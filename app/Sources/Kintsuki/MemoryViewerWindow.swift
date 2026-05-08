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
    @State private var selectedOffset: Int? = nil
    @State private var jumpTarget: Int? = nil
    @State private var generation: Int = 0
    @State private var cache = MemoryPageCache()

    private static let bytesPerPage: Int = 256

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if emulator.loadedROM != nil {
                HexCanvasRepresentable(
                    totalBytes: Int(region.size),
                    selectedOffset: selectedOffset,
                    jumpTarget: jumpTarget,
                    generation: generation,
                    addrLabel: { addrLabel(forOffset: $0) },
                    byteAt: { byteAt($0) },
                    onTap: { offset in selectedOffset = offset },
                    onWrite: { offset, byte in commitWrite(offset: offset, byte: byte) },
                    onMoveSelection: { offset in selectedOffset = offset },
                    onJumpHandled: { jumpTarget = nil }
                )
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
            selectedOffset = nil
            invalidate()
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            invalidate()
        }
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
                Text("Go to").font(.caption).foregroundStyle(.secondary)
                TextField("$XXXXXX", text: $addrInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 110)
                    .onSubmit { jumpToAddrInput() }
            }
            Button("Refresh") { invalidate() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        .padding(8)
    }

    /// Write a single byte through the bus, drop the affected page so
    /// the next paint reflects the new value, and bump the generation
    /// counter so SwiftUI redraws the canvas with the fresh data.
    private func commitWrite(offset: Int, byte: UInt8) {
        emulator.writeRegion(region, offset: UInt32(offset), byte: byte)
        let pageIdx = offset / Self.bytesPerPage
        cache.pages.removeValue(forKey: pageIdx)
        generation &+= 1
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
        selectedOffset = target
        jumpTarget = target
    }
}

/// Reference-typed page store so the view body can lazy-load pages
/// without tickling SwiftUI's "state modified during view update".
@MainActor
final class MemoryPageCache {
    var pages: [Int: Data] = [:]
}

// MARK: - HexCanvasRepresentable + NSView

/// SwiftUI bridge to `HexCanvasView`. The NSView owns its NSScrollView,
/// draws only visible rows, and forwards taps via the closure inputs.
struct HexCanvasRepresentable: NSViewRepresentable {
    let totalBytes: Int
    let selectedOffset: Int?
    let jumpTarget: Int?
    let generation: Int
    let addrLabel: (Int) -> String
    let byteAt: (Int) -> UInt8?
    let onTap: (Int) -> Void
    let onWrite: (Int, UInt8) -> Void
    let onMoveSelection: (Int) -> Void
    let onJumpHandled: () -> Void

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
        canvas.onTap = onTap
        canvas.onWrite = onWrite
        canvas.onMoveSelection = onMoveSelection
        canvas.totalBytes = totalBytes
        canvas.selectedOffset = selectedOffset
        scroll.documentView = canvas
        applyCanvasFrame(scroll: scroll, canvas: canvas)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? HexCanvasView else { return }
        canvas.addrLabel = addrLabel
        canvas.byteAt = byteAt
        canvas.onTap = onTap
        canvas.onWrite = onWrite
        canvas.onMoveSelection = onMoveSelection
        if canvas.totalBytes != totalBytes {
            canvas.totalBytes = totalBytes
            applyCanvasFrame(scroll: scroll, canvas: canvas)
        }
        if canvas.selectedOffset != selectedOffset {
            canvas.selectedOffset = selectedOffset
        }
        canvas.needsDisplay = true
        if let t = jumpTarget {
            canvas.scrollToOffset(t)
            onJumpHandled()
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
    var selectedOffset: Int? {
        didSet { if selectedOffset != oldValue { needsDisplay = true } }
    }
    var addrLabel: ((Int) -> String) = { _ in "" }
    var byteAt: ((Int) -> UInt8?) = { _ in nil }
    var onTap: ((Int) -> Void)? = nil
    var onWrite: ((Int, UInt8) -> Void)? = nil
    var onMoveSelection: ((Int) -> Void)? = nil
    /// Partial high nibble accumulator. While set, a hex digit was
    /// pressed at `selectedOffset`; the next digit commits both
    /// nibbles as the new byte and advances the selection.
    private var pendingNibble: UInt8? = nil {
        didSet { needsDisplay = true }
    }

    let bytesPerRow: Int = 16
    private let font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var rowHeight: CGFloat { ceil(font.boundingRectForFont.height) + 2 }
    private var addrWidth: CGFloat = 80
    private var hexCellWidth: CGFloat = 22
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

                // Selection highlight
                if let sel = selectedOffset, sel == off {
                    let rect = NSRect(x: cellX - 1, y: y,
                                      width: hexCellWidth, height: rowH - 1)
                    NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                    rect.fill()
                }

                if off < totalBytes, let b = byteAt(off) {
                    // While a high-nibble is buffered at the selected
                    // offset, render the nibble being typed in
                    // accent + the existing low nibble dimmed so the
                    // user sees what they typed before the second key.
                    if let high = pendingNibble, selectedOffset == off {
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
        guard let off = offsetAt(point: loc) else { return }
        pendingNibble = nil
        onTap?(off)
    }

    override func keyDown(with event: NSEvent) {
        guard let off = selectedOffset else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 0x7B:                                       // ←
            advanceSelection(by: -1); pendingNibble = nil; return
        case 0x7C:                                       // →
            advanceSelection(by: 1);  pendingNibble = nil; return
        case 0x7E:                                       // ↑
            advanceSelection(by: -bytesPerRow); pendingNibble = nil; return
        case 0x7D:                                       // ↓
            advanceSelection(by: bytesPerRow);  pendingNibble = nil; return
        case 0x35:                                       // Esc
            pendingNibble = nil; return
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers, let ch = chars.first else {
            super.keyDown(with: event); return
        }
        if let nibble = hexNibble(ch) {
            if let high = pendingNibble {
                let value = (high << 4) | nibble
                onWrite?(off, value)
                pendingNibble = nil
                advanceSelection(by: 1)
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

    private func advanceSelection(by delta: Int) {
        guard let cur = selectedOffset else { return }
        let next = max(0, min(totalBytes - 1, cur + delta))
        if next != cur {
            selectedOffset = next
            onMoveSelection?(next)
            scrollToOffset(next)
        }
    }

    private func offsetAt(point p: NSPoint) -> Int? {
        guard p.x >= hexAreaStart, p.x < hexAreaStart + hexAreaWidth else { return nil }
        let row = Int(p.y / rowHeight)
        let col = Int((p.x - hexAreaStart) / hexCellWidth)
        let off = row * bytesPerRow + col
        if off < 0 || off >= totalBytes { return nil }
        return off
    }
}
