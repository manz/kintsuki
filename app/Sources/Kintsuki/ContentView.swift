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
        // Bare "CPU STP" — the BRK / STP site is rendered as `#0` of
        // the backtrace below so it follows gdb conventions and lines
        // up vertically with the rest of the frames.
        "CPU STP"
    }

    private var backtraceText: String {
        var lines: [String] = []
        for (idx, frame) in emulator.crashBacktrace.enumerated() {
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
            lines.append(String(format: "#%-2d %@%@%@",
                                idx, pc, labelPart, srcPart))
            // CPU registers ride with the halt-site frame (#0). Keep
            // them indented under their frame so a copy-paste of the
            // whole report stays readable.
            if let cpu = frame.cpu {
                lines.append(formatRegisters(cpu))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func formatRegisters(_ cpu: Emulator.CpuState) -> String {
        // Mesen-style register dump. Flags get the NVMXDIZC mnemonic
        // (uppercase = set, lowercase = clear) so users can read the
        // status without unpacking the hex byte. STP/WAI tagged when
        // set so the halt cause is unambiguous.
        let p = cpu.p
        let flagOrder: [(UInt8, Character, Character)] = [
            (0x80, "N", "n"),
            (0x40, "V", "v"),
            (0x20, "M", "m"),
            (0x10, "X", "x"),
            (0x08, "D", "d"),
            (0x04, "I", "i"),
            (0x02, "Z", "z"),
            (0x01, "C", "c"),
        ]
        let flags = String(flagOrder.map { (p & $0.0) != 0 ? $0.1 : $0.2 })
        // STP/WAI are noise here — the overlay only renders when the
        // CPU is STP'd, so they'd always read the same value.
        let emuFlag = cpu.e ? " E" : ""
        return String(format:
            "    A:%04X X:%04X Y:%04X S:%04X D:%04X B:%02X P:%02X[%@]%@",
            cpu.a, cpu.x, cpu.y, cpu.s, cpu.d, cpu.b, p, flags, emuFlag)
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
