import SwiftUI
import AppKit

/// Hex viewer + editor for every host-readable memory region. Same
/// pause/refresh model as the other tool windows: cached snapshot,
/// 2 Hz auto-refresh, plain Emulator reference (no @EnvironmentObject)
/// so opening the window doesn't pin the emulator's redraw graph.
///
/// Editing is allowed for every region but the bus does the right thing
/// — ROM writes typically silently drop on hardware-mapped LoROM banks.
struct MemoryViewerView: View {
    let emulator: Emulator
    @State private var region: Emulator.MemRegion = .wram
    @State private var baseAddr: UInt32 = 0
    @State private var rowCount: Int = 32
    @State private var snapshot: Data = Data()
    @State private var addrInput: String = ""
    @State private var selectedOffset: Int? = nil
    @State private var editing: Bool = false
    @State private var editValue: String = ""

    private static let bytesPerRow: Int = 16

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
        .onAppear { rebuildSnapshot() }
        .onChange(of: emulator.running) { _, isRunning in
            if !isRunning { rebuildSnapshot() }
        }
        .onChange(of: emulator.loadedROM) { _, _ in rebuildSnapshot() }
        .onChange(of: region) { _, _ in
            baseAddr = 0
            selectedOffset = nil
            rebuildSnapshot()
        }
        .onChange(of: baseAddr) { _, _ in rebuildSnapshot() }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            if !editing { rebuildSnapshot() }
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

            Text(addrLabel())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                Text("Go to").font(.caption).foregroundStyle(.secondary)
                TextField("$XXXXXX", text: $addrInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 100)
                    .onSubmit { jumpToAddrInput() }
            }

            Button("Refresh") { rebuildSnapshot() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        .padding(8)
    }

    private func addrLabel() -> String {
        // Surface the absolute bus address that offset 0 of the snapshot
        // resolves to. Helps the user reason about LoROM mapping
        // ($8000:00–7D for ROM, $7E0000+ for WRAM, etc.).
        switch region {
        case .wram:  return String(format: "$%06X..%06X (WRAM via bus)",
                                   0x7E0000 + Int(baseAddr),
                                   0x7E0000 + Int(baseAddr) + snapshot.count - 1)
        case .rom:
            let bank = Int(baseAddr) / 0x8000
            let addr = (bank << 16) | 0x8000 | (Int(baseAddr) & 0x7FFF)
            return String(format: "$%06X (LoROM)", addr)
        case .sram:
            return String(format: "$70:%04X (SRAM via bus)", Int(baseAddr) & 0xFFFF)
        case .vram:  return String(format: "$%04X (VRAM bytes)", Int(baseAddr))
        case .cgram: return String(format: "$%03X (CGRAM bytes)", Int(baseAddr))
        case .oam:   return String(format: "$%03X (OAM bytes)", Int(baseAddr))
        }
    }

    // ----- Hex body -----
    private var hexBody: some View {
        ScrollView([.vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                hexHeader
                Divider()
                ForEach(0..<rowCount, id: \.self) { row in
                    hexRow(row: row)
                }
            }
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.background)
    }

    private var hexHeader: some View {
        HStack(spacing: 12) {
            Text("offset").font(.caption2).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(headerHexLine())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text("ascii").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func headerHexLine() -> String {
        return (0..<Self.bytesPerRow).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func hexRow(row: Int) -> some View {
        let offset = row * Self.bytesPerRow
        let lineBase = Int(baseAddr) + offset
        let bytes = (0..<Self.bytesPerRow).map { i -> UInt8? in
            let idx = offset + i
            return idx < snapshot.count ? snapshot[idx] : nil
        }
        return HStack(spacing: 12) {
            Text(String(format: "%06X", lineBase))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<Self.bytesPerRow, id: \.self) { i in
                    hexCell(absoluteOffset: offset + i, byte: bytes[i])
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
            // SNES text isn't ASCII but printable bytes still help spot
            // strings + alignment. Non-printable -> '.'
            if b >= 0x20 && b < 0x7F {
                s.append(Character(UnicodeScalar(b)))
            } else {
                s.append(".")
            }
        }
        return s
    }

    // ----- Actions -----
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
        emulator.writeRegion(region, offset: baseAddr + UInt32(off), byte: value)
        rebuildSnapshot()
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
        let target = min(v, regionSize > 0 ? regionSize - 1 : 0)
        // Snap to row alignment so the hex grid stays tidy.
        baseAddr = target & ~UInt32(Self.bytesPerRow - 1)
        addrInput = ""
        selectedOffset = nil
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        guard emulator.loadedROM != nil else { snapshot = Data(); return }
        let length = rowCount * Self.bytesPerRow
        let cap = region.size > 0 ? Int(region.size) - Int(baseAddr) : length
        let want = max(0, min(length, cap))
        snapshot = emulator.readRegion(region, offset: baseAddr, length: want)
    }
}
