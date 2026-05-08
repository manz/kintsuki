import AppKit
import SwiftUI
import SwiftData

@main
struct KintsukiApp: App {
    @State private var emulator = Emulator()
    @State private var showStateBrowser = false
    @Environment(\.openWindow) private var openWindow

    private let modelContainer: ModelContainer = Self.makeContainer()

    var body: some Scene {
        Window("Kintsuki", id: "main") {
            ContentView(showStateBrowser: $showStateBrowser)
                .environment(emulator)
                .frame(minWidth: 564, minHeight: 484)
                .onAppear { handleLaunchArguments() }
        }
        .modelContainer(modelContainer)

        Window("Tilemap Viewer", id: "tilemap") {
            // Plain reference, like DebuggerView — keeps the viewer
            // from re-rendering 60 Hz on every emulator @Published mutation.
            TilemapViewerView(emulator: emulator)
        }

        Window("Debugger", id: "debugger") {
            // Hand the Emulator over as a plain reference rather than an
            // `.environmentObject`. DebuggerView intentionally does not
            // subscribe to its `@Published` mutations — see the doc on
            // `DebuggerView.emulator` for the FPS rationale.
            DebuggerView(emulator: emulator)
        }

        Window("VRAM Viewer", id: "vram") {
            VRAMViewerView(emulator: emulator)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open ROM…") {
                    emulator.openRomViaPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(emulator.recentROMs, id: \.self) { url in
                        Button(url.lastPathComponent) { emulator.loadROM(url) }
                    }
                    if !emulator.recentROMs.isEmpty {
                        Divider()
                        Button("Clear Menu") { emulator.clearRecents() }
                    }
                }
                .disabled(emulator.recentROMs.isEmpty)
                Divider()
                Button("Load Save File (.srm)…") { loadSRMViaPanel() }
                    .disabled(emulator.loadedROM == nil)
                Divider()
                Button("Open Crash Dump…") { openCrashDumpViaPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Reveal Crash Dumps in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Emulator.crashDumpsDirectory])
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Reset") { emulator.reset() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(emulator.loadedROM == nil)
                Button("Reload ROM From Disk") { emulator.reloadROMFromDisk() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(emulator.loadedROM == nil)
                Button("Hot-Reload ROM (Keep State)") { emulator.hotReloadKeepingState() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(emulator.loadedROM == nil)
                Button(emulator.running ? "Pause" : "Resume") {
                    emulator.togglePause()
                }
                .keyboardShortcut("p", modifiers: .command)
                Button("Step Frame") { emulator.stepOneFrame() }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Rewind 1 Frame") { emulator.rewindOneFrame() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(emulator.rewindFrames < 2)
                Button("Rewind 1 Second") { emulator.rewindBy(frames: 60) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                    .disabled(emulator.rewindFrames < 2)
                Divider()
                Button("Tilemap Viewer") { openWindow(id: "tilemap") }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("VRAM Viewer") { openWindow(id: "vram") }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Debugger") { openWindow(id: "debugger") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("State") {
                Button("Show Save States in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Self.saveStateDirectory])
                }
                Divider()
                Button("Save State") { emulator.saveState(named: "") }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(emulator.loadedROM == nil)
                Button("Manage Save States…") { showStateBrowser = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(emulator.loadedROM == nil)
                Divider()
                Button("Export State to File…") { exportStateViaPanel() }
                    .disabled(emulator.loadedROM == nil)
                Button("Import State from File…") { importStateViaPanel() }
                    .disabled(emulator.loadedROM == nil)
            }
        }
    }

    /// Honour `--recover <path>` on launch by loading a `.kcr` dump
    /// straight into recovery mode. Anything else (including a bare
    /// positional ROM path) is left to the existing open-ROM flow.
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--recover"),
              i + 1 < args.count else { return }
        let path = args[i + 1]
        let url = URL(fileURLWithPath: path)
        if !emulator.loadCrashDump(url) {
            NSLog("kintsuki: --recover load failed for \(path)")
        }
    }

    private func openCrashDumpViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a Kintsuki crash dump (.kcr)"
        panel.prompt = "Recover"
        panel.directoryURL = Emulator.crashDumpsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            let ok = emulator.loadCrashDump(url)
            if !ok {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Crash dump load failed"
                alert.informativeText = "Could not load \(url.lastPathComponent)."
                alert.runModal()
            }
        }
    }

    private func loadSRMViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a cart save (.srm)"
        panel.prompt = "Inject"
        if panel.runModal() == .OK, let url = panel.url {
            let ok = emulator.loadSRM(url: url)
            if !ok {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "SRM load failed"
                alert.informativeText = "Could not inject \(url.lastPathComponent) into cart SRAM."
                alert.runModal()
            }
        }
    }

    private func exportStateViaPanel() {
        let panel = NSSavePanel()
        panel.message = "Save kintsuki state"
        panel.prompt = "Save"
        let stem = emulator.loadedROM?.deletingPathExtension().lastPathComponent ?? "state"
        panel.nameFieldStringValue = "\(stem).kss"
        if panel.runModal() == .OK, let url = panel.url {
            _ = emulator.exportStateToFile(url: url)
        }
    }

    private func importStateViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a kintsuki state file"
        panel.prompt = "Load"
        if panel.runModal() == .OK, let url = panel.url {
            let ok = emulator.importStateFromFile(url: url)
            if !ok {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "State load failed"
                alert.informativeText = "Could not load \(url.lastPathComponent) - blob mismatch or corrupt file."
                alert.runModal()
            }
        }
    }

    /// Persistent location for SwiftData store + external blobs.
    /// `~/Library/Application Support/Kintsuki/SaveStates.sqlite` —
    /// survives app reinstall, lives outside the build artefact tree.
    private static var saveStateDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory,
                           in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Kintsuki", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeContainer() -> ModelContainer {
        let url = saveStateDirectory.appendingPathComponent("SaveStates.sqlite")
        let config = ModelConfiguration(url: url)
        do {
            return try ModelContainer(for: SaveStateEntry.self, configurations: config)
        } catch {
            NSLog("kintsuki: ModelContainer init failed: \(error)")
            // Fall back to in-memory so the app still launches.
            let mem = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: SaveStateEntry.self, configurations: mem)
        }
    }
}
