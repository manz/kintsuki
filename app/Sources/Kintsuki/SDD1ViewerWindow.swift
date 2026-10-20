import SwiftUI
import AppKit

/// S-DD1 stream viewer. Lists the decompressed DMA streams libkintsuki
/// logs for S-DD1 carts (newest first) and shows the selected stream's
/// output as a hex dump and a tile sheet (2/4/8 bpp, greyscale or the
/// live CGRAM). Same refresh model as the VRAM Viewer: plain `Emulator`
/// reference, 2 Hz auto-refresh, immediate refresh on pause.
struct SDD1ViewerView: View {
    let emulator: Emulator
    @Environment(\.openWindow) private var openWindow
    @State private var present = false
    @State private var streams: [Emulator.SDD1Stream] = []
    @State private var selection: Emulator.SDD1Stream.Key? = nil
    /// Decompressed bytes of `selection`. Kept after the stream is
    /// evicted from the log so the view doesn't blank mid-inspection.
    @State private var data: [UInt8] = []
    /// Metadata of the stream `data` came from (survives eviction too).
    @State private var shownStream: Emulator.SDD1Stream? = nil
    @State private var bpp: TileBpp = .bpp4
    @State private var widthTiles: Int = 16
    @State private var useCGRAM = false
    @State private var paletteIndex: Int = 0
    @State private var sheet: TileSheet? = nil

    private static let scale: CGFloat = 2

    var body: some View {
        Group {
            if present {
                HSplitView {
                    streamList.frame(minWidth: 520)
                    detail.frame(minWidth: 380, idealWidth: 460)
                }
            } else {
                ContentUnavailableView("No S-DD1",
                                       systemImage: "shippingbox",
                                       description: Text("The loaded cart has no S-DD1 chip."))
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .onAppear { refresh() }
        .onChange(of: emulator.running) { _, isRunning in
            if !isRunning { refresh() }
        }
        .onChange(of: emulator.loadedROM) { _, _ in
            selection = nil
            refresh()
        }
        .onChange(of: selection) { _, _ in reloadData() }
        .onChange(of: bpp) { _, _ in rebuildSheet() }
        .onChange(of: widthTiles) { _, _ in rebuildSheet() }
        .onChange(of: useCGRAM) { _, _ in rebuildSheet() }
        .onChange(of: paletteIndex) { _, _ in rebuildSheet() }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    // ----- Stream list -----
    private var streamList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("S-DD1 streams (\(streams.count))").font(.headline)
                Spacer()
                Button("Refresh") { refresh() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Clear") {
                    emulator.sdd1LogClear()
                    refresh()
                }
                .disabled(streams.isEmpty)
            }
            .padding(8)
            Divider()
            Table(streams, selection: $selection) {
                TableColumn("Frame") { s in mono("\(s.frame)") }
                    .width(min: 50, ideal: 70)
                TableColumn("Caller") { s in mono(emulator.pcLabel(s.callerPc)) }
                    .width(min: 80, ideal: 130)
                TableColumn("Source") { s in
                    mono(String(format: "$%06X  rom $%06X", s.busAddr, s.romOffset))
                }
                .width(min: 140, ideal: 170)
                TableColumn("Size") { s in
                    mono(String(format: "%d → %d", s.compressedSize, s.captured))
                }
                .width(min: 80, ideal: 100)
                TableColumn("Dest") { s in mono(destLabel(s)) }
                    .width(min: 90, ideal: 120)
                TableColumn("Done") { s in
                    Image(systemName: s.complete ? "checkmark" : "ellipsis")
                        .foregroundStyle(s.complete ? Color.secondary : Color.orange)
                }
                .width(36)
            }
        }
    }

