import SwiftUI
import AppKit
import CKintsuki

/// HDMA Inspector. Two halves:
///   - Left: per-channel detail rows (target reg name, transfer mode,
///     source bank:addr, indirect bank:addr, current line counter,
///     fires-this-frame from the scanline mask).
///   - Right: 8-column scanline strip showing which channel fired on
///     each scanline of the previous frame.
/// Source addresses link into the Memory Viewer so you can drill into
/// the table that's driving the raster effect.
struct HDMAInspectorView: View {
    let emulator: Emulator
    @Environment(\.openWindow) private var openWindow
    @State private var mask: [UInt8] = Array(repeating: 0, count: 320)
    @State private var ppu: kintsuki_ppu_state_t? = nil

    private static let channelColors: [Color] = [
        .red, .orange, .yellow, .green,
        .mint, .teal, .blue, .purple,
    ]

    var body: some View {
        HSplitView {
            channelsPane
                .frame(minWidth: 360, idealWidth: 460)
            scanlinePane
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 520)
        .onAppear { rebuild() }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            rebuild()
        }
    }

    // ----- Left: channels -----
    private var channelsPane: some View {
        ScrollView {
            VStack(spacing: 0) {
                summaryHeader
                Divider()
                ForEach(0..<8, id: \.self) { ch in
                    channelRow(ch: ch)
                    Divider()
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var summaryHeader: some View {
        let active = (0..<8).reduce(0) { acc, ch in
            acc + (firesPerChannel(ch) > 0 ? 1 : 0)
        }
        let armed = ppu.map { Int($0.hdmaen).nonzeroBitCount } ?? 0
        return HStack {
            Text("HDMA").font(.headline)
            Spacer()
            Text("\(armed) armed · \(active) firing")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func channelRow(ch: Int) -> some View {
        let chData = ppu.flatMap { dmaChannel($0, index: ch) }
        let fires = firesPerChannel(ch)
        let armed = (Int(ppu?.hdmaen ?? 0) >> ch) & 1 == 1
        let active = fires > 0
        return HStack(alignment: .top, spacing: 8) {
            // Channel color chip + number
            VStack(spacing: 2) {
                Rectangle()
                    .fill(Self.channelColors[ch].opacity(armed ? 0.9 : 0.25))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text("\(ch)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white)
                    )
                Text(active ? "fire" : (armed ? "arm" : "off"))
                    .font(.caption2)
                    .foregroundStyle(active ? .green : (armed ? .orange : .secondary))
            }
            .frame(width: 36)

            // Target + mode + source
            VStack(alignment: .leading, spacing: 2) {
                if let chData {
                    HStack(spacing: 6) {
                        Text(targetLabel(dst: chData.dest))
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.semibold)
                        Text(modeLabel(ctrl: chData.ctrl))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if active {
                            Text("\(fires)/frame")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("src").font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        sourceLink(bank: chData.src_bank, addr: chData.src_addr)
                    }
                    if (chData.ctrl & 0x40) != 0 {
                        HStack(spacing: 4) {
                            Text("ind").font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)
                            sourceLink(bank: chData.ind_bank,
                                       addr: chData.ind_count)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(String(format: "line: %d", chData.line_count))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(directionLabel(ctrl: chData.ctrl))
                            .font(.caption2).foregroundStyle(.secondary)
                        if (chData.ctrl & 0x08) != 0 {
                            Text("fixed").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("(no PPU state)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .opacity(armed || active ? 1.0 : 0.55)
    }

    private func sourceLink(bank: UInt8, addr: UInt16) -> some View {
        let bus = (UInt32(bank) << 16) | UInt32(addr)
        return Button {
            let region: Emulator.MemRegion =
                (0x7E0000...0x7FFFFF).contains(bus) ? .wram : .rom
            let off = region == .wram
                ? Int(bus & 0x1FFFF)
                : romOffset(busAddr: bus)
            emulator.requestMemoryView(region: region, offset: off)
            openWindow(id: "memory")
        } label: {
            Text(String(format: "%02X:%04X", bank, addr))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .underline()
        }
        .buttonStyle(.plain)
    }

    // ----- Right: scanline strip -----
    private var scanlinePane: some View {
        VStack(spacing: 0) {
            stripHeader
            Divider()
            ScrollView([.vertical]) {
                strip.padding(.vertical, 6)
            }
            .background(Color.black)
        }
    }

    private var stripHeader: some View {
        HStack(spacing: 4) {
            ForEach(0..<8, id: \.self) { ch in
                Rectangle()
                    .fill(Self.channelColors[ch].opacity(0.85))
                    .frame(width: 18, height: 14)
                    .overlay(
                        Text("\(ch)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white)
                    )
            }
        }
        .padding(6)
    }

    private var strip: some View {
        let scanlines = mask.count
        let cellH: CGFloat = 2
        let colW: CGFloat = 18
        let totalH = CGFloat(scanlines) * cellH
        return Canvas { ctx, _ in
            // Scanline 224 = vblank boundary on NTSC; draw a faint line.
            let vblank = CGRect(x: 0, y: 224 * cellH,
                                width: 8 * colW, height: 0.5)
            ctx.fill(Path(vblank.insetBy(dx: 0, dy: -0.5)),
                     with: .color(.gray.opacity(0.4)))
            for sl in 0..<scanlines {
                let m = mask[sl]
                if m == 0 { continue }
                for ch in 0..<8 where (m & UInt8(1 << ch)) != 0 {
                    let rect = CGRect(
                        x: CGFloat(ch) * colW,
                        y: CGFloat(sl) * cellH,
                        width: colW - 2,
                        height: cellH
                    )
                    ctx.fill(Path(rect),
                             with: .color(Self.channelColors[ch]))
                }
            }
        }
        .frame(width: 8 * 18, height: totalH)
    }

    // ----- Helpers -----
    private func rebuild() {
        mask = emulator.hdmaScanlineMask()
        ppu = emulator.ppuState()
    }

    private func firesPerChannel(_ ch: Int) -> Int {
        let bit = UInt8(1 << ch)
        return mask.reduce(0) { $0 + ((($1 & bit) != 0) ? 1 : 0) }
    }

    /// Decode the dest register low byte ($21XX) into a name when
    /// known; falls back to the raw `$21XX` form otherwise.
    private func targetLabel(dst: UInt8) -> String {
        let name: String? = ppuRegName(dst)
        if let name {
            return String(format: "$21%02X %@", dst, name as CVarArg)
        }
        return String(format: "$21%02X", dst)
    }

    private func modeLabel(ctrl: UInt8) -> String {
        let mode = Int(ctrl & 0x07)
        // ares lengths table: 1, 2, 2, 4, 4, 4, 2, 4 bytes per fire.
        let lengths = [1, 2, 2, 4, 4, 4, 2, 4]
        return "mode \(mode) (\(lengths[mode])B/line)"
    }

    private func directionLabel(ctrl: UInt8) -> String {
        return (ctrl & 0x80) != 0 ? "B→A" : "A→B"
    }

    private func romOffset(busAddr: UInt32) -> Int {
        let bank = Int(busAddr >> 16) & 0x7F
        let lo = Int(busAddr & 0xFFFF)
        if lo < 0x8000 { return 0 }
        return bank * 0x8000 + (lo - 0x8000)
    }

    private func ppuRegName(_ reg: UInt8) -> String? {
        switch reg {
        case 0x00: return "INIDISP"
        case 0x01: return "OBSEL"
        case 0x02: return "OAMADDL"
        case 0x03: return "OAMADDH"
        case 0x04: return "OAMDATA"
        case 0x05: return "BGMODE"
        case 0x06: return "MOSAIC"
        case 0x07: return "BG1SC"
        case 0x08: return "BG2SC"
        case 0x09: return "BG3SC"
        case 0x0A: return "BG4SC"
        case 0x0B: return "BG12NBA"
        case 0x0C: return "BG34NBA"
        case 0x0D: return "BG1HOFS"
        case 0x0E: return "BG1VOFS"
        case 0x0F: return "BG2HOFS"
        case 0x10: return "BG2VOFS"
        case 0x11: return "BG3HOFS"
        case 0x12: return "BG3VOFS"
        case 0x13: return "BG4HOFS"
        case 0x14: return "BG4VOFS"
        case 0x15: return "VMAIN"
        case 0x16: return "VMADDL"
        case 0x17: return "VMADDH"
        case 0x18: return "VMDATAL"
        case 0x19: return "VMDATAH"
        case 0x1A: return "M7SEL"
        case 0x1B: return "M7A"
        case 0x1C: return "M7B"
        case 0x1D: return "M7C"
        case 0x1E: return "M7D"
        case 0x1F: return "M7X"
        case 0x20: return "M7Y"
        case 0x21: return "CGADD"
        case 0x22: return "CGDATA"
        case 0x23: return "W12SEL"
        case 0x24: return "W34SEL"
        case 0x25: return "WOBJSEL"
        case 0x26: return "WH0"
        case 0x27: return "WH1"
        case 0x28: return "WH2"
        case 0x29: return "WH3"
        case 0x2A: return "WBGLOG"
        case 0x2B: return "WOBJLOG"
        case 0x2C: return "TM"
        case 0x2D: return "TS"
        case 0x2E: return "TMW"
        case 0x2F: return "TSW"
        case 0x30: return "CGWSEL"
        case 0x31: return "CGADSUB"
        case 0x32: return "COLDATA"
        case 0x33: return "SETINI"
        default: return nil
        }
    }
}

/// Swift imports `kintsuki_dma_channel_t dma[8]` as an opaque 8-tuple;
/// rebind to a pointer to access by index.
private func dmaChannel(_ ppu: kintsuki_ppu_state_t,
                        index: Int) -> kintsuki_dma_channel_t {
    var copy = ppu
    return withUnsafePointer(to: &copy.dma) { tup in
        tup.withMemoryRebound(to: kintsuki_dma_channel_t.self, capacity: 8) { p in
            p[max(0, min(7, index))]
        }
    }
}
