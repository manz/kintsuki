import SwiftUI

@main
struct KintsukiApp: App {
    @StateObject private var emulator = Emulator()

    var body: some Scene {
        Window("Kintsuki", id: "main") {
            ContentView()
                .environmentObject(emulator)
                .frame(minWidth: 564, minHeight: 484)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open ROM…") {
                    emulator.openRomViaPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
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
            }
        }
    }
}
