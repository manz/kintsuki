import SwiftUI
import AppKit

/// Hex viewer + editor for every host-readable memory region.
///
/// Rendering: a custom `NSView` (via `NSViewRepresentable`) draws only
/// the visible rows on demand — SwiftUI's LazyVStack-of-Text approach
/// died at 524K rows × 17 cells for ROM. Bytes come from a paged cache
/// keyed by 256-byte pages so scrolling never materialises the whole
/// region; pages are evicted on region change / manual / 2 Hz refresh.
struct MemoryViewerView: View {
    let emulator: Emulator
    @State private var region: Emulator.MemRegion = .wram
    @State private var addrInput: String = ""
    @State private var addrPickerShown: Bool = false
    @State private var selection: HexSelection? = nil
    @State private var jumpTarget: Int? = nil
    @State private var generation: Int = 0
    @State private var cache = MemoryPageCache()
    @State private var markers: [HexMarker] = []
    /// Last navigation request nonce we've already honoured. Prevents
    /// the 2 Hz refresh tick from re-jumping back to the marker after
    /// the user has scrolled away (each tick re-evaluates the body
    /// which would otherwise re-call handleNavRequest with the same
    /// stale request still pending).
    @State private var lastHandledNavNonce: Int = 0
    @State private var bytesPerRow: Int = 16
    @State private var bytesPerRowInput: String = "16"
    @State private var jumpNonce: Int = 0
    @State private var compact: Bool = false

