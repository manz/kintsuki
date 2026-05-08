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
    @State private var pendingEdit: Int? = nil
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
                    onDoubleTap: { offset in pendingEdit = offset; selectedOffset = offset },
                    onJumpHandled: { jumpTarget = nil }
                )
            } else {
                ContentUnavailableView("No ROM", systemImage: "rectangle.dashed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let edit = pendingEdit {
                Divider()
                editBar(offset: edit)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: emulator.running) { _, isRunning in
            if !isRunning { invalidate() }
        }
        .onChange(of: emulator.loadedROM) { _, _ in invalidate() }
        .onChange(of: region) { _, _ in
            selectedOffset = nil
            pendingEdit = nil
            invalidate()
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            if pendingEdit == nil { invalidate() }
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

    private func editBar(offset: Int) -> some View {
        let current = byteAt(offset).map { String(format: "%02X", $0) } ?? "??"
        return HStack(spacing: 8) {
            Text(String(format: "Edit %@ (current %@):",
                        addrLabel(forOffset: offset), current))
                .font(.system(.caption, design: .monospaced))
            TextField("hex", text: editBinding(),
                      onCommit: { commitEdit(at: offset) })
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .font(.system(.caption, design: .monospaced))
            Button("Cancel") { pendingEdit = nil; tempEditValue = "" }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .padding(8)
    }

    @State private var tempEditValue: String = ""
    private func editBinding() -> Binding<String> {
        Binding(
            get: { tempEditValue },
            set: { tempEditValue = $0 }
        )
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

    private func commitEdit(at offset: Int) {
        defer {
            tempEditValue = ""
            pendingEdit = nil
        }
        var hex = tempEditValue.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("$") { hex.removeFirst() }
        guard hex.count <= 2,
              hex.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }),
              let value = UInt8(hex, radix: 16) else {
            NSSound.beep(); return
        }
        emulator.writeRegion(region, offset: UInt32(offset), byte: value)
        let pageIdx = offset / Self.bytesPerPage
        cache.pages.removeValue(forKey: pageIdx)
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
    let onDoubleTap: (Int) -> Void
    let onJumpHandled: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let canvas = HexCanvasView(frame: .zero)
        canvas.addrLabel = addrLabel
        canvas.byteAt = byteAt
        canvas.onTap = onTap
        canvas.onDoubleTap = onDoubleTap
        canvas.totalBytes = totalBytes
        canvas.selectedOffset = selectedOffset
        scroll.documentView = canvas
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? HexCanvasView else { return }
        canvas.addrLabel = addrLabel
        canvas.byteAt = byteAt
        canvas.onTap = onTap
        canvas.onDoubleTap = onDoubleTap
        if canvas.totalBytes != totalBytes {
            canvas.totalBytes = totalBytes
            canvas.invalidateIntrinsicContentSize()
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
    var onDoubleTap: ((Int) -> Void)? = nil

    private let bytesPerRow: Int = 16
    private let font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var rowHeight: CGFloat { ceil(font.boundingRectForFont.height) + 2 }
    private var addrWidth: CGFloat = 80
    private var hexCellWidth: CGFloat = 22
    private var hexAreaStart: CGFloat { addrWidth + 8 }
    private var hexAreaWidth: CGFloat { hexCellWidth * CGFloat(bytesPerRow) }
    private var asciiStart: CGFloat { hexAreaStart + hexAreaWidth + 12 }

    override var isFlipped: Bool { true }

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
                    let s = String(format: "%02X", b)
                    (s as NSString).draw(at: NSPoint(x: cellX + 2, y: y),
                                         withAttributes: attrs)
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
        let loc = convert(event.locationInWindow, from: nil)
        guard let off = offsetAt(point: loc) else { return }
        if event.clickCount >= 2 {
            onDoubleTap?(off)
        } else {
            onTap?(off)
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
