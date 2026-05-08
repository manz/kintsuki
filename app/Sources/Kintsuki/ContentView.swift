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
        }
        .onAppear { emulator.setModelContext(modelContext) }
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
        // Python-traceback header. Frames are listed shallowest-first
        // below, deepest-call (the STP site) at the bottom.
        "Traceback (CPU STP, most recent call last):"
    }

    private var backtraceText: String {
        var lines: [String] = []
        for frame in emulator.crashBacktrace {
            let pc = String(format: "%02X:%04X",
                            (frame.callsite >> 16) & 0xFF,
                            frame.callsite & 0xFFFF)
            // Python-style header line:  `  PC, in <name+offset>`.
            let labelPart: String
            if let name = frame.label {
                labelPart = frame.offset > 0
                    ? String(format: ", in %@+0x%X", name, frame.offset)
                    : ", in \(name)"
            } else {
                labelPart = ", in <unknown>"
            }
            var srcPart = ""
            if let file = frame.file, let line = frame.line {
                let base = (file as NSString).lastPathComponent
                srcPart = "  (\(base):\(line))"
            }
            lines.append("  \(pc)\(labelPart)\(srcPart)")
            // Call frames carry a target label — print the dispatched
            // call as the next indented line so the chain reads as a
            // sequence of "we were here, then we did this jump".
            if frame.kind != 0xFF {
                let mnem = frame.kind == 1 ? "JSL" : "JSR"
                let target = String(format: "%02X:%04X",
                                    (frame.target >> 16) & 0xFF,
                                    frame.target & 0xFFFF)
                let targetName = frame.targetLabel ?? target
                lines.append("    → \(mnem) \(targetName)")
            }
            // Registers ride with the halt-site frame (the deepest /
            // last entry).
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
