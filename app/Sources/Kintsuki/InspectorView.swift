import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var emulator: Emulator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fpsRow
                Divider()
                cpuSection
                Divider()
                memorySection
                Divider()
                paletteSection
                Divider()
                tileSection
                Divider()
                breakpointSection
                Divider()
                saveStateSection
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 360)
        .background(.background)
    }

    // ------------------------------------------------------------------ FPS
    private var fpsRow: some View {
        HStack {
            Text("FPS").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f", emulator.fps))
                .font(.system(.body, design: .monospaced))
            Text(emulator.running ? "running" : "paused")
                .font(.caption)
                .foregroundStyle(emulator.running ? .green : .orange)
        }
    }

    // ------------------------------------------------------------------ CPU
    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CPU (65816)").font(.headline)
            let s = emulator.cpuState
            HStack {
                regCol("A",  String(format: "%04X", s.a))
                regCol("X",  String(format: "%04X", s.x))
                regCol("Y",  String(format: "%04X", s.y))
            }
            HStack {
                regCol("S",  String(format: "%04X", s.s))
                regCol("D",  String(format: "%04X", s.d))
                regCol("B",  String(format: "%02X", s.b))
            }
            HStack {
                regCol("PC", String(format: "%06X", s.pc))
                regCol("P",  String(format: "%02X", s.p))
                regCol("E",  s.e ? "1" : "0")
            }
            Text(flagString(s.p))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func regCol(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flagString(_ p: UInt8) -> String {
        let labels: [(UInt8, Character)] = [
            (0x80,"N"),(0x40,"V"),(0x20,"M"),(0x10,"X"),
            (0x08,"D"),(0x04,"I"),(0x02,"Z"),(0x01,"C"),
        ]
        return String(labels.map { (p & $0.0) != 0 ? $0.1 : Character($0.1.lowercased()) })
    }

    // --------------------------------------------------------------- Memory
    @State private var memRegion: Emulator.MemRegion = .wram
    @State private var memBase: UInt32 = 0
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Memory").font(.headline)
                Spacer()
                Picker("", selection: $memRegion) {
                    ForEach(Emulator.MemRegion.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 110)
                .onChange(of: memRegion) { _, _ in memBase = 0 }
            }
            HStack {
                Stepper("",
                        value: $memBase,
                        in: 0...max(0, memRegion.size - 0x100),
                        step: 0x100)
                    .labelsHidden()
                    .controlSize(.mini)
                Text("$\(String(format: "%06X", memBase))")
                    .font(.system(.caption, design: .monospaced))
                Spacer()
            }
            let bytes = emulator.readRegion(memRegion, offset: memBase, length: 256)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<16, id: \.self) { row in
                    let off = row * 16
                    let slice = off+16 <= bytes.count
                        ? bytes.subdata(in: off..<off+16)
                        : (off < bytes.count ? bytes.subdata(in: off..<bytes.count) : Data())
                    HStack(spacing: 6) {
                        Text(String(format: "%05X", memBase + UInt32(off)))
                            .foregroundStyle(.secondary)
                        Text(slice.map { String(format: "%02x", $0) }.joined(separator: " "))
                        Spacer()
                    }
                    .font(.system(.caption2, design: .monospaced))
                }
            }
            .id(emulator.lastFrameID / 6)  // refresh ~10 Hz
        }
    }

    // -------------------------------------------------------------- Palette
    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CGRAM Palette").font(.headline)
            let colors = emulator.paletteRGB()
            VStack(spacing: 1) {
                ForEach(0..<16, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<16, id: \.self) { col in
                            let i = row * 16 + col
                            if i < colors.count {
                                let c = colors[i]
                                Color(.sRGB,
                                      red: Double(c.0)/255.0,
                                      green: Double(c.1)/255.0,
                                      blue: Double(c.2)/255.0)
                                    .frame(width: 16, height: 16)
                                    .help("$\(String(format: "%02X", i)) = #\(String(format: "%02X%02X%02X", c.0, c.1, c.2))")
                            }
                        }
                    }
                }
            }
            .id(emulator.lastFrameID / 12)  // refresh ~5 Hz
        }
    }

    // -------------------------------------------------------------- Tiles
    @State private var tileBase: UInt32 = 0
    @State private var tilePalette: Int = 0
    private var tileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("VRAM Tiles (4bpp)").font(.headline)
                Spacer()
                Stepper("", value: $tileBase, in: 0...0xF800, step: 0x800)
                    .labelsHidden()
                    .controlSize(.mini)
                Text("$\(String(format: "%04X", tileBase))")
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Text("Sub-palette \(tilePalette)").font(.caption2).foregroundStyle(.secondary)
                Stepper("", value: $tilePalette, in: 0...15)
                    .labelsHidden()
                    .controlSize(.mini)
            }
            tileGrid
                .id(emulator.lastFrameID / 12)
        }
    }

    @ViewBuilder
    private var tileGrid: some View {
        let colors = emulator.paletteRGB()
        let paletteOffset = tilePalette * 16
        VStack(spacing: 1) {
            ForEach(0..<8, id: \.self) { tileRow in
                HStack(spacing: 1) {
                    ForEach(0..<16, id: \.self) { tileCol in
                        let tileIndex = tileRow * 16 + tileCol
                        let pixels = emulator.decodeTile4bpp(addr: tileBase + UInt32(tileIndex * 32))
                        TileView(pixels: pixels,
                                 paletteOffset: paletteOffset,
                                 colors: colors)
                            .frame(width: 16, height: 16)
                    }
                }
            }
        }
    }

    // -------------------------------------------------------- Breakpoints
    @State private var newBpKind: Emulator.BreakKind = .exec
    @State private var newBpLoText: String = ""
    @State private var newBpHiText: String = ""

    private var breakpointSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Breakpoints").font(.headline)
            HStack(spacing: 4) {
                Picker("", selection: $newBpKind) {
                    ForEach(Emulator.BreakKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 80)
                TextField("$lo",  text: $newBpLoText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: 80)
                TextField("$hi",  text: $newBpHiText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: 80)
                Button("Add") { addBreakpoint() }
                    .controlSize(.small)
                    .disabled(parsedRange() == nil)
            }
            ForEach(emulator.breakpoints) { bp in
                HStack {
                    Text(bp.kind.label).font(.caption2)
                        .frame(width: 40, alignment: .leading)
                    Text("$\(String(format:"%06X", bp.lo))..$\(String(format:"%06X", bp.hi))")
                        .font(.system(.caption2, design: .monospaced))
                    Spacer()
                    Text("hits \(bp.hitCount)").font(.caption2)
                        .foregroundStyle(.secondary)
                    if bp.hitCount > 0 {
                        Text("@$\(String(format:"%06X", bp.lastHit))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button("✕") { emulator.removeBreakpoint(bp) }
                        .controlSize(.mini)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func parsedRange() -> (UInt32, UInt32)? {
        let lo = parseHex(newBpLoText)
        let hi = newBpHiText.isEmpty ? lo : parseHex(newBpHiText)
        guard let lo, let hi, lo <= hi else { return nil }
        return (lo, hi)
    }
    private func addBreakpoint() {
        guard let (lo, hi) = parsedRange() else { return }
        emulator.addBreakpoint(kind: newBpKind, lo: lo, hi: hi)
        newBpLoText = ""
        newBpHiText = ""
    }
    private func parseHex(_ s: String) -> UInt32? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "0x", with: "")
        return UInt32(trimmed, radix: 16)
    }

    // ----------------------------------------------------------- Save slots
    private var saveStateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save States").font(.headline)
            Text("⌘1-9 save · ⇧⌘1-9 load")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(1...9, id: \.self) { slot in
                HStack {
                    Text("Slot \(slot)").font(.system(.caption, design: .monospaced))
                    Spacer()
                    if let s = emulator.saveStateSlots[slot] {
                        Text(s.savedAt, style: .time)
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Load") { emulator.quickLoad(slot: slot) }
                            .controlSize(.mini)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                    Button("Save") { emulator.quickSave(slot: slot) }
                        .controlSize(.mini)
                }
            }
        }
    }
}

/// Renders a decoded 8x8 tile (64 palette indices) as a small image.
private struct TileView: View {
    let pixels: [UInt8]
    let paletteOffset: Int
    let colors: [(UInt8, UInt8, UInt8)]

    var body: some View {
        Canvas { ctx, size in
            let cell = min(size.width / 8.0, size.height / 8.0)
            for y in 0..<8 {
                for x in 0..<8 {
                    let idx = pixels[y*8 + x]
                    let palIdx = paletteOffset + Int(idx)
                    let c = palIdx < colors.count ? colors[palIdx] : (0, 0, 0)
                    let color = Color(.sRGB,
                                      red: Double(c.0)/255.0,
                                      green: Double(c.1)/255.0,
                                      blue: Double(c.2)/255.0)
                    let rect = CGRect(x: Double(x) * cell,
                                      y: Double(y) * cell,
                                      width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}
