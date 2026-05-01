import AppKit
import SwiftUI
import SwiftData

@main
struct KintsukiApp: App {
    @StateObject private var emulator = Emulator()
    @State private var showStateBrowser = false

    private let modelContainer: ModelContainer = Self.makeContainer()

    var body: some Scene {
        Window("Kintsuki", id: "main") {
            ContentView(showStateBrowser: $showStateBrowser)
                .environmentObject(emulator)
                .frame(minWidth: 564, minHeight: 484)
        }
        .modelContainer(modelContainer)
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
            }
            CommandGroup(after: .toolbar) {
                Button("Reset") { emulator.reset() }
                    .keyboardShortcut("r", modifiers: .command)
                Button(emulator.running ? "Pause" : "Resume") {
                    emulator.togglePause()
                }
                .keyboardShortcut("p", modifiers: .command)
                Button("Step Frame") { emulator.stepOneFrame() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button(emulator.inspectorOpen ? "Hide Inspector" : "Show Inspector") {
                    emulator.inspectorOpen.toggle()
                }
                .keyboardShortcut("i", modifiers: .command)
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