    private static let bytesPerPage: Int = 256

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if region == .rom, emulator.projectIsOpen {
                Divider()
                projectStrip
            }
            Divider()
            if emulator.loadedROM != nil {
                HexCanvasRepresentable(
                    totalBytes: Int(region.size),
                    bytesPerRow: bytesPerRow,
                    compact: compact,
                    selection: selection,
                    markers: markers,
                    classByteAt: { off in projectClassByte(at: off) },
                    jumpTarget: jumpTarget,
                    jumpNonce: jumpNonce,
                    generation: generation,
                    addrLabel: { addrLabel(forOffset: $0) },
                    byteAt: { byteAt($0) },
                    onSelectionChanged: { sel in selection = sel },
                    onWrite: { range, byte in commitWrite(range: range, byte: byte) }
                )
                if !markers.isEmpty {
                    Divider()
                    markerLegend
                }
            } else {
                ContentUnavailableView("No ROM", systemImage: "rectangle.dashed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: emulator.running) { _, isRunning in
            if !isRunning { invalidate() }
        }
        .onChange(of: emulator.loadedROM) { _, _ in invalidate() }
        .onChange(of: region) { _, _ in
            selection = nil
            invalidate()
            rebuildMarkers()
        }
        .onAppear {
            rebuildMarkers()
            handleNavRequest()
        }
        .onChange(of: emulator.memoryNavRequest) { _, _ in handleNavRequest() }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            invalidate()
            rebuildMarkers()
        }
    }

    // ----- Project overlay (kintsuki project, slice 6 UI) ----------------

    /// Project byte-class lookup hot path. Restricted to ROM region —
    /// `map.bin` is ROM-offset addressed and WRAM/VRAM/CGRAM/OAM don't
    /// have an equivalent overlay (yet).
    private func projectClassByte(at romOffset: Int) -> UInt8? {
        guard region == .rom, emulator.projectIsOpen else { return nil }
        guard romOffset >= 0 else { return nil }
        let b = emulator.projectClassify(romOffset: UInt32(romOffset))
        return b == 0 ? nil : b
    }

    /// Top strip surfacing the project overlay on ROM: shows the class
    /// under the cursor + lets the user re-tag the current selection
    /// without leaving the keyboard. Only rendered when ROM is
    /// selected and a project is open.
    @ViewBuilder
    private var projectStrip: some View {
        let cursor = selection?.cursor
        let cursorByte = cursor.flatMap { projectClassByte(at: $0) } ?? 0
        let cursorCls = Emulator.ByteClass(rawValue: cursorByte & 0x7F) ?? .unknown
        let sticky = (cursorByte & 0x80) != 0
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group.fill")
                .foregroundStyle(.purple)
                .help("Kintsuki project overlay")
            if let off = cursor {
                Text(String(format: "$%06X", off))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(cursorCls.label)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color(cursorCls.overlayColor).opacity(sticky ? 0.55 : 0.3),
                                in: Capsule())
                if sticky {
                    Text("(sticky)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("(no selection)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(Emulator.ByteClass.allUserMarkable, id: \.rawValue) { cls in
                    Button(cls.label) { markSelection(as: cls, userSticky: true) }
                }
            } label: {
                Label("Mark as…", systemImage: "tag.fill")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(selection == nil)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func markSelection(as cls: Emulator.ByteClass, userSticky: Bool) {
        guard region == .rom, let sel = selection else { return }
        let range = sel.range
        let lo = max(0, range.lowerBound)
        let hi = max(lo, range.upperBound)
        let len = hi - lo + 1
        emulator.projectMark(romOffset: UInt32(lo),
                             length: UInt32(len),
                             cls: cls,
                             userSticky: userSticky)
    }

    /// Honour an `Emulator.memoryNavRequest` exactly once per nonce.
    /// The nonce gate is what stops the 2 Hz tick from re-jumping the
    /// canvas back to the marker after the user has scrolled away —
    /// the request stays around (so a second window can also pick it
    /// up later), but each handler instance only fires on a new nonce.
    private func handleNavRequest() {
        guard let req = emulator.memoryNavRequest else { return }
        guard req.nonce != lastHandledNavNonce else { return }
        lastHandledNavNonce = req.nonce
        if region != req.region {
            region = req.region
        }
        let target = max(0, min(Int(region.size) - 1, req.offset))
        selection = .single(target)
        jumpTarget = target; jumpNonce &+= 1
        invalidate()
    }

    // ----- Toolbar -----
    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $region) {
                ForEach(Emulator.MemRegion.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            Spacer()

            HStack(spacing: 4) {
                Text("Row").font(.caption).foregroundStyle(.secondary)
                TextField("16", text: $bytesPerRowInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 38)
                    .onSubmit { commitBytesPerRow() }
            }
            Toggle("Compact", isOn: $compact)
                .toggleStyle(.checkbox)
                .help("Tighter cell spacing — fits more bytes per window width")
            goToMenu
            Button("Refresh") { invalidate() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        .padding(8)
    }

    /// "Go to…" menu — semantic targets first (BG tilemaps, char bases,
    /// OAM, CGRAM derived from PPU regs), then a free-form address
    /// popover. Replaces the always-visible TextField so the toolbar
    /// stays clean when the user isn't navigating.
    private var goToMenu: some View {
        Menu {
            ForEach(semanticTargets()) { tgt in
                Button(tgt.label) {
                    region = tgt.region
                    selection = .single(tgt.offset)
                    jumpTarget = tgt.offset; jumpNonce &+= 1
                }
            }
            Divider()
            Button("Custom address…") { addrPickerShown.toggle() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "scope")
                Text("Go to")
            }
        }
        .menuStyle(.borderlessButton)
        .frame(width: 90)
        .popover(isPresented: $addrPickerShown) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Go to address").font(.headline)
                TextField("$XXXXXX", text: $addrInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 220)
                    .onSubmit { jumpToAddrInput(); addrPickerShown = false }
                HStack {
                    Spacer()
                    Button("Jump") { jumpToAddrInput(); addrPickerShown = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(10)
        }
    }

    private var markerLegend: some View {
        // Color-chip + label pairs; each chip is a button that jumps
        // the canvas to the start of its range so the legend doubles
        // as a navigation index.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(markers) { m in
                    Button {
                        let lo = m.range.lowerBound
                        selection = .single(lo)
                        jumpTarget = lo; jumpNonce &+= 1
                    } label: {
                        HStack(spacing: 4) {
                            Rectangle()
                                .fill(Color(m.color).opacity(0.4))
                                .frame(width: 10, height: 10)
                            Text(m.label)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func commitBytesPerRow() {
        let s = bytesPerRowInput.trimmingCharacters(in: .whitespaces)
        guard let v = Int(s), v >= 1, v <= 64 else {
            bytesPerRowInput = String(bytesPerRow)
            NSSound.beep()
            return
        }
        bytesPerRow = v
        bytesPerRowInput = String(v)
    }

    /// Write `byte` to every offset in `range`. Drops touched pages
    /// so the next paint reflects the new values; bumps the generation
    /// counter so SwiftUI rebuilds the canvas snapshot.
    private func commitWrite(range: ClosedRange<Int>, byte: UInt8) {
        for off in range {
            emulator.writeRegion(region, offset: UInt32(off), byte: byte)
        }
        let firstPage = range.lowerBound / Self.bytesPerPage
        let lastPage  = range.upperBound / Self.bytesPerPage
        for p in firstPage...lastPage { cache.pages.removeValue(forKey: p) }
        generation &+= 1
    }

    // ----- Semantic targets (Go to…) + region markers ---------------------

    private struct GoTarget: Identifiable {
        let id = UUID()
        let label: String
        let region: Emulator.MemRegion
        let offset: Int
    }

    private func semanticTargets() -> [GoTarget] {
        var out: [GoTarget] = []
        guard let ppu = emulator.ppuState() else { return out }
        // BG tilemap bases — BGxSC bits 7..2 are the word base.
        for layer in 1...4 {
            let bgsc: UInt8
            switch layer {
            case 1: bgsc = ppu.bg1sc
            case 2: bgsc = ppu.bg2sc
            case 3: bgsc = ppu.bg3sc
            default: bgsc = ppu.bg4sc
            }
            let mapBaseByte = (Int(bgsc & 0xFC) << 8) << 1
            out.append(GoTarget(label: String(format: "BG%d tilemap ($%04X.w)", layer, mapBaseByte >> 1),
                                region: .vram,
                                offset: mapBaseByte & 0xFFFF))
        }
        // Char bases — BG12NBA / BG34NBA, 4-bit fields × 0x1000 words.
        let bg1nba = (Int(ppu.bg12nba) & 0x0F) * 0x1000 << 1
        let bg2nba = ((Int(ppu.bg12nba) >> 4) & 0x0F) * 0x1000 << 1
        let bg3nba = (Int(ppu.bg34nba) & 0x0F) * 0x1000 << 1
        let bg4nba = ((Int(ppu.bg34nba) >> 4) & 0x0F) * 0x1000 << 1
        out.append(GoTarget(label: String(format: "BG1 char ($%04X.w)", bg1nba >> 1),
                            region: .vram, offset: bg1nba & 0xFFFF))
        out.append(GoTarget(label: String(format: "BG2 char ($%04X.w)", bg2nba >> 1),
                            region: .vram, offset: bg2nba & 0xFFFF))
        out.append(GoTarget(label: String(format: "BG3 char ($%04X.w)", bg3nba >> 1),
                            region: .vram, offset: bg3nba & 0xFFFF))
        out.append(GoTarget(label: String(format: "BG4 char ($%04X.w)", bg4nba >> 1),
                            region: .vram, offset: bg4nba & 0xFFFF))
        out.append(GoTarget(label: "OAM start", region: .oam, offset: 0))
        out.append(GoTarget(label: "CGRAM start", region: .cgram, offset: 0))
        out.append(GoTarget(label: "WRAM $7E:0000", region: .wram, offset: 0))
        return out
    }

    /// Region markers — VRAM-only for now (BG tilemap ranges + char
    /// bases derived from PPU regs). WRAM markers would need a DMA
    /// transfer log to know which regions hold tile/tilemap data;
    /// shelved until a DMA spy ring lands.
    private func rebuildMarkers() {
        guard region == .vram, let ppu = emulator.ppuState() else {
            if !markers.isEmpty { markers = [] }
            return
        }
        var built: [HexMarker] = []
        let layerColors: [NSColor] = [
            .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        ]
        for layer in 1...4 {
            let bgsc: UInt8
            switch layer {
            case 1: bgsc = ppu.bg1sc
            case 2: bgsc = ppu.bg2sc
            case 3: bgsc = ppu.bg3sc
            default: bgsc = ppu.bg4sc
            }
            let mapBaseByte = (Int(bgsc & 0xFC) << 8) << 1
            // Plane size encoded in BGxSC bits 1..0; each sub-plane is
            // 0x800 bytes (32×32 cells × 2).
            let subPlanes: Int
            switch bgsc & 0x03 {
            case 1, 2: subPlanes = 2
            case 3:    subPlanes = 4
            default:   subPlanes = 1
            }
            let length = subPlanes * 0x800
            let lo = mapBaseByte & 0xFFFF
            let hi = min(0xFFFF, lo + length - 1)
            if lo < hi {
                built.append(HexMarker(range: lo...hi,
                                       color: layerColors[layer - 1],
                                       label: "BG\(layer) tilemap"))
            }
        }
        let nbas: [(layer: Int, base: Int)] = [
            (1, (Int(ppu.bg12nba) & 0x0F) * 0x1000 << 1),
            (2, ((Int(ppu.bg12nba) >> 4) & 0x0F) * 0x1000 << 1),
            (3, (Int(ppu.bg34nba) & 0x0F) * 0x1000 << 1),
            (4, ((Int(ppu.bg34nba) >> 4) & 0x0F) * 0x1000 << 1),
        ]
        // Char ranges aren't bounded by hardware — give them a 4 KB
        // window each as a visual hint; overlapping with another
        // marker is fine, the canvas paints first-listed wins.
        let charColors: [NSColor] = [
            .systemTeal, .systemMint, .systemYellow, .systemPink,
        ]
        for (i, e) in nbas.enumerated() {
            let lo = e.base & 0xFFFF
            let hi = min(0xFFFF, lo + 0x1000 - 1)
            if lo < hi {
                built.append(HexMarker(range: lo...hi,
                                       color: charColors[i],
                                       label: "BG\(e.layer) char"))
            }
        }
        if built != markers { markers = built }
    }

    // ----- Page cache -----
    private func byteAt(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < Int(region.size) else { return nil }
        let pageIdx = offset / Self.bytesPerPage
        let pageOff = offset % Self.bytesPerPage
        if let page = cache.pages[pageIdx] {
            return pageOff < page.count ? page[pageOff] : nil
        }
        let baseAddr = UInt32(pageIdx * Self.bytesPerPage)
        let length = min(Self.bytesPerPage, Int(region.size) - Int(baseAddr))
        let data = emulator.readRegion(region, offset: baseAddr, length: length)
        cache.pages[pageIdx] = data
        return pageOff < data.count ? data[pageOff] : nil
    }

    private func addrLabel(forOffset offset: Int) -> String {
        switch region {
        case .wram:  return String(format: "%06X", 0x7E0000 + offset)
        case .rom:
            let bank = offset / 0x8000
            let addr = (bank << 16) | 0x8000 | (offset & 0x7FFF)
            return String(format: "%06X", addr)
        case .sram:  return String(format: "70:%04X", offset & 0xFFFF)
        case .vram:  return String(format: "VRAM:%04X", offset & 0xFFFF)
        case .cgram: return String(format: "CGRM:%03X", offset & 0x1FF)
        case .oam:   return String(format: "OAM:%03X", offset & 0x3FF)
        }
    }

    // ----- Actions -----
    private func invalidate() {
        cache.pages.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    private func jumpToAddrInput() {
        var s = addrInput.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$") { s.removeFirst() }
        else if s.lowercased().hasPrefix("0x") { s.removeFirst(2) }
        guard !s.isEmpty,
              s.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }),
              let v = UInt32(s, radix: 16) else {
            NSSound.beep(); return
        }
        let regionSize = region.size
        let target = Int(min(v, regionSize > 0 ? regionSize - 1 : 0))
        addrInput = ""
        selection = .single(target)
        jumpTarget = target; jumpNonce &+= 1
    }
}

/// Reference-typed page store so the view body can lazy-load pages
/// without tickling SwiftUI's "state modified during view update".
@MainActor
final class MemoryPageCache {
    var pages: [Int: Data] = [:]
}

/// Two-anchor selection model: `anchor` is set by mouseDown / Esc /
/// non-shift movement, `cursor` slides on drag / Shift+arrow. The
/// effective byte range is the closed range bounded by both.
struct HexSelection: Equatable {
    var anchor: Int
    var cursor: Int
    var range: ClosedRange<Int> {
        min(anchor, cursor)...max(anchor, cursor)
    }
    var isCollapsed: Bool { anchor == cursor }
    static func single(_ off: Int) -> HexSelection {
        HexSelection(anchor: off, cursor: off)
    }
}

/// Coloured semantic overlay (BG tilemap, charset, OAM, .adbg-labelled
/// WRAM, etc). HexCanvasView paints a translucent tint over the cells
/// covered by `range`; the legend lives outside the canvas.
struct HexMarker: Identifiable, Equatable {
    let id = UUID()
    let range: ClosedRange<Int>
    let color: NSColor
    let label: String
    static func == (l: HexMarker, r: HexMarker) -> Bool {
        l.range == r.range && l.label == r.label
    }
}

// MARK: - HexCanvasRepresentable + NSView

/// SwiftUI bridge to `HexCanvasView`. The NSView owns its NSScrollView,
/// draws only visible rows, and forwards taps via the closure inputs.
struct HexCanvasRepresentable: NSViewRepresentable {
    let totalBytes: Int
    let bytesPerRow: Int
    let compact: Bool
    let selection: HexSelection?
    let markers: [HexMarker]
    /// Closure returning the project byte-class for a region offset, or
    /// nil when no overlay applies (no project, non-ROM region, OOB).
    /// Bit 7 is the user-sticky flag; low 7 bits are the class enum.
    let classByteAt: (Int) -> UInt8?
    let jumpTarget: Int?
    /// Bumped by the parent for each new `jumpTarget`. Used by the
    /// representable's coordinator to scroll exactly once per jump
    /// even if `jumpTarget` happens to alias a previous value (e.g.
    /// the user clicks the same legend chip twice or something on
    /// the parent re-emits the same offset).
    let jumpNonce: Int
    let generation: Int
    let addrLabel: (Int) -> String
    let byteAt: (Int) -> UInt8?
    let onSelectionChanged: (HexSelection) -> Void
    let onWrite: (ClosedRange<Int>, UInt8) -> Void

    final class Coordinator {
        var lastJumpNonce: Int = 0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let canvas = HexCanvasView(frame: .zero)
        canvas.translatesAutoresizingMaskIntoConstraints = true
        canvas.autoresizingMask = [.width]
        canvas.addrLabel = addrLabel
        canvas.byteAt = byteAt
        canvas.onSelectionChanged = onSelectionChanged
        canvas.onWrite = onWrite
        canvas.bytesPerRow = bytesPerRow
        canvas.compact = compact
        canvas.totalBytes = totalBytes
        canvas.selection = selection
        canvas.markers = markers
        canvas.classByteAt = classByteAt
        scroll.documentView = canvas
        applyCanvasFrame(scroll: scroll, canvas: canvas)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? HexCanvasView else { return }
        canvas.addrLabel = addrLabel
        canvas.byteAt = byteAt
        canvas.onSelectionChanged = onSelectionChanged
        canvas.onWrite = onWrite
        if canvas.bytesPerRow != bytesPerRow {
            canvas.bytesPerRow = bytesPerRow
            applyCanvasFrame(scroll: scroll, canvas: canvas)
        }
        if canvas.compact != compact {
            canvas.compact = compact
            applyCanvasFrame(scroll: scroll, canvas: canvas)
        }
        if canvas.totalBytes != totalBytes {
            canvas.totalBytes = totalBytes
            applyCanvasFrame(scroll: scroll, canvas: canvas)
        }
        if canvas.selection != selection {
            canvas.selection = selection
        }
        if canvas.markers != markers {
            canvas.markers = markers
        }
        canvas.classByteAt = classByteAt
        canvas.needsDisplay = true
        // Coordinator-gated scroll: only honour a jumpTarget when its
        // nonce is fresh. Without this, every body re-eval (cache
        // invalidation, marker rebuild, BG @State pulse) saw the
        // same jumpTarget value and re-scrolled the canvas back to
        // the marker — the user could never wander away from the
        // initial focus point.
        if let t = jumpTarget, jumpNonce != context.coordinator.lastJumpNonce {
            context.coordinator.lastJumpNonce = jumpNonce
            canvas.scrollToOffset(t)
        }
    }

    /// NSScrollView uses the documentView's *frame*, not its
    /// intrinsicContentSize, to size the scrollable area. Without an
    /// explicit frame set on every totalBytes change the canvas stayed
    /// the size of the clip view and scrolling capped at the first
    /// page — locking the user on row 0 of an 8 MB region.
    private func applyCanvasFrame(scroll: NSScrollView, canvas: HexCanvasView) {
        let totalRows = (canvas.totalBytes + canvas.bytesPerRow - 1) / canvas.bytesPerRow
        let height = canvas.rowHeight * CGFloat(totalRows + 1)
        let width = max(scroll.contentView.bounds.width, 600)
        canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
}

/// Custom NSView that draws hex rows on demand. Owns no model state
/// beyond what `MemoryViewerView` hands it through `addrLabel` /
/// `byteAt` closures, so the view is a thin renderer + hit-tester.
final class HexCanvasView: NSView {
    var totalBytes: Int = 0 {
        didSet {
            if totalBytes != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true }
        }
    }
    var selection: HexSelection? {
        didSet { if selection != oldValue { needsDisplay = true } }
    }
    var markers: [HexMarker] = [] {
        didSet { needsDisplay = true }
    }
    /// Project byte-class overlay. Closure-fed so we don't have to copy
    /// the full map.bin into the canvas on every paint — the parent
    /// view does the FFI hop once per cell on demand.
    var classByteAt: ((Int) -> UInt8?) = { _ in nil }
    var addrLabel: ((Int) -> String) = { _ in "" }
    var byteAt: ((Int) -> UInt8?) = { _ in nil }
    var onSelectionChanged: ((HexSelection) -> Void)? = nil
    var onWrite: ((ClosedRange<Int>, UInt8) -> Void)? = nil
    /// Partial high nibble accumulator. While set, a hex digit was
    /// pressed at the selection cursor; the next digit commits the
    /// composed byte across the selection range and advances by 1.
    private var pendingNibble: UInt8? = nil {
        didSet { needsDisplay = true }
    }

    var bytesPerRow: Int = 16 {
        didSet {
            if bytesPerRow != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true }
        }
    }
    /// Compact mode shrinks the per-byte cell (22 → 16 px) so a 16-wide
    /// row fits in ~256 px instead of ~352. Useful at narrow window
    /// widths or when the user wants a denser hex view.
    var compact: Bool = false {
        didSet {
            if compact != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true }
        }
    }
    private let font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var rowHeight: CGFloat { ceil(font.boundingRectForFont.height) + 2 }
    private var addrWidth: CGFloat = 80
    private var hexCellWidth: CGFloat { compact ? 16 : 22 }
    private var hexAreaStart: CGFloat { addrWidth + 8 }
    private var hexAreaWidth: CGFloat { hexCellWidth * CGFloat(bytesPerRow) }
    private var asciiStart: CGFloat { hexAreaStart + hexAreaWidth + 12 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool {
        pendingNibble = nil
        needsDisplay = true
        return true
    }

    override var intrinsicContentSize: NSSize {
        let rows = (totalBytes + bytesPerRow - 1) / bytesPerRow
        let height = rowHeight * CGFloat(rows + 1) // +1 row for header padding
        return NSSize(width: 600, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard totalBytes > 0 else { return }

        let rowH = rowHeight
        let totalRows = (totalBytes + bytesPerRow - 1) / bytesPerRow
        // Negative dirtyRect (AppKit hands us partial-overlap rects with
        // negative origins for off-canvas scrolling) collapses both
        // bounds → range fatal. Clamp + ensure lastRow >= firstRow.
        let rawFirst = Int((dirtyRect.minY / rowH).rounded(.down)) - 1
        let rawLast  = Int((dirtyRect.maxY / rowH).rounded(.up)) + 1
        let firstRow = min(max(0, rawFirst), totalRows)
        let lastRow  = min(max(firstRow, rawLast), totalRows)
        guard firstRow < lastRow else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let dim: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let selRange = selection?.range
        let cursor = selection?.cursor

        for row in firstRow..<lastRow {
            let y = CGFloat(row) * rowH
            let rowOffset = row * bytesPerRow
            // Address column
            let addrStr = addrLabel(rowOffset)
            (addrStr as NSString).draw(at: NSPoint(x: 4, y: y), withAttributes: dim)

            var asciiBuf = ""
            for i in 0..<bytesPerRow {
                let off = rowOffset + i
                let cellX = hexAreaStart + CGFloat(i) * hexCellWidth

                // Project byte-class tint (slice 6 UI). Drawn first so
                // markers + selection still read on top — the class
                // tint is for at-a-glance "what kind of bytes is this
                // region" not for highlighting a focus point.
                if let cb = classByteAt(off), (cb & 0x7F) != 0 {
                    let cls = Emulator.ByteClass(rawValue: cb & 0x7F) ?? .unknown
                    let rect = NSRect(x: cellX - 1, y: y,
                                      width: hexCellWidth, height: rowH - 1)
                    let alpha: CGFloat = (cb & 0x80) != 0 ? 0.32 : 0.18
                    cls.overlayColor.withAlphaComponent(alpha).setFill()
                    rect.fill()
                }
                // Marker tint underneath everything else.
                if let mc = markerColor(at: off) {
                    let rect = NSRect(x: cellX - 1, y: y,
                                      width: hexCellWidth, height: rowH - 1)
                    mc.withAlphaComponent(0.18).setFill()
                    rect.fill()
                }
                // Selection highlight: stronger for the cursor cell.
                if let r = selRange, r.contains(off) {
                    let rect = NSRect(x: cellX - 1, y: y,
                                      width: hexCellWidth, height: rowH - 1)
                    let alpha: CGFloat = (cursor == off) ? 0.5 : 0.3
                    NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
                    rect.fill()
                }

                if off < totalBytes, let b = byteAt(off) {
                    if let high = pendingNibble, cursor == off {
                        let highStr = String(format: "%X", high)
                        let lowStr  = String(format: "%X", b & 0x0F)
                        let hiAttrs: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: NSColor.controlAccentColor,
                        ]
                        (highStr as NSString).draw(at: NSPoint(x: cellX + 2, y: y),
                                                    withAttributes: hiAttrs)
                        (lowStr as NSString).draw(at: NSPoint(x: cellX + 12, y: y),
                                                   withAttributes: dim)
                    } else {
                        let s = String(format: "%02X", b)
                        (s as NSString).draw(at: NSPoint(x: cellX + 2, y: y),
                                             withAttributes: attrs)
                    }
                    asciiBuf.append((b >= 0x20 && b < 0x7F)
                                    ? Character(UnicodeScalar(b))
                                    : ".")
                } else {
                    asciiBuf.append(" ")
                }
            }
            // ASCII column
            (asciiBuf as NSString).draw(at: NSPoint(x: asciiStart, y: y),
                                        withAttributes: dim)
        }
    }

    private func markerColor(at offset: Int) -> NSColor? {
        // First marker wins. Markers are typically non-overlapping
        // (BG1 tilemap vs BG12 charset) but if they ever intersect the
        // earlier-listed marker takes the cell.
        for m in markers where m.range.contains(offset) { return m.color }
        return nil
    }

    func scrollToOffset(_ offset: Int) {
        let row = offset / bytesPerRow
        let y = CGFloat(row) * rowHeight
        let rect = NSRect(x: 0, y: y - rowHeight,
                          width: bounds.width, height: rowHeight * 4)
        scrollToVisible(rect)
    }

    // ----- Hit testing -----
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let loc = convert(event.locationInWindow, from: nil)
        // No clamping on the initial click — clicking the empty
        // gutter / address column shouldn't snap selection to row 0
        // (which the user reads as "jumped to the start of the
        // session"). Drag still uses clamping so a drag that started
        // inside the hex area can extend past its left/right margins.
        guard let off = offsetAt(point: loc, clamping: false) else { return }
        pendingNibble = nil
        let extend = event.modifierFlags.contains(.shift)
        if extend, let cur = selection {
            updateSelection(HexSelection(anchor: cur.anchor, cursor: off))
        } else {
            updateSelection(.single(off))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard let off = offsetAt(point: loc, clamping: true),
              let cur = selection else { return }
        updateSelection(HexSelection(anchor: cur.anchor, cursor: off))
    }

    override func keyDown(with event: NSEvent) {
        guard selection != nil else { super.keyDown(with: event); return }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 0x7B: moveCursor(by: -1, extend: shift); pendingNibble = nil; return     // ←
        case 0x7C: moveCursor(by:  1, extend: shift); pendingNibble = nil; return     // →
        case 0x7E: moveCursor(by: -bytesPerRow, extend: shift); pendingNibble = nil; return // ↑
        case 0x7D: moveCursor(by:  bytesPerRow, extend: shift); pendingNibble = nil; return // ↓
        case 0x33:                                       // Backspace
            // Convention: zero every byte in the selection range.
            if let r = selection?.range { onWrite?(r, 0) }
            pendingNibble = nil
            return
        case 0x35:                                       // Esc
            pendingNibble = nil
            if let cur = selection { updateSelection(.single(cur.cursor)) }
            return
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers, let ch = chars.first else {
            super.keyDown(with: event); return
        }
        if let nibble = hexNibble(ch) {
            if let high = pendingNibble, let r = selection?.range {
                let value = (high << 4) | nibble
                onWrite?(r, value)
                pendingNibble = nil
                moveCursor(by: 1, extend: false)
            } else {
                pendingNibble = nibble
            }
            return
        }
        super.keyDown(with: event)
    }

    private func hexNibble(_ c: Character) -> UInt8? {
        guard let ascii = c.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return ascii - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return 10 + ascii - UInt8(ascii: "a")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return 10 + ascii - UInt8(ascii: "A")
        default: return nil
        }
    }

    private func moveCursor(by delta: Int, extend: Bool) {
        guard let cur = selection else { return }
        let next = max(0, min(totalBytes - 1, cur.cursor + delta))
        let newSel = extend
            ? HexSelection(anchor: cur.anchor, cursor: next)
            : HexSelection.single(next)
        updateSelection(newSel)
        scrollToOffset(next)
    }

    private func updateSelection(_ sel: HexSelection) {
        selection = sel
        onSelectionChanged?(sel)
    }

    /// Map a local point to a byte offset. When `clamping` is true the
    /// caller wants the closest valid offset (used by drag) — clicks
    /// outside the hex area still snap to the nearest column.
    private func offsetAt(point p: NSPoint, clamping: Bool = false) -> Int? {
        let inside = p.x >= hexAreaStart && p.x < hexAreaStart + hexAreaWidth
        if !inside, !clamping { return nil }
        let col: Int = inside
            ? Int((p.x - hexAreaStart) / hexCellWidth)
            : (p.x < hexAreaStart ? 0 : bytesPerRow - 1)
        let row = max(0, Int(p.y / rowHeight))
        let off = row * bytesPerRow + max(0, min(bytesPerRow - 1, col))
        if off < 0 { return 0 }
        if off >= totalBytes { return totalBytes - 1 }
        return off
    }
}
