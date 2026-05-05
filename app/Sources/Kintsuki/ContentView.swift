import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject var emulator: Emulator
    @Environment(\.modelContext) private var modelContext
    @Binding var showStateBrowser: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                EmuView(emulator: emulator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                if emulator.loadedROM == nil {
                    VStack(spacing: 12) {
                        Text("Kintsuki")
                            .font(.system(size: 40, weight: .thin, design: .monospaced))
                        Text("Open a SNES ROM to begin (⌘O)")
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                if !emulator.running, emulator.loadedROM != nil, !emulator.halted {
                    Text("PAUSED")
                        .font(.system(.title2, design: .monospaced))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if emulator.halted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Game stopped due to a crash")
                            .font(.system(.title3, design: .monospaced))
                            .bold()
                        Text(String(format: "CPU STP @ %02X:%04X",
                                    (emulator.cpuState.pc >> 16) & 0xFF,
                                    emulator.cpuState.pc & 0xFFFF))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if !emulator.crashBacktrace.isEmpty {
                            Divider()
                            ForEach(Array(emulator.crashBacktrace.enumerated()), id: \.offset) { idx, frame in
                                HStack(spacing: 8) {
                                    Text(String(format: "#%-2d", idx))
                                        .foregroundStyle(.tertiary)
                                    Text(String(format: "%02X:%04X",
                                                (frame.callsite >> 16) & 0xFF,
                                                frame.callsite & 0xFFFF))
                                    if let label = frame.label {
                                        Text("in \(label)").foregroundStyle(.secondary)
                                    }
                                }
                                .font(.system(.caption, design: .monospaced))
                            }
                        }
                        Divider()
                        Text("⌘R to reset · ⌘⇧R to reload from disk")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(.red.opacity(0.6), lineWidth: 1.5))
                }
                if emulator.loadedROM != nil {
                    VStack {
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(String(format: "%.0f fps", emulator.fps))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.black.opacity(0.4), in: Capsule())
                                if emulator.rewindFrames > 1 {
                                    let secs = Double(emulator.rewindFrames) / 60.0
                                    Text(String(format: "↶ %.1fs", secs))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.black.opacity(0.4), in: Capsule())
                                }
                            }
                            .padding(8)
                        }
                        Spacer()
                    }
                }
            }
            if emulator.inspectorOpen {
                InspectorView()
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: emulator.inspectorOpen)
        .onAppear { emulator.modelContext = modelContext }
        .sheet(isPresented: $showStateBrowser) {
            if let url = emulator.loadedROM {
                SaveStateBrowserView(romPath: url.path)
                    .environmentObject(emulator)
            }
        }
    }
}
