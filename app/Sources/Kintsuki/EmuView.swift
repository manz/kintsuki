import AppKit
import MetalKit
import SwiftUI

/// SwiftUI host for an MTKView. Forwards key events to the emulator via the
/// shared first-responder NSView subclass below.
struct EmuView: NSViewRepresentable {
    let emulator: Emulator

    func makeCoordinator() -> Coordinator {
        Coordinator(emulator: emulator)
    }

    func makeNSView(context: Context) -> NSView {
        let host = HostView()
        host.emulator = emulator
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor

        let mtk = MTKView(frame: .zero)
        mtk.preferredFramesPerSecond = 60
        mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtk.translatesAutoresizingMaskIntoConstraints = false
        mtk.wantsLayer = true

        if let renderer = MetalRenderer(view: mtk) {
            renderer.emulator = emulator
            mtk.delegate = renderer
            context.coordinator.renderer = renderer
        }

        host.addSubview(mtk)
        NSLayoutConstraint.activate([
            mtk.topAnchor.constraint(equalTo: host.topAnchor),
            mtk.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            mtk.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            mtk.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        NSLog("kintsuki: EmuView makeNSView host=\(host) mtk=\(mtk)")
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        let emulator: Emulator
        var renderer: MetalRenderer?
        init(emulator: Emulator) { self.emulator = emulator }
    }
}

/// First-responder NSView that funnels keyboard input into the emulator.
final class HostView: NSView {
    weak var emulator: Emulator?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let emu = emulator else { return }
        if let btn = InputMapper.button(forKeyCode: event.keyCode) {
            NSLog("kintsuki: keyDown code=\(event.keyCode) btn=\(btn)")
            emu.press(port: 0, button: btn.rawValue, pressed: true)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard let emu = emulator else { return }
        if let btn = InputMapper.button(forKeyCode: event.keyCode) {
            emu.press(port: 0, button: btn.rawValue, pressed: false)
            return
        }
        super.keyUp(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Reclaim first responder when the user clicks the game area.
        // SwiftUI sometimes steals focus during commands / menu actions.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}
