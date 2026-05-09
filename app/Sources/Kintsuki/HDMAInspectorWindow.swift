import SwiftUI
import AppKit

/// Per-scanline HDMA activity strip. One column per DMA channel × 320
/// rows of scanlines (NTSC 262 + headroom). A row glows in the
/// channel's colour when that channel's `Channel::hdmaTransfer` fired
/// on that scanline of the previous frame. Lets the user see at a
/// glance which raster effect is driven by which channel — Mode 7
/// rotations, mid-frame palette swaps, parallax scroll, etc.
struct HDMAInspectorView: View {
    let emulator: Emulator
    @State private var mask: [UInt8] = Array(repeating: 0, count: 320)

    private static let channelColors: [Color] = [
        .red, .orange, .yellow, .green,
        .mint, .teal, .blue, .purple,
    ]
    private static let cellHeight: CGFloat = 2
    private static let colWidth: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView([.vertical]) {
                strip
                    .padding(.vertical, 6)
            }
            .background(Color.black)
        }
        .frame(minWidth: 220, idealWidth: 260, minHeight: 480)
        .onAppear { rebuild() }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            rebuild()
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(0..<8, id: \.self) { ch in
                Rectangle()
                    .fill(Self.channelColors[ch].opacity(0.85))
                    .frame(width: Self.colWidth - 2, height: 14)
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
        let totalH = CGFloat(scanlines) * Self.cellHeight
        return Canvas { ctx, _ in
            for sl in 0..<scanlines {
                let m = mask[sl]
                if m == 0 { continue }
                for ch in 0..<8 {
                    if (m & UInt8(1 << ch)) == 0 { continue }
                    let rect = CGRect(
                        x: CGFloat(ch) * Self.colWidth,
                        y: CGFloat(sl) * Self.cellHeight,
                        width: Self.colWidth - 2,
                        height: Self.cellHeight
                    )
                    ctx.fill(Path(rect),
                             with: .color(Self.channelColors[ch]))
                }
            }
        }
        .frame(width: 8 * Self.colWidth, height: totalH)
    }

    private func rebuild() {
        mask = emulator.hdmaScanlineMask()
    }
}
