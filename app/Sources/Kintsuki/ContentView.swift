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
                if !emulator.running, emulator.loadedROM != nil {
                    Text("PAUSED")
                        .font(.system(.title2, design: .monospaced))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if emulator.loadedROM != nil {
                    VStack {
                        HStack {
                            Spacer()
                            Text(String(format: "%.0f fps", emulator.fps))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.4), in: Capsule())
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
