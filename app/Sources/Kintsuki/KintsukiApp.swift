import AppKit
import SwiftUI
import SwiftData

@main
struct KintsukiApp: App {
    @State private var emulator = Emulator()
    @State private var showStateBrowser = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// True when SwiftUI's window with `id` is currently visible.
    /// Used to flip the tool-window menu shortcuts into toggles
    /// (open ↔ close) instead of "open another instance".
    private func toolWindowOpen(_ id: String) -> Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == id && $0.isVisible }
    }

    /// Open `id` if it's not already, otherwise dismiss it. Bound to
    /// each viewer's ⌘⇧X shortcut so a second press hides the panel.
    private func toggleToolWindow(_ id: String) {
        if toolWindowOpen(id) {
            dismissWindow(id: id)
        } else {
            openWindow(id: id)
        }
    }

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

        Window("Memory Viewer", id: "memory") {
            MemoryViewerView(emulator: emulator)
        }

        Window("HDMA Inspector", id: "hdma") {
            HDMAInspectorView(emulator: emulator)
        }

        Window("Project Labels", id: "labels") {
            ProjectLabelsView(emulator: emulator)
        }

        Window("Project Bookmarks", id: "bookmarks") {
            ProjectBookmarksView(emulator: emulator)
        }

        Window("Profiler", id: "profiler") {
            ProfilerView(emulator: emulator)
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
                Button("Tilemap Viewer") { toggleToolWindow("tilemap") }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("VRAM Viewer") { toggleToolWindow("vram") }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Memory Viewer") { toggleToolWindow("memory") }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("HDMA Inspector") { toggleToolWindow("hdma") }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Debugger") { toggleToolWindow("debugger") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Project Labels") { toggleToolWindow("labels") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Project Bookmarks") { toggleToolWindow("bookmarks") }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Profiler") { toggleToolWindow("profiler") }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("Project") {
                if emulator.projectIsOpen, let dir = emulator.projectDir {
                    Text(dir.lastPathComponent)
                    if let s = emulator.projectStats {
                        Text(String(format: "%.1f%% classified · %u labels-sticky",
                                    s.pctClassified, s.userSticky))
                            .font(.caption)
                    }
                    Divider()
                    Button("Save Now") { emulator.projectSave() }
                        .keyboardShortcut("s", modifiers: [.command, .control])
                    Button("Close Project") { emulator.projectClose() }
                    Divider()
                    Menu("Autosave") {
                        Button("Off")            { _ = emulator.projectAutosave(0) }
                        Button("Every 60 frames (~1s)") { _ = emulator.projectAutosave(60) }
                        Button("Every 600 frames (~10s)") { _ = emulator.projectAutosave(600) }
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                } else {
                    Button("Create Project for Loaded ROM") {
                        emulator.projectCreateForLoadedROM()
                    }
                    .disabled(emulator.loadedROM == nil)
                    Button("Attach Existing Project…") { attachProjectViaPanel() }
                        .disabled(emulator.loadedROM == nil)
                }
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

    private func attachProjectViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Select a Kintsuki project directory (.kintsuki/)"
        panel.prompt = "Attach"
        if let rom = emulator.loadedROM {
            panel.directoryURL = rom.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            emulator.projectOpen(at: url)
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
