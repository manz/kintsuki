import SwiftUI
import AppKit

/// Reference-typed page store so MemoryViewerView can mutate the dict
/// from inside row body lazy-loads without triggering SwiftUI's
/// "state modified during view update" complaint.
@MainActor
final class MemoryPageCache {
    var pages: [Int: Data] = [:]
}

/// Hex viewer + editor for every host-readable memory region.
///
/// Pages on demand: rows render through a 256-byte page cache so an
/// 8 MB ROM region scrolls without ever materialising the whole region
/// in one go. Auto-refresh (2 Hz) just bumps a generation counter —
/// pages are invalidated lazily as rows redraw, so off-screen pages
/// don't get re-fetched until the user scrolls back to them.
struct MemoryViewerView: View {
    let emulator: Emulator
    @State private var region: Emulator.MemRegion = .wram
    @State private var addrInput: String = ""
    @State private var selectedOffset: Int? = nil
    @State private var editing: Bool = false
    @State private var editValue: String = ""
    @State private var jumpRow: Int? = nil
    /// Reference-type cache holding decoded pages. Lives behind
    /// @State so SwiftUI doesn't yell about "mutating state during
    /// view update" when a row body lazily fetches its missing page.
    @State private var cache = MemoryPageCache()
    /// Bumped by the 2 Hz timer (or manual refresh) to invalidate
    /// `cache`. Visible rows re-fetch their page on next render.
    @State private var generation: Int = 0

    private static let bytesPerRow: Int = 16
    private static let rowsPerPage: Int = 16
    private static let bytesPerPage: Int = bytesPerRow * rowsPerPage   // 256

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if emulator.loadedROM != nil {
                hexBody
            } else {
                ContentUnavailableView("No ROM",
                                       systemImage: "rectangle.dashed")
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
            jumpRow = 0
            invalidate()
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            if !editing { invalidate() }
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
                    .frame(width: 100)
                    .onSubmit { jumpToAddrInput() }
            }

            Button("Refresh") { invalidate() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        .padding(8)
    }

    // ----- Hex body -----
    private var hexBody: some View {
        let totalBytes = Int(region.size)
        let totalRows = (totalBytes + Self.bytesPerRow - 1) / Self.bytesPerRow
        return ScrollViewReader { scroller in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    hexHeader
                    Divider()
                    ForEach(0..<totalRows, id: \.self) { row in
                        hexRow(row: row)
                            .id(row)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(.background)
            .onChange(of: jumpRow) { _, target in
                if let t = target {
                    withAnimation(.none) { scroller.scrollTo(t, anchor: .top) }
                    jumpRow = nil
                }
            }
        }
    }

    private var hexHeader: some View {
        HStack(spacing: 12) {
            Text("offset").font(.caption2).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text((0..<Self.bytesPerRow).map { String(format: "%02X", $0) }
                    .joined(separator: " "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text("ascii").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func hexRow(row: Int) -> some View {
        let rowOffset = row * Self.bytesPerRow
        let bytes = (0..<Self.bytesPerRow).map { i -> UInt8? in
            byteAt(rowOffset + i)
        }
        return HStack(spacing: 12) {
            Text(addrLabel(forOffset: rowOffset))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<Self.bytesPerRow, id: \.self) { i in
                    hexCell(absoluteOffset: rowOffset + i, byte: bytes[i])
                }
            }
            Spacer()
            Text(asciiRow(bytes))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func hexCell(absoluteOffset: Int, byte: UInt8?) -> some View {
        if let b = byte {
            let isSelected = selectedOffset == absoluteOffset
            if isSelected, editing {
                TextField("", text: $editValue)
                    .textFieldStyle(.plain)
                    .frame(width: 22)
                    .background(Color.accentColor.opacity(0.4))
                    .onSubmit { commitEdit() }
                    .onExitCommand { editing = false; editValue = "" }
            } else {
                Text(String(format: "%02X", b))
                    .frame(width: 22)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        selectedOffset = absoluteOffset
                        editValue = String(format: "%02X", b)
                        editing = true
                    }
                    .onTapGesture {
                        selectedOffset = absoluteOffset
                    }
            }
        } else {
            Text("--").foregroundStyle(.secondary).frame(width: 22)
        }
    }

    private func asciiRow(_ bytes: [UInt8?]) -> String {
        var s = ""
        for b in bytes {
            guard let b else { s.append(" "); continue }
            if b >= 0x20 && b < 0x7F {
                s.append(Character(UnicodeScalar(b)))
            } else {
                s.append(".")
            }
        }
        return s
    }

    // ----- Page cache -----
    private func byteAt(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < Int(region.size) else { return nil }
        let pageIdx = offset / Self.bytesPerPage
        let pageOff = offset % Self.bytesPerPage
        if let page = cache.pages[pageIdx] {
            return pageOff < page.count ? page[pageOff] : nil
        }
        // Fetch the missing page synchronously — readRegion is one
        // FFI hop for WRAM/SRAM (kintsuki_read_range) and a small
        // bounded-loop for VRAM/CGRAM/OAM. Sub-100µs per page.
        let baseAddr = UInt32(pageIdx * Self.bytesPerPage)
        let length = min(Self.bytesPerPage, Int(region.size) - Int(baseAddr))
        let data = emulator.readRegion(region, offset: baseAddr, length: length)
        // Reference-typed cache → mutating its dict doesn't tickle
        // SwiftUI's "modified state during view update" warning, since
        // the @State only tracks the reference (unchanged).
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
        // @State change forces SwiftUI to re-eval the body so visible
        // rows hit the empty cache and re-fetch.
        generation &+= 1
    }

    private func commitEdit() {
        defer { editing = false; editValue = "" }
        guard let off = selectedOffset else { return }
        var hex = editValue.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("$") { hex.removeFirst() }
        guard hex.count <= 2,
              hex.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }),
              let value = UInt8(hex, radix: 16) else {
            NSSound.beep()
            return
        }
        emulator.writeRegion(region, offset: UInt32(off), byte: value)
        // Drop the touched page so the new value paints on next frame.
        let pageIdx = off / Self.bytesPerPage
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
        let row = (target & ~(Self.bytesPerRow - 1)) / Self.bytesPerRow
        addrInput = ""
        selectedOffset = target
        jumpRow = row
    }
}
