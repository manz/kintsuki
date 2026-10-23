import SwiftUI
import AppKit
import CKintsuki

/// VRAM Map. Records which VRAM words the PPU draws from and who writes
/// them (`Emulator.vramMapStart`), then shows VRAM a word a pixel, 256
/// words a row: a colour per layer, orange for words written but never
/// drawn (dead), near black for words nobody touched (free). The PPU's
/// registers outline where each enabled layer starts and how far it can
/// reach; the sidebar lists the runs no layer read, the room to pack into.
struct VRAMMapView: View {
    let emulator: Emulator
    @State private var map: VRAMMap? = nil
    @State private var runs: [VRAMRun] = []
    @State private var image: CGImage? = nil
    @State private var regions: [VRAMRegion] = []
    @State private var showLayout = true
    @State private var showReadRuns = false
    @State private var minWords = 16
    @State private var hovered: Int? = nil
    @State private var selected: VRAMRun? = nil

    static let rowWords = 256
    static let scale: CGFloat = 3

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let image {
                    ScrollView([.vertical, .horizontal]) {
                        HStack(alignment: .top, spacing: 6) {
                            rowLabels(rows: image.height)
                            canvas(image)
                        }
                        .padding(8)
                    }
                    .background(Color.black)
                } else {
                    ContentUnavailableView("Record to map VRAM",
                                           systemImage: "square.grid.3x3",
                                           description: Text("Play while recording: every word a layer draws from, and every write, lands on the map."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 820, minHeight: 440)

            sidebar
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        }
        .frame(minWidth: 1100, minHeight: 480)
        .onAppear { rebuild() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if emulator.vramMapRecording { rebuild() }
        }
    }

