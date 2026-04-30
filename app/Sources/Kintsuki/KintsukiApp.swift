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
                Divider()
                Button(emulator.inspectorOpen ? "Hide Inspector" : "Show Inspector") {
                    emulator.inspectorOpen.toggle()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            // Save / load state slots — ⌘1-9 / ⇧⌘1-9.
            CommandMenu("State") {
                ForEach(1...9, id: \.self) { slot in
                    Button("Save Slot \(slot)") { emulator.quickSave(slot: slot) }
                        .keyboardShortcut(KeyEquivalent(Character("\(slot)")),
                                          modifiers: .command)
                }
                Divider()
                ForEach(1...9, id: \.self) { slot in
                    Button("Load Slot \(slot)") { emulator.quickLoad(slot: slot) }
                        .keyboardShortcut(KeyEquivalent(Character("\(slot)")),
                                          modifiers: [.command, .shift])
                }
            }
        }
    }
}
