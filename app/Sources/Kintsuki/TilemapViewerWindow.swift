import SwiftUI
import AppKit

/// Mesen-S-style BG tilemap viewer. Per-layer canvas, tile-grid overlay,
/// scroll-window overlay, sidebar with tilemap meta + selected-tile detail.
/// Refreshes on pause + manual button (v1). Mode 7 not handled.
struct TilemapViewerView: View {
    /// Plain reference, NOT `@EnvironmentObject` — the Emulator's
    /// `@Published` properties churn at 60 Hz while running and would
    /// otherwise force this whole pane (4 layers × 64×64 tiles ×
    /// CGImage build) to redraw every tick. We pull snapshots on
    /// pause / explicit refresh instead.
    let emulator: Emulator
    @Environment(\.openWindow) private var openWindow
    @State private var selectedLayer: Int = 1
    @State private var showGrid: Bool = true
    @State private var showScrollOverlay: Bool = true
    @State private var selectedCell: (row: Int, col: Int)? = nil
    /// Cached layer snapshot — recomputed on pause edge / manual refresh /
    /// layer change. nil while no ROM is loaded or current BG mode has
    /// no data for the selected layer.
    @State private var cachedSnapshot: LayerSnapshot? = nil

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $selectedLayer) {
                    ForEach(1...4, id: \.self) { i in
                        Text("Layer \(i)").tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)

                Divider()

                if let snap = cachedSnapshot {
                    ScrollView([.horizontal, .vertical]) {
                        TilemapCanvas(snap: snap,
                                      showGrid: showGrid,
                                      showScrollOverlay: showScrollOverlay,
                                      selected: selectedCell,
                                      onSelect: { selectedCell = $0 })
                            .padding(12)
                    }
                    .background(Color.black)
                } else {
                    ContentUnavailableView("Layer not active in current BG mode (or running — pause to refresh)",
                                           systemImage: "rectangle.dashed")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()
                HStack {
                    Toggle("Show tile grid", isOn: $showGrid)
                    Toggle("Show scroll overlay", isOn: $showScrollOverlay)
                    Spacer()
                    Button("Refresh") { rebuildSnapshot() }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                }
                .padding(8)
            }
            .frame(minWidth: 560, minHeight: 400)

            sidebar
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 360)
        }
        .frame(minWidth: 820, minHeight: 480)
        .onAppear { rebuildSnapshot() }
        // Subscribe selectively via `.onReceive` rather than carrying an
        // `@EnvironmentObject` — the latter would invalidate this body on
        // every emulator @Published mutation (60 Hz).
        .onChange(of: emulator.running) { _, isRunning in
            if !isRunning { rebuildSnapshot() }
        }
        .onChange(of: emulator.loadedROM) { _, _ in rebuildSnapshot() }
        .onChange(of: selectedLayer) { _, _ in rebuildSnapshot() }
        // 2 Hz auto-refresh while running so the canvas tracks tilemap
        // edits without forcing the user to pause. Cheap: each rebuild
        // is one PPU snapshot + one tilemap CGImage build, far below
        // 60 Hz cost.
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            rebuildSnapshot()
        }
    }

    private func rebuildSnapshot() {
        cachedSnapshot = layerSnapshot(layer: selectedLayer)
    }

    // ----- Sidebar -----
    @ViewBuilder
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let snap = cachedSnapshot {
                    metaSection(snap)
                    Divider()
                    dmaSourcesSection
                    Divider()
                    selectedTileSection(snap)
                } else {
                    Text("No data").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private func metaSection(_ snap: LayerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tilemap").font(.headline)
            metaRow("Size", "\(snap.size.widthCells)×\(snap.size.heightCells)")
            metaRow("Size (px)", "\(snap.size.widthCells * 8)×\(snap.size.heightCells * 8)")
            vramLinkRow(label: "Tilemap", byteOffset: snap.mapBaseByte)
            vramLinkRow(label: "Tileset", byteOffset: snap.charBaseByte)
            metaRow("Format", "\(snap.bpp.rawValue) bpp")
            metaRow("Mode", "BG\(snap.layer) (mode \(snap.bgMode))")
        }
    }

    @ViewBuilder
    private func selectedTileSection(_ snap: LayerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected Tile").font(.headline)
            if let sel = selectedCell, sel.row < snap.size.heightCells, sel.col < snap.size.widthCells {
                let cell = snap.cell(row: sel.row, col: sel.col)
                let cellByteOffset = tilemapCellByteOffset(size: snap.size,
                                                           mapBaseByte: snap.mapBaseByte,
                                                           row: sel.row, col: sel.col)
                let tileByteAddr = (snap.charBaseByte + Int(cell.tile) * snap.bpp.tileBytes) & 0xFFFF
                let palBase = paletteBaseFor(cell: cell, bpp: snap.bpp)
                tilePreview(snap: snap, cell: cell)
                paletteSwatch(snap: snap, paletteBase: palBase)
                metaRow("Column, Row", "\(sel.col), \(sel.row)")
                metaRow("X, Y", "\(sel.col * 8), \(sel.row * 8)")
                metaRow("Size", "8×8")
                vramLinkRow(label: "Tilemap addr", byteOffset: cellByteOffset)
                metaRow("Tile index", String(format: "$%03X", cell.tile))
                vramLinkRow(label: "Tile addr", byteOffset: tileByteAddr)
                metaRow("Palette idx", "\(cell.palette)")
                metaRow("Palette addr", String(format: "$%02X", palBase))
                flagRow("Horizontal mirror", cell.hflip)
                flagRow("Vertical mirror", cell.vflip)
                flagRow("High priority", cell.priority)
            } else {
                Text("Click a cell").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private func tilePreview(snap: LayerSnapshot, cell: TilemapCell) -> some View {
        let img = renderSingleTile(snap: snap, cell: cell)
        return HStack {
            Text("Tile").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .frame(width: 48, height: 48)
                .background(Color.black)
        }
    }

    private func paletteSwatch(snap: LayerSnapshot, paletteBase: Int) -> some View {
        let cols = max(snap.bpp.paletteStride / 8, 1) // fold long palettes
        let stride = snap.bpp.paletteStride
        return HStack(alignment: .top) {
            Text("Palette").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            VStack(spacing: 1) {
                ForEach(0..<(stride / cols), id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<cols, id: \.self) { col in
                            let idx = (paletteBase + row * cols + col) & 0xFF
                            let c = snap.paletteRGB[idx]
                            Rectangle()
                                .fill(Color(red: Double(c.0)/255,
                                            green: Double(c.1)/255,
                                            blue: Double(c.2)/255))
                                .frame(width: 14, height: 14)
                        }
                    }
                }
            }
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

    /// Recent CPU→VRAM DMA sources surfaced from the libkintsuki ring.
    /// Each row is clickable: jumps the Memory Viewer to the
    /// corresponding WRAM/ROM source with a marker covering the
    /// transfer length. Helps the user trace "what fed this region".
    @ViewBuilder
    private var dmaSourcesSection: some View {
        // Only surface CPU→VRAM transfers whose destination range
        // overlaps THIS layer's tilemap or charset window. Stops the
        // panel from drowning the user in unrelated copies (sprite
        // tile uploads, OAM-DMA-via-VRAM tricks, etc.).
        let xfers = emulator.dmaTransfers().filter { x in
            guard x.isVRAMWrite, let dst = x.vramByteRange else { return false }
            return ranges(forLayer: cachedSnapshot).contains { r in
                dst.overlaps(r)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Layer DMA sources").font(.headline)
            if xfers.isEmpty {
                Text("(no transfers into this layer yet — pause/play to capture)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(xfers.prefix(8)) { x in
                    dmaRow(x)
                }
            }
        }
    }

    private func dmaRow(_ x: Emulator.DMATransfer) -> some View {
        let dstByte = (Int(x.vramAddr) << 1) & 0xFFFF
        return Button {
            let region: Emulator.MemRegion =
                (0x7E0000...0x7FFFFF).contains(x.srcAddr) ? .wram : .rom
            let off = region == .wram
                ? Int(x.srcAddr & 0x1FFFF)
                : romOffsetFor(busAddr: x.srcAddr)
            emulator.requestMemoryView(region: region, offset: off)
            openWindow(id: "memory")
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(String(format: "%06X", x.srcAddr))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .underline()
                    Text(String(format: "→ VRAM $%04X.w (%d B) ×%d",
                                dstByte >> 1, x.size, x.hits))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Byte ranges in VRAM "owned" by the current layer — tilemap
    /// (sub-plane × 0x800) plus a 4 KB char-base hint window. Used
    /// to filter the DMA log to entries that hit the layer the user
    /// is looking at.
    private func ranges(forLayer snap: LayerSnapshot?) -> [ClosedRange<Int>] {
        guard let snap else { return [] }
        var out: [ClosedRange<Int>] = []
        // Tilemap range matches what HexMarker uses in MemoryViewer.
        let subPlanes = snap.size.subPlanes
        let mapLo = snap.mapBaseByte & 0xFFFF
        let mapHi = min(0xFFFF, mapLo + subPlanes * 0x800 - 1)
        if mapLo < mapHi { out.append(mapLo...mapHi) }
        // Char base hint: 4 KB.
        let charLo = snap.charBaseByte & 0xFFFF
        let charHi = min(0xFFFF, charLo + 0x1000 - 1)
        if charLo < charHi { out.append(charLo...charHi) }
        return out
    }

    /// Translate a 24-bit bus address into the LoROM region offset
    /// used by MemoryViewerView (bank * 0x8000 + (addr & 0x7FFF)).
    private func romOffsetFor(busAddr: UInt32) -> Int {
        let bank = Int(busAddr >> 16) & 0x7F
        let lo = Int(busAddr & 0xFFFF)
        if lo < 0x8000 { return 0 }                  // not in ROM mapping
        return bank * 0x8000 + (lo - 0x8000)
    }

    /// Address row that doubles as a link to the Memory Viewer's VRAM
    /// tab, focused on the given byte offset. Click → opens the
    /// memory window if needed and dispatches a navigation request
    /// through the shared `Emulator.requestMemoryView` channel.
    private func vramLinkRow(label: String, byteOffset: Int) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Button {
                emulator.requestMemoryView(region: .vram,
                                           offset: byteOffset & 0xFFFF)
                openWindow(id: "memory")
            } label: {
                Text(String(format: "$%04X.w", byteOffset >> 1))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .underline()
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func flagRow(_ k: String, _ v: Bool) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Image(systemName: v ? "checkmark.square.fill" : "square")
                .foregroundStyle(v ? Color.accentColor : Color.secondary)
            Spacer()
        }
    }

    // ----- Snapshot derivation -----
    private func layerSnapshot(layer: Int) -> LayerSnapshot? {
        guard let ppu = emulator.ppuState() else { return nil }
        let mode = Int(ppu.bgmode & 0x07)
        guard let bpp = bppFor(layer: layer, mode: mode) else { return nil }
        let bgsc: UInt8
        switch layer {
        case 1: bgsc = ppu.bg1sc
        case 2: bgsc = ppu.bg2sc
        case 3: bgsc = ppu.bg3sc
        default: bgsc = ppu.bg4sc
        }
        let size = TilemapSize(bgsc: bgsc)
        let mapBaseWord = Int(bgsc & 0xFC) << 8     // bits 7..2 → word base
        let mapBaseByte = mapBaseWord << 1
        // BG12NBA bits 0-3 = BG1, 4-7 = BG2. BG34NBA likewise.
        let nba: UInt8
        switch layer {
        case 1: nba = ppu.bg12nba & 0x0F
        case 2: nba = (ppu.bg12nba >> 4) & 0x0F
        case 3: nba = ppu.bg34nba & 0x0F
        default: nba = (ppu.bg34nba >> 4) & 0x0F
        }
        let charBaseByte = (Int(nba) * 0x1000) << 1   // ×0x2000 bytes per step
        let hofs: UInt16
        let vofs: UInt16
        switch layer {
        case 1: hofs = ppu.bg1hofs; vofs = ppu.bg1vofs
        case 2: hofs = ppu.bg2hofs; vofs = ppu.bg2vofs
        case 3: hofs = ppu.bg3hofs; vofs = ppu.bg3vofs
        default: hofs = ppu.bg4hofs; vofs = ppu.bg4vofs
        }
        let vram = emulator.vramSnapshot()
        let cgram = emulator.cgramSnapshot()
        return LayerSnapshot(layer: layer,
                             bgMode: mode,
                             bpp: bpp,
                             size: size,
                             mapBaseByte: mapBaseByte & 0xFFFF,
                             charBaseByte: charBaseByte & 0xFFFF,
                             scrollX: hofs,
                             scrollY: vofs,
                             vram: vram,
                             paletteRGB: paletteFromCGRAM(cgram))
    }

    private func bppFor(layer: Int, mode: Int) -> TileBpp? {
        // Mode 7 (and mode 6 BG2/BG4) intentionally skipped in v1.
        switch (mode, layer) {
        case (0, _):                         return .bpp2
        case (1, 1), (1, 2):                 return .bpp4
        case (1, 3):                         return .bpp2
        case (1, 4):                         return nil
        case (2, 1), (2, 2):                 return .bpp4
        case (3, 1):                         return .bpp8
        case (3, 2):                         return .bpp4
        case (4, 1):                         return .bpp8
        case (4, 2):                         return .bpp2
        case (5, 1):                         return .bpp4
        case (5, 2):                         return .bpp2
        case (6, 1):                         return .bpp4
        case (7, _):                         return nil    // skip Mode 7
        default:                             return nil
        }
    }

    private func paletteBaseFor(cell: TilemapCell, bpp: TileBpp) -> Int {
        switch bpp {
        case .bpp2: return Int(cell.palette) * 4
        case .bpp4: return Int(cell.palette) * 16
        case .bpp8: return 0
        }
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

    private func renderSingleTile(snap: LayerSnapshot, cell: TilemapCell) -> NSImage {
        let palBase = paletteBaseFor(cell: cell, bpp: snap.bpp)
        var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
        rgba.withUnsafeMutableBufferPointer { dst in
            snap.vram.withUnsafeBytes { src in
                guard let s = src.bindMemory(to: UInt8.self).baseAddress,
                      let d = dst.baseAddress else { return }
                TileDecoder.blitTile(vram: s, vramSize: snap.vram.count,
                                     charBase: snap.charBaseByte,
                                     tileIndex: Int(cell.tile),
                                     bpp: snap.bpp,
                                     paletteRGB: snap.paletteRGB,
                                     paletteBase: palBase,
                                     hflip: cell.hflip, vflip: cell.vflip,
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
struct LayerSnapshot {
    let layer: Int
    let bgMode: Int
    let bpp: TileBpp
    let size: TilemapSize
    let mapBaseByte: Int
    let charBaseByte: Int
    let scrollX: UInt16
    let scrollY: UInt16
    let vram: Data
    let paletteRGB: [(UInt8, UInt8, UInt8)]

    func cell(row: Int, col: Int) -> TilemapCell {
        let off = tilemapCellByteOffset(size: size, mapBaseByte: mapBaseByte,
                                        row: row, col: col)
        let lo = vram[off & 0xFFFF]
        let hi = vram[(off + 1) & 0xFFFF]
        return TilemapCell(raw: UInt16(lo) | (UInt16(hi) << 8))
    }
}

// ----- Canvas (full tilemap + grid + scroll overlay) -----
private struct TilemapCanvas: View {
    let snap: LayerSnapshot
    let showGrid: Bool
    let showScrollOverlay: Bool
    let selected: (row: Int, col: Int)?
    let onSelect: ((row: Int, col: Int)) -> Void

    var body: some View {
        let pxW = snap.size.widthCells * 8
        let pxH = snap.size.heightCells * 8
        let scale: CGFloat = 2.0
        let img = renderTilemapImage(snap: snap)

        ZStack(alignment: .topLeading) {
            if let img {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(pxW) * scale, height: CGFloat(pxH) * scale)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
                    .frame(width: CGFloat(pxW) * scale, height: CGFloat(pxH) * scale)
            }
            if showGrid {
                gridOverlay(pxW: pxW, pxH: pxH, scale: scale)
            }
            if showScrollOverlay {
                scrollOverlay(pxW: pxW, pxH: pxH, scale: scale)
            }
            if let sel = selected {
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1)
                    .frame(width: 8 * scale, height: 8 * scale)
                    .offset(x: CGFloat(sel.col * 8) * scale,
                            y: CGFloat(sel.row * 8) * scale)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: CGFloat(pxW) * scale, height: CGFloat(pxH) * scale)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { loc in
            let col = Int(loc.x / (8 * scale))
            let row = Int(loc.y / (8 * scale))
            if col >= 0, col < snap.size.widthCells,
               row >= 0, row < snap.size.heightCells {
                onSelect((row: row, col: col))
            }
        }
    }

    private func gridOverlay(pxW: Int, pxH: Int, scale: CGFloat) -> some View {
        Canvas { ctx, _ in
            let w = CGFloat(pxW) * scale
            let h = CGFloat(pxH) * scale
            var path = Path()
            for x in stride(from: 0, through: pxW, by: 8) {
                let xx = CGFloat(x) * scale
                path.move(to: CGPoint(x: xx, y: 0))
                path.addLine(to: CGPoint(x: xx, y: h))
            }
            for y in stride(from: 0, through: pxH, by: 8) {
                let yy = CGFloat(y) * scale
                path.move(to: CGPoint(x: 0, y: yy))
                path.addLine(to: CGPoint(x: w, y: yy))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 1)
        }
        .frame(width: CGFloat(pxW) * scale, height: CGFloat(pxH) * scale)
        .allowsHitTesting(false)
    }

    private func scrollOverlay(pxW: Int, pxH: Int, scale: CGFloat) -> some View {
        // SNES screen window: 256x224 starting at (scrollX, scrollY) mod tilemap size.
        let sx = Int(snap.scrollX) % pxW
        let sy = Int(snap.scrollY) % pxH
        return Canvas { ctx, _ in
            ctx.stroke(Path { p in
                p.addRect(CGRect(x: CGFloat(sx) * scale,
                                 y: CGFloat(sy) * scale,
                                 width: 256 * scale,
                                 height: 224 * scale))
            }, with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
        .frame(width: CGFloat(pxW) * scale, height: CGFloat(pxH) * scale)
        .allowsHitTesting(false)
    }
}

// ----- Full-tilemap renderer -----
private func renderTilemapImage(snap: LayerSnapshot) -> NSImage? {
    let pxW = snap.size.widthCells * 8
    let pxH = snap.size.heightCells * 8
    let stride = pxW * 4
    var rgba = [UInt8](repeating: 0, count: stride * pxH)
    rgba.withUnsafeMutableBufferPointer { dst in
        snap.vram.withUnsafeBytes { src in
            guard let s = src.bindMemory(to: UInt8.self).baseAddress,
                  let d = dst.baseAddress else { return }
            for row in 0..<snap.size.heightCells {
                for col in 0..<snap.size.widthCells {
                    let cell = snap.cell(row: row, col: col)
                    let palBase: Int
                    switch snap.bpp {
                    case .bpp2: palBase = Int(cell.palette) * 4
                    case .bpp4: palBase = Int(cell.palette) * 16
                    case .bpp8: palBase = 0
                    }
                    TileDecoder.blitTile(vram: s, vramSize: snap.vram.count,
                                         charBase: snap.charBaseByte,
                                         tileIndex: Int(cell.tile),
                                         bpp: snap.bpp,
                                         paletteRGB: snap.paletteRGB,
                                         paletteBase: palBase,
                                         hflip: cell.hflip, vflip: cell.vflip,
                                         out: d, dstStride: stride,
                                         dstX: col * 8, dstY: row * 8)
                }
            }
        }
    }
    return cgImageFromRGBA(rgba: rgba, width: pxW, height: pxH)
        .map { NSImage(cgImage: $0, size: NSSize(width: pxW, height: pxH)) }
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
