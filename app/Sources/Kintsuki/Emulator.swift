import AppKit
import Foundation
import CKintsuki

/// High-level wrapper around libkintsuki. Lives on the main actor so
/// SwiftUI bindings stay safe; emulation step itself is cheap (~16ms / frame).
@MainActor
final class Emulator: ObservableObject {
    @Published private(set) var running: Bool = false
    @Published private(set) var loadedROM: URL?
    @Published private(set) var lastFrameID: UInt64 = 0

    /// The most recent framebuffer copied out of libkintsuki (RGBA, 0x00RRGGBB
    /// packed). Width/height refresh per frame. Surface is BGRA in memory
    /// (little-endian) so MTLPixelFormat.bgra8Unorm uploads without swizzle.
    private(set) var framebuffer: Data = .init()
    private(set) var fbWidth: UInt32 = 0
    private(set) var fbHeight: UInt32 = 0

    private var handle: OpaquePointer?
    private var displayLink: CADisplayLink?

    init() {
        // Set KINTSUKI_SYSTEM_PAK env var so the dylib finds boards.bml/ipl.rom
        // bundled at Contents/Resources/System/Super Famicom/.
        if let res = Bundle.main.resourcePath {
            let pak = res + "/System/Super Famicom"
            setenv("KINTSUKI_SYSTEM_PAK", pak, 1)
        }
        handle = kintsuki_create()
    }

    deinit {
        if let h = handle {
            kintsuki_destroy(h)
        }
    }

    // ----- ROM lifecycle ---------------------------------------------------
    func openRomViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a SNES ROM (.sfc / .smc)"
        if panel.runModal() == .OK, let url = panel.url {
            loadROM(url)
        }
    }

    func loadROM(_ url: URL) {
        guard let h = handle else { return }
        let path = url.path
        let ok = path.withCString { kintsuki_load_rom(h, $0) }
        guard ok != 0 else {
            NSLog("kintsuki: failed to load ROM at \(path)")
            return
        }
        loadedROM = url
        running = true
        startRunLoop()
    }

    func reset() {
        guard let url = loadedROM else { return }
        stopRunLoop()
        loadROM(url)
    }

    // ----- Run loop --------------------------------------------------------
    func togglePause() {
        running.toggle()
        if running { startRunLoop() } else { stopRunLoop() }
    }

    func stepOneFrame() {
        guard let h = handle else { return }
        kintsuki_run_frames(h, 1)
        snapshotFramebuffer()
    }

    private func startRunLoop() {
        guard displayLink == nil else { return }
        let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopRunLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard running, let h = handle else { return }
        kintsuki_run_frames(h, 1)
        snapshotFramebuffer()
    }

    // ----- Framebuffer ------------------------------------------------------
    private func snapshotFramebuffer() {
        guard let h = handle else { return }
        var w: UInt32 = 0
        var h2: UInt32 = 0
        guard let ptr = kintsuki_framebuffer(h, &w, &h2), w > 0, h2 > 0 else { return }
        let byteCount = Int(w) * Int(h2) * 4
        framebuffer = Data(bytes: ptr, count: byteCount)
        fbWidth = w
        fbHeight = h2
        lastFrameID &+= 1
    }

    // ----- Input ------------------------------------------------------------
    func press(port: Int32, button: Int32, pressed: Bool) {
        guard let h = handle else { return }
        kintsuki_press(h, port, button, pressed ? 1 : 0)
    }
}
