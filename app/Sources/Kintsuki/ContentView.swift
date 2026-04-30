import SwiftUI

struct ContentView: View {
    @EnvironmentObject var emulator: Emulator

    var body: some View {
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
        }
    }
}