    // ----- Detail -----
    @ViewBuilder
    private var detail: some View {
        if let s = shownStream, !data.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                streamHeader(s)
                Divider()
                VSplitView {
                    tilePreview.frame(minHeight: 160)
                    hexView.frame(minHeight: 120)
                }
            }
        } else {
            ContentUnavailableView("Select a stream", systemImage: "list.bullet.rectangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func streamHeader(_ s: Emulator.SDD1Stream) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: "$%06X", s.busAddr)).font(.headline.monospaced())
                if selectedStream == nil {
                    Text("evicted from log").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export .bin…") { exportBin(s) }
                Button("Export .png…") { exportPNG(s) }.disabled(sheet == nil)
            }
            metaRow("ROM offset", String(format: "$%06X", s.romOffset))
            metaRow("Size", String(format: "%d compressed → %d decompressed (DMA %d)%@",
                                   s.compressedSize, s.captured, s.size,
                                   s.complete ? "" : ", in progress"))
            metaRow("Channel", "\(s.channel) → $21\(String(format: "%02X", s.dstReg))")
            HStack {
                Text("Caller").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                linkButton(emulator.pcLabel(s.callerPc)) {
                    emulator.requestDisasmView(pc: s.callerPc)
                    openWindow(id: "debugger")
                }
            }
            HStack {
                Text("Dest").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                if s.isVRAMWrite {
                    linkButton(destLabel(s)) {
                        emulator.requestVRAMTile(byteOffset: Int(s.vramAddr) << 1, bpp: bpp.rawValue)
                        openWindow(id: "vram")
                    }
                } else {
                    mono(destLabel(s))
                }
            }
        }
        .padding(8)
    }

    private var tilePreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewToolbar
            Divider()
            ScrollView([.vertical, .horizontal]) {
                if let sheet, let img = sheet.cgImage {
                    Image(decorative: img, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: CGFloat(sheet.width) * Self.scale,
                               height: CGFloat(sheet.height) * Self.scale)
                        .padding(8)
                }
            }
            .background(Color.black)
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 10) {
            Picker("Format", selection: $bpp) {
                Text("2 bpp").tag(TileBpp.bpp2)
                Text("4 bpp").tag(TileBpp.bpp4)
                Text("8 bpp").tag(TileBpp.bpp8)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            Stepper(value: $widthTiles, in: 1...64) {
                Text("\(widthTiles) tiles wide").font(.caption.monospacedDigit())
            }
            Toggle("CGRAM", isOn: $useCGRAM).toggleStyle(.checkbox)
            Stepper(value: $paletteIndex, in: 0...maxPaletteIndex) {
                Text(String(format: "$%02X", paletteIndex * bpp.paletteStride))
                    .font(.caption.monospaced())
            }
            .disabled(!useCGRAM || bpp == .bpp8)
            Spacer()
        }
        .padding(8)
    }

    private var hexView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<HexDump.rowCount(data.count), id: \.self) { r in
                    Text(HexDump.row(data, r))
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ----- Small views -----
    private func mono(_ s: String) -> some View {
        Text(s).font(.system(.caption, design: .monospaced))
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            mono(v)
            Spacer()
        }
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            mono(title).foregroundStyle(Color.accentColor).underline()
        }
        .buttonStyle(.plain)
    }

    private func destLabel(_ s: Emulator.SDD1Stream) -> String {
        if s.isVRAMWrite { return String(format: "VRAM $%04X.w", s.vramAddr) }
        if s.isWRAMWrite { return String(format: "WRAM $%06X", 0x7E0000 + (s.wramAddr & 0x1FFFF)) }
        return String(format: "$21%02X", s.dstReg)
    }

    private var maxPaletteIndex: Int {
        bpp == .bpp8 ? 0 : 256 / bpp.paletteStride - 1
    }

    private var selectedStream: Emulator.SDD1Stream? {
        streams.first { $0.key == selection }
    }

    // ----- Refresh -----
    private func refresh() {
        present = emulator.sdd1Present
        streams = present ? emulator.sdd1Streams() : []
        // An in-progress stream keeps growing; re-pull until it settles.
        if let s = selectedStream, s.captured != data.count { reloadData() }
    }

    private func reloadData() {
        guard let key = selection else {
            data = []
            shownStream = nil
            sheet = nil
            return
        }
        if let d = emulator.sdd1StreamData(key) {
            data = [UInt8](d)
            shownStream = selectedStream
        }
        rebuildSheet()
    }

    private func rebuildSheet() {
        guard !data.isEmpty else { sheet = nil; return }
        if paletteIndex > maxPaletteIndex { paletteIndex = maxPaletteIndex }
        let palette = useCGRAM ? TilePalette.rgb(fromCGRAM: emulator.cgramSnapshot())
                               : TilePalette.greyscale(bpp)
        let base = useCGRAM && bpp != .bpp8 ? paletteIndex * bpp.paletteStride : 0
        sheet = TileSheet(data: Data(data), bpp: bpp, widthTiles: widthTiles,
                          palette: palette, paletteBase: base)
    }

    // ----- Export -----
    private func exportStem(_ s: Emulator.SDD1Stream) -> String {
        String(format: "sdd1_%06X_f%llu", s.busAddr, s.frame)
    }

    private func exportBin(_ s: Emulator.SDD1Stream) {
        guard let url = savePanelURL(name: exportStem(s) + ".bin") else { return }
        writeOrAlert(Data(data), to: url)
    }

    private func exportPNG(_ s: Emulator.SDD1Stream) {
        guard let img = sheet?.cgImage,
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]),
              let url = savePanelURL(name: "\(exportStem(s))_\(bpp.rawValue)bpp.png") else { return }
        writeOrAlert(png, to: url)
    }

    private func savePanelURL(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.message = "Export S-DD1 stream"
        panel.prompt = "Export"
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func writeOrAlert(_ d: Data, to url: URL) {
        do {
            try d.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
