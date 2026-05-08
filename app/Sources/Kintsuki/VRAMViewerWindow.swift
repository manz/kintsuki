import SwiftUI
import AppKit

/// VRAM viewer. Decodes the live tile data into a grid view across the
/// whole 64 KB region for the chosen bpp + sub-palette. Sidebar surfaces
/// the selected tile's address + raw bytes + palette swatch. Same
/// pause/refresh model as the Tilemap Viewer — cached snapshot, 2 Hz
/// auto-refresh while running, plain `Emulator` reference (no
/// `@EnvironmentObject`) so opening the window doesn't tax the run loop.
struct VRAMViewerView: View {
    let emulator: Emulator
    @Environment(\.openWindow) private var openWindow
    @State private var bpp: TileBpp = .bpp4
    @State private var paletteIndex: Int = 0
    @State private var selectedTile: Int? = nil
    @State private var snapshot: VRAMSnapshot? = nil
    /// Cached DMA transfers — re-pulled on the same 2 Hz tick that
    /// rebuilds the snapshot so the sidebar shows current sources
    /// without subscribing to every emulator @Published change.
    @State private var dmaTransfers: [Emulator.DMATransfer] = []

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let snap = snapshot {
                    ScrollView([.vertical]) {
                        VRAMTileGrid(snapshot: snap,
                                     selected: selectedTile,
                                     onSelect: { selectedTile = $0 })
                            .padding(8)
                    }
                    .background(Color.black)
                } else {
                    ContentUnavailableView("No ROM",
                                           systemImage: "rectangle.dashed")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 540, minHeight: 420)

            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        }
        .frame(minWidth: 800, minHeight: 480)
        .onAppear { rebuildSnapshot() }
        .onChange(of: emulator.running) { _, isRunning in
            if !isRunning { rebuildSnapshot() }
        }
        .onChange(of: emulator.loadedROM) { _, _ in rebuildSnapshot() }
        .onChange(of: bpp) { _, _ in rebuildSnapshot() }
        .onChange(of: paletteIndex) { _, _ in rebuildSnapshot() }
        // 2 Hz auto-refresh — same cost model as the tilemap viewer.
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            rebuildSnapshot()
        }
    }

    // ----- Toolbar -----
    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Format", selection: $bpp) {
                Text("2 bpp").tag(TileBpp.bpp2)
                Text("4 bpp").tag(TileBpp.bpp4)
                Text("8 bpp").tag(TileBpp.bpp8)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .labelsHidden()

            HStack(spacing: 4) {
                Text("Palette").font(.caption).foregroundStyle(.secondary)
                Stepper(value: $paletteIndex, in: 0...maxPaletteIndex(bpp)) {
                    Text(String(format: "$%02X", paletteIndex * bpp.paletteStride))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 50)
                }
                .disabled(bpp == .bpp8)
            }
            Spacer()
            Button("Refresh") { rebuildSnapshot() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        .padding(8)
    }

    private func maxPaletteIndex(_ bpp: TileBpp) -> Int {
        switch bpp {
        case .bpp2: return 63          // 64 sub-palettes of 4 colors
        case .bpp4: return 15          // 16 sub-palettes of 16 colors
        case .bpp8: return 0           // single palette
        }
    }

    // ----- Sidebar -----
    @ViewBuilder
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let snap = snapshot {
                    metaSection(snap)
                    Divider()
                    selectedTileSection(snap)
                    Divider()
                    paletteSection(snap)
                    Divider()
                    dmaSourcesSection
                } else {
                    Text("No data").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private func metaSection(_ snap: VRAMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VRAM").font(.headline)
            metaRow("Region", "$0000–$FFFF (64 KB)")
            metaRow("Format", "\(snap.bpp.rawValue) bpp")
            metaRow("Tile size", "8×8")
            metaRow("Tile count", "\(snap.tileCount)")
            metaRow("Bytes / tile", "\(snap.bpp.tileBytes)")
        }
    }

    @ViewBuilder
    private func selectedTileSection(_ snap: VRAMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected Tile").font(.headline)
            if let t = selectedTile, t < snap.tileCount {
                let addr = t * snap.bpp.tileBytes
                tilePreview(snap: snap, tileIndex: t)
                metaRow("Index", String(format: "$%04X", t))
                metaRow("Address", String(format: "$%04X.w", addr >> 1))
                metaRow("Bytes", "\(snap.bpp.tileBytes)")
                rawBytesRow(snap: snap, tileIndex: t)
            } else {
                Text("Click a tile").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private func paletteSection(_ snap: VRAMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Palette").font(.headline)
            // 16x16 grid of all 256 CGRAM entries; the active sub-palette
            // (whatever the user picked in the toolbar) gets a highlight
            // ring so it's obvious which row is rendering the tile grid.
            VStack(spacing: 1) {
                ForEach(0..<16, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<16, id: \.self) { col in
                            let idx = row * 16 + col
                            let c = snap.paletteRGB[idx]
                            Rectangle()
                                .fill(Color(red: Double(c.0)/255,
                                            green: Double(c.1)/255,
                                            blue: Double(c.2)/255))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    Rectangle()
                                        .strokeBorder(Color.white,
                                                      lineWidth: idx == paletteIndex * snap.bpp.paletteStride ? 1 : 0)
                                )
                        }
                    }
                }
            }
        }
    }

    private func tilePreview(snap: VRAMSnapshot, tileIndex: Int) -> some View {
        let img = renderSingleTile(snap: snap, tileIndex: tileIndex)
        return HStack {
            Text("Tile").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .frame(width: 64, height: 64)
                .background(Color.black)
        }
    }

    private func rawBytesRow(snap: VRAMSnapshot, tileIndex: Int) -> some View {
        let addr = tileIndex * snap.bpp.tileBytes
        let bytes = snap.vram.subdata(in: addr..<min(addr + snap.bpp.tileBytes,
                                                     snap.vram.count))
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 2) {
            Text("Bytes").font(.caption).foregroundStyle(.secondary)
            Text(hex)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(4)
                .foregroundStyle(.secondary)
        }
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(v).font(.system(.caption, design: .monospaced))
            Spacer()
        }
    }

    /// Recent CPU→VRAM DMA transfers surfaced from the libkintsuki
    /// ring. Each row is a link that opens the Memory Viewer focused
    /// on the source WRAM/ROM offset; lets the user trace which
    /// buffer fed which VRAM region without leaving this window.
    @ViewBuilder
    private var dmaSourcesSection: some View {
        let xfers = dmaTransfers.filter { $0.isVRAMWrite }
        VStack(alignment: .leading, spacing: 6) {
            Text("VRAM DMA sources").font(.headline)
            if xfers.isEmpty {
                Text("(no transfers logged yet)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(xfers.prefix(8)) { x in
                    Button {
                        let region: Emulator.MemRegion =
                            (0x7E0000...0x7FFFFF).contains(x.srcAddr)
                                ? .wram : .rom
                        let off = region == .wram
                            ? Int(x.srcAddr & 0x1FFFF)
                            : romOffsetFor(busAddr: x.srcAddr)
                        emulator.requestMemoryView(region: region, offset: off)
                        openWindow(id: "memory")
                    } label: {
                        HStack {
                            Text(String(format: "%06X", x.srcAddr))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .underline()
                            Text(String(format: "→ VRAM $%04X.w (%d B) ×%d",
                                        x.vramAddr, x.size, x.hits))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 24-bit bus addr → LoROM region offset (matches MemoryViewer's
    /// `.rom` mapping: bank * 0x8000 + (addr & 0x7FFF)).
    private func romOffsetFor(busAddr: UInt32) -> Int {
        let bank = Int(busAddr >> 16) & 0x7F
        let lo = Int(busAddr & 0xFFFF)
        if lo < 0x8000 { return 0 }
        return bank * 0x8000 + (lo - 0x8000)
    }

    // ----- Snapshot derivation -----
    private func rebuildSnapshot() {
        // Pull DMA log alongside the VRAM/CGRAM snapshot — same cadence,
        // single touch of @State per refresh tick.
        dmaTransfers = emulator.dmaTransfers()
        guard emulator.loadedROM != nil else {
            snapshot = nil
            return
        }
        let vram = emulator.vramSnapshot()
        let cgram = emulator.cgramSnapshot()
        let palette = paletteFromCGRAM(cgram)
        let tileBytes = bpp.tileBytes
        let tileCount = vram.count / tileBytes
        snapshot = VRAMSnapshot(bpp: bpp,
                                paletteIndex: paletteIndex,
                                tileCount: tileCount,
                                vram: vram,
                                paletteRGB: palette)
    }

    private func paletteFromCGRAM(_ cgram: Data) -> [(UInt8, UInt8, UInt8)] {
        var out = [(UInt8, UInt8, UInt8)](repeating: (0, 0, 0), count: 256)
        cgram.withUnsafeBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<256 {
                let lo = p[i * 2]
                let hi = p[i * 2 + 1]
                let bgr = UInt16(lo) | (UInt16(hi) << 8)
                let r5 = UInt8((bgr >> 0) & 0x1F)
                let g5 = UInt8((bgr >> 5) & 0x1F)
                let b5 = UInt8((bgr >> 10) & 0x1F)
                out[i] = ((r5 << 3) | (r5 >> 2),
                          (g5 << 3) | (g5 >> 2),
                          (b5 << 3) | (b5 >> 2))
            }
        }
        return out
    }

    private func renderSingleTile(snap: VRAMSnapshot, tileIndex: Int) -> NSImage {
        var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let palBase = paletteIndex * snap.bpp.paletteStride
        rgba.withUnsafeMutableBufferPointer { dst in
            snap.vram.withUnsafeBytes { src in
                guard let s = src.bindMemory(to: UInt8.self).baseAddress,
                      let d = dst.baseAddress else { return }
                TileDecoder.blitTile(vram: s, vramSize: snap.vram.count,
                                     charBase: 0, tileIndex: tileIndex,
                                     bpp: snap.bpp,
                                     paletteRGB: snap.paletteRGB,
                                     paletteBase: palBase,
                                     hflip: false, vflip: false,
                                     out: d, dstStride: 8 * 4,
                                     dstX: 0, dstY: 0)
            }
        }
        return cgImageFromRGBA(rgba: rgba, width: 8, height: 8)
            .map { NSImage(cgImage: $0, size: NSSize(width: 8, height: 8)) }
            ?? NSImage(size: NSSize(width: 8, height: 8))
    }
}

// ----- Snapshot value type -----
struct VRAMSnapshot {
    let bpp: TileBpp
    let paletteIndex: Int
    let tileCount: Int
    let vram: Data
    let paletteRGB: [(UInt8, UInt8, UInt8)]
}

// ----- Tile grid canvas -----
private struct VRAMTileGrid: View {
    let snapshot: VRAMSnapshot
    let selected: Int?
    let onSelect: (Int) -> Void

    /// 16 tiles per row keeps the canvas a fixed 128 px wide at 1× and
    /// is the convention every SNES tile inspector ships with.
    private static let cols = 16
    private static let scale: CGFloat = 2.0

    var body: some View {
        let cols = Self.cols
        let rows = (snapshot.tileCount + cols - 1) / cols
        let pxW = cols * 8
        let pxH = rows * 8
        let img = renderImage(snapshot: snapshot, cols: cols, rows: rows)
        ZStack(alignment: .topLeading) {
            if let img {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(pxW) * Self.scale, height: CGFloat(pxH) * Self.scale)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
                    .frame(width: CGFloat(pxW) * Self.scale, height: CGFloat(pxH) * Self.scale)
            }
            if let t = selected {
                let col = t % cols
                let row = t / cols
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1)
                    .frame(width: 8 * Self.scale, height: 8 * Self.scale)
                    .offset(x: CGFloat(col * 8) * Self.scale,
                            y: CGFloat(row * 8) * Self.scale)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: CGFloat(pxW) * Self.scale, height: CGFloat(pxH) * Self.scale)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { loc in
            let col = Int(loc.x / (8 * Self.scale))
            let row = Int(loc.y / (8 * Self.scale))
            let t = row * cols + col
            if t >= 0, t < snapshot.tileCount { onSelect(t) }
        }
    }

    private func renderImage(snapshot: VRAMSnapshot, cols: Int, rows: Int) -> NSImage? {
        let pxW = cols * 8
        let pxH = rows * 8
        let stride = pxW * 4
        var rgba = [UInt8](repeating: 0, count: stride * pxH)
        let palBase = snapshot.paletteIndex * snapshot.bpp.paletteStride
        rgba.withUnsafeMutableBufferPointer { dst in
            snapshot.vram.withUnsafeBytes { src in
                guard let s = src.bindMemory(to: UInt8.self).baseAddress,
                      let d = dst.baseAddress else { return }
                for t in 0..<snapshot.tileCount {
                    let col = t % cols
                    let row = t / cols
                    TileDecoder.blitTile(vram: s, vramSize: snapshot.vram.count,
                                         charBase: 0, tileIndex: t,
                                         bpp: snapshot.bpp,
                                         paletteRGB: snapshot.paletteRGB,
                                         paletteBase: palBase,
                                         hflip: false, vflip: false,
                                         out: d, dstStride: stride,
                                         dstX: col * 8, dstY: row * 8)
                }
            }
        }
        return cgImageFromRGBA(rgba: rgba, width: pxW, height: pxH)
            .map { NSImage(cgImage: $0, size: NSSize(width: pxW, height: pxH)) }
    }
}

private func cgImageFromRGBA(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGImage(width: width, height: height,
                   bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: cs,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}