    // ----- Toolbar -----
    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(emulator.vramMapRecording ? "Stop" : "Record") {
                if emulator.vramMapRecording { emulator.vramMapStop() } else { emulator.vramMapStart() }
                selected = nil
                rebuild()
            }
            .disabled(emulator.loadedROM == nil)
            Button("Clear") {
                emulator.vramMapClear()
                selected = nil
                rebuild()
            }
            .disabled(map == nil)
            Toggle("PPU layout", isOn: $showLayout)
                .toggleStyle(.checkbox)
            Spacer()
            legend
        }
        .padding(8)
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(Array(["BG1", "BG2", "BG3", "BG4", "OBJ"].enumerated()), id: \.offset) { i, name in
                chip(VRAMMapImage.layerColors[i], name)
            }
            chip(VRAMMapImage.dead, "dead")
            chip(VRAMMapImage.free, "free")
        }
    }

    private func chip(_ c: (UInt8, UInt8, UInt8), _ name: String) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(rgb(c)).frame(width: 10, height: 10)
                .overlay(Rectangle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // ----- Map -----
    private func rowLabels(rows: Int) -> some View {
        // A label every 4 rows: 0x400 words, a 32x32 tilemap screen.
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<(rows + 3) / 4, id: \.self) { i in
                Text(String(format: "$%04X", i * 4 * Self.rowWords))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(height: 4 * Self.scale, alignment: .top)
            }
        }
    }

    private func canvas(_ image: CGImage) -> some View {
        let w = CGFloat(image.width) * Self.scale
        let h = CGFloat(image.height) * Self.scale
        return Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: w, height: h)
            .overlay {
                Canvas { ctx, _ in
                    // 0x400-word rules: where tilemap screens and tile banks align.
                    for row in stride(from: 4, to: image.height, by: 4) {
                        let y = CGFloat(row) * Self.scale
                        ctx.fill(Path(CGRect(x: 0, y: y, width: w, height: 0.5)),
                                 with: .color(.white.opacity(0.12)))
                    }
                    if showLayout {
                        for region in regions {
                            let tiles = region.name.contains("tiles")
                            ctx.stroke(span(region.start, region.end),
                                       with: .color(rgb(VRAMMapImage.layerColors[region.layer])),
                                       style: StrokeStyle(lineWidth: 1.5, dash: tiles ? [4, 3] : []))
                        }
                    }
                    if let selected {
                        ctx.stroke(span(selected.start, selected.end), with: .color(.white), lineWidth: 2)
                    }
                    if let hovered {
                        ctx.stroke(span(hovered, hovered), with: .color(.white), lineWidth: 1)
                    }
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let word = Int(p.y / Self.scale) * Self.rowWords + Int(p.x / Self.scale)
                    hovered = (0..<(map?.words ?? 0)).contains(word) ? word : nil
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture {
                if let hovered { selected = runs.first { $0.start <= hovered && hovered <= $0.end } }
            }
    }

    /// The outline of words `start`...`end`, row by row.
    private func span(_ start: Int, _ end: Int) -> Path {
        var path = Path()
        let s = Self.scale
        for row in start / Self.rowWords...end / Self.rowWords {
            let lo = max(start, row * Self.rowWords) % Self.rowWords
            let hi = min(end, row * Self.rowWords + Self.rowWords - 1) % Self.rowWords
            path.addRect(CGRect(x: CGFloat(lo) * s, y: CGFloat(row) * s,
                                width: CGFloat(hi - lo + 1) * s, height: s))
        }
        return path
    }

    // ----- Sidebar -----
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            wordDetail
            Divider()
            totals
            Divider()
            HStack {
                Toggle("Read runs too", isOn: $showReadRuns).toggleStyle(.checkbox)
                Spacer()
                Picker("Min", selection: $minWords) {
                    Text("≥ 1").tag(1)
                    Text("≥ 16").tag(16)
                    Text("≥ 64").tag(64)
                    Text("≥ 256").tag(256)
                }
                .frame(width: 110)
            }
            .font(.caption)
            List(listedRuns, selection: Binding(get: { selected?.id },
                                                set: { id in selected = runs.first { $0.id == id } })) { run in
                runRow(run).tag(run.id)
            }
            .listStyle(.plain)
        }
        .padding(8)
    }

    private var listedRuns: [VRAMRun] {
        runs.filter { ($0.kind != .read || showReadRuns) && $0.words >= minWords }
    }

    @ViewBuilder
    private var wordDetail: some View {
        if let map, let word = hovered ?? selected?.start {
            let reads = map.reads[word]
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "$%04X  (byte $%05X)", word, word * 2))
                    .font(.system(.body, design: .monospaced))
                Text(reads == 0 ? "no layer drew from it" : VRAMMap.layerNames(reads).joined(separator: ", "))
                    .font(.caption)
                Text(map.writes[word] == 0 ? "never written"
                     : "\(map.writes[word]) writes, last by \(emulator.pcLabel(map.writers[word]))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let inside = regions.filter { $0.start <= word && word <= $0.end }.map(\.name)
                if !inside.isEmpty {
                    Text("PPU: " + inside.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Hover a word").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var totals: some View {
        let words = { (kind: VRAMRun.Kind) in runs.filter { $0.kind == kind }.reduce(0) { $0 + $1.words } }
        return HStack(spacing: 12) {
            Text("read \(words(.read))")
            Text("dead \(words(.dead))").foregroundStyle(rgb(VRAMMapImage.dead))
            Text("free \(words(.free))")
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func runRow(_ run: VRAMRun) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(String(format: "$%04X-$%04X", run.start, run.end))
                    .font(.system(.caption, design: .monospaced))
                Text("\(run.words)w").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(run.kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(run.kind == .dead ? rgb(VRAMMapImage.dead) : .secondary)
            }
            let detail = run.kind == .read ? VRAMMap.layerNames(run.reads).joined(separator: ", ")
                : run.writers.sorted().map { emulator.pcLabel($0) }.joined(separator: " ")
            if !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    // ----- Helpers -----
    private func rebuild() {
        map = emulator.vramMap()
        runs = map?.runs() ?? []
        image = map.flatMap { makeImage($0) }
        if let selected { self.selected = runs.first { $0.start <= selected.start && selected.start <= $0.end } }
        if let p = emulator.ppuState() {
            regions = VRAMLayout.regions(bgmode: p.bgmode, sc: [p.bg1sc, p.bg2sc, p.bg3sc, p.bg4sc],
                                         nba: [p.bg12nba, p.bg34nba], obsel: p.obsel,
                                         layers: p.tm | p.ts, words: map?.words ?? 0x8000)
        }
    }

    private func makeImage(_ map: VRAMMap) -> CGImage? {
        let rows = map.words / Self.rowWords
        let data = Data(VRAMMapImage.rgba(map)) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: Self.rowWords, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Self.rowWords * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func rgb(_ c: (UInt8, UInt8, UInt8)) -> Color {
        Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255)
    }
}
