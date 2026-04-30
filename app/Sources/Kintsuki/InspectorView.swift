import SwiftUI

/// Right-side inspector panel: CPU state, memory, save slots, FPS.
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
                saveStateSection
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 320)
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
        // 65816 P flags: NVMXDIZC (M+X are 8/16 selectors).
        let labels: [(UInt8, Character)] = [
            (0x80,"N"),(0x40,"V"),(0x20,"M"),(0x10,"X"),
            (0x08,"D"),(0x04,"I"),(0x02,"Z"),(0x01,"C"),
        ]
        return String(labels.map { (p & $0.0) != 0 ? $0.1 : Character($0.1.lowercased()) })
    }

    // --------------------------------------------------------------- Memory
    @State private var memBase: UInt32 = 0
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WRAM").font(.headline)
                Spacer()
                Stepper("$\(String(format: "%05X", memBase))",
                        value: $memBase, in: 0...UInt32(0x1FF00), step: 0x100)
                    .labelsHidden()
                    .controlSize(.mini)
                Text("$\(String(format: "%05X", memBase))")
                    .font(.system(.caption, design: .monospaced))
            }
            let bytes = emulator.readWRAM(start: memBase, length: 256)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<16) { row in
                    let off = row * 16
                    let slice = bytes.subdata(in: off..<min(off+16, bytes.count))
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
