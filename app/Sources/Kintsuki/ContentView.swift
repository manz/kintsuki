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
                    CrashOverlay(emulator: emulator)
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


/// Crash overlay rendered when the CPU executes STP. Selectable text
/// (cmd-C copies the highlighted region), explicit Copy button drops the
/// full PC + backtrace onto NSPasteboard, action buttons inline so the
/// overlay doesn't block the run loop the way an NSAlert would.
private struct CrashOverlay: View {
    @ObservedObject var emulator: Emulator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.orange)
                Text("Game stopped").font(.headline)
                Spacer(minLength: 24)
                Button { copyToPasteboard() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .help("Copy crash report")
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(crashHeaderText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !emulator.crashBacktrace.isEmpty {
                    Text(backtraceText)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .textSelection(.enabled)

            HStack(spacing: 10) {
                Button("Reset") { emulator.reset() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reload from Disk") { emulator.reloadROMFromDisk() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, lineWidth: 0.5))
        .frame(maxWidth: 480)
        .shadow(radius: 14, y: 4)
    }

    private var crashHeaderText: String {
        String(format: "CPU STP @ %02X:%04X",
               (emulator.cpuState.pc >> 16) & 0xFF,
               emulator.cpuState.pc & 0xFFFF)
    }

    private var backtraceText: String {
        emulator.crashBacktrace.enumerated().map { idx, frame in
            let pc = String(format: "%02X:%04X",
                            (frame.callsite >> 16) & 0xFF,
                            frame.callsite & 0xFFFF)
            // `+offset` suffix only when non-zero — exact-start hits
            // read cleaner without a "+0x0".
            let labelPart: String
            if let name = frame.label {
                labelPart = frame.offset > 0
                    ? String(format: " in %@+0x%X", name, frame.offset)
                    : " in \(name)"
            } else {
                labelPart = ""
            }
            // Trim verbose absolute paths to just the file's basename so
            // the overlay stays readable; user can grep/IDE-jump on the
            // copied report which has the full path embedded too.
            var srcPart = ""
            if let file = frame.file, let line = frame.line {
                let base = (file as NSString).lastPathComponent
                srcPart = "  (\(base):\(line))"
            }
            return String(format: "#%-2d %@%@%@", idx, pc, labelPart, srcPart)
        }.joined(separator: "\n")
    }

    private func copyToPasteboard() {
        let body = backtraceText.isEmpty
            ? crashHeaderText
            : "\(crashHeaderText)\n\(backtraceText)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(body, forType: .string)
    }
}
