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
    private var runTimer: Timer?

    init() {
        // Set KINTSUKI_SYSTEM_PAK env var so the dylib finds boards.bml/ipl.rom
        // bundled at Contents/Resources/System/Super Famicom/.
        if let res = Bundle.main.resourcePath {
            let pak = res + "/System/Super Famicom"
            setenv("KINTSUKI_SYSTEM_PAK", pak, 1)
            let fm = FileManager.default
            let boards = pak + "/boards.bml"
            let ipl = pak + "/ipl.rom"
            NSLog("kintsuki: system pak = \(pak)")
            NSLog("kintsuki: boards.bml exists=\(fm.fileExists(atPath: boards))")
            NSLog("kintsuki: ipl.rom    exists=\(fm.fileExists(atPath: ipl))")
        } else {
            NSLog("kintsuki: WARN no Bundle.main.resourcePath")
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
        // Don't filter: macOS 14+ rejects an empty allowedContentTypes array
        // outright, and an explicit UTType list excludes ROMs Finder didn't
        // tag with a recognised type. Just let the user pick any file.
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a SNES ROM (.sfc / .smc)"
        panel.prompt = "Open"
        let response = panel.runModal()
        NSLog("kintsuki: open panel response=\(response.rawValue) url=\(panel.url?.path ?? "nil")")
        if response == .OK, let url = panel.url {
            loadROM(url)
        }
    }

    func loadROM(_ url: URL) {
        guard let h = handle else {
            NSLog("kintsuki: loadROM called with nil handle")
            return
        }
        let path = url.path
        NSLog("kintsuki: loadROM path=\(path)")
        let ok = path.withCString { kintsuki_load_rom(h, $0) }
        guard ok != 0 else {
            NSLog("kintsuki: failed to load ROM at \(path)")
            return
        }
        NSLog("kintsuki: ROM loaded successfully")
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
        guard runTimer == nil else { return }
        // 60 Hz Timer is simpler than CADisplayLink for emulation pacing.
        // The MTKView runs its own display sync, so we just need to advance
        // the emulator at roughly the source frame rate.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Hop to main actor since Timer fires on the run loop's thread
            // (which is main here, but explicit hop satisfies the actor).
            Task { @MainActor in self.tick() }
        }
        timer.tolerance = 1.0 / 240.0
        RunLoop.main.add(timer, forMode: .common)
        runTimer = timer
        NSLog("kintsuki: run loop started")
    }

    private func stopRunLoop() {
        runTimer?.invalidate()
        runTimer = nil
        NSLog("kintsuki: run loop stopped")
    }

    private func tick() {
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
        if lastFrameID % 60 == 0 {
            let sample = framebuffer.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
            let nonzero = framebuffer.contains { $0 != 0 }
            var s = kintsuki_cpu_state_t()
            kintsuki_get_state(h, &s)
            NSLog("kintsuki: fb#\(lastFrameID) sample=\(sample) nz=\(nonzero) PC=$\(String(format: "%06X", s.pc)) A=\(String(format: "%04X", s.a))")
        }
    }

    // ----- Input ------------------------------------------------------------
    func press(port: Int32, button: Int32, pressed: Bool) {
        guard let h = handle else { return }
        kintsuki_press(h, port, button, pressed ? 1 : 0)
    }
}
