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
    @Published var inspectorOpen: Bool = false
    @Published private(set) var fps: Double = 0
    @Published private(set) var cpuState = CpuState()
    @Published private(set) var saveStateSlots: [Int: SaveSlot] = [:]

    struct CpuState: Equatable {
        var a: UInt16 = 0, x: UInt16 = 0, y: UInt16 = 0
        var s: UInt16 = 0, d: UInt16 = 0
        var b: UInt8 = 0, p: UInt8 = 0
        var pc: UInt32 = 0
        var e: Bool = false
    }

    struct SaveSlot {
        var data: Data
        var savedAt: Date
    }

    /// The most recent framebuffer copied out of libkintsuki (RGBA, 0x00RRGGBB
    /// packed). Width/height refresh per frame. Surface is BGRA in memory
    /// (little-endian) so MTLPixelFormat.bgra8Unorm uploads without swizzle.
    private(set) var framebuffer: Data = .init()
    private(set) var fbWidth: UInt32 = 0
    private(set) var fbHeight: UInt32 = 0

    private var handle: OpaquePointer?
    private var runTimer: Timer?
    private var lastFpsTime: Date = .now
    private var framesSinceFpsTick: Int = 0

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
        snapshotCpuState()
        framesSinceFpsTick += 1
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastFpsTime)
        if elapsed >= 0.5 {
            fps = Double(framesSinceFpsTick) / elapsed
            framesSinceFpsTick = 0
            lastFpsTime = now
        }
    }

    private func snapshotCpuState() {
        guard let h = handle else { return }
        var raw = kintsuki_cpu_state_t()
        kintsuki_get_state(h, &raw)
        // Only republish on change so SwiftUI doesn't redraw 60Hz for nothing.
        let s = CpuState(a: raw.a, x: raw.x, y: raw.y, s: raw.s, d: raw.d,
                         b: raw.b, p: raw.p, pc: raw.pc, e: raw.e != 0)
        if s != cpuState { cpuState = s }
    }

    // ----- Memory snapshot for hex viewer (called from view body) ---------
    func readWRAM(start: UInt32, length: Int) -> Data {
        guard let h = handle else { return Data() }
        var buf = [UInt8](repeating: 0, count: length)
        buf.withUnsafeMutableBufferPointer { ptr in
            _ = kintsuki_read_range(h, 0x7E0000 + start, UInt32(length), ptr.baseAddress)
        }
        return Data(buf)
    }

    // ----- Save-state slots -----------------------------------------------
    func quickSave(slot: Int) {
        guard let h = handle else { return }
        let size = kintsuki_save_state(h, nil, 0)
        guard size > 0 else { return }
        var blob = Data(count: Int(size))
        blob.withUnsafeMutableBytes { _ = kintsuki_save_state(h, $0.baseAddress, size) }
        saveStateSlots[slot] = SaveSlot(data: blob, savedAt: .now)
        NSLog("kintsuki: quick-saved slot \(slot) (\(size) bytes)")
    }

    func quickLoad(slot: Int) {
        guard let h = handle, let snap = saveStateSlots[slot] else { return }
        let ok = snap.data.withUnsafeBytes { raw in
            kintsuki_load_state(h, raw.baseAddress, UInt32(snap.data.count))
        }
        if ok != 0 { NSLog("kintsuki: quick-loaded slot \(slot)") }
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
