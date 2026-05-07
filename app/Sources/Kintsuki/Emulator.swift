import AppKit
import Foundation
import SwiftData
import CKintsuki

/// High-level wrapper around libkintsuki. Lives on the main actor so
/// SwiftUI bindings stay safe; emulation step itself is cheap (~16ms / frame).
@MainActor
final class Emulator: ObservableObject {
    @Published private(set) var running: Bool = false
    @Published private(set) var loadedROM: URL?
    @Published private(set) var recentROMs: [URL] = []
    private let recentsKey = "kintsuki.recentROMs"
    private let recentsLimit = 10
    @Published private(set) var lastFrameID: UInt64 = 0
    @Published var inspectorOpen: Bool = false
    @Published private(set) var fps: Double = 0
    @Published private(set) var cpuState = CpuState()
    @Published private(set) var breakpoints: [Breakpoint] = []

    /// Set by ContentView once SwiftData's ModelContext is available.
    var modelContext: ModelContext?

    enum BreakKind: Int, CaseIterable, Identifiable {
        case exec = 0, read = 1, write = 2
        var id: Int { rawValue }
        var label: String { ["Exec", "Read", "Write"][rawValue] }
    }

    struct Breakpoint: Identifiable, Equatable {
        let id = UUID()
        var kind: BreakKind
        var lo: UInt32
        var hi: UInt32
        var hitCount: Int = 0
        var lastHit: UInt32 = 0
        // Native callback id from kintsuki_add_callback.
        var nativeId: Int32 = 0
    }

    struct CpuState: Equatable {
        var a: UInt16 = 0, x: UInt16 = 0, y: UInt16 = 0
        var s: UInt16 = 0, d: UInt16 = 0
        var b: UInt8 = 0, p: UInt8 = 0
        var pc: UInt32 = 0
        var e: Bool = false
        var stp: Bool = false
        var wai: Bool = false
    }

    /// True when the CPU executed STP and is sitting in instructionStop's
    /// idle loop — the game has effectively crashed (or hit a manual halt).
    /// Drives the "Game stopped" overlay in ContentView.
    @Published private(set) var halted: Bool = false

    struct BacktraceFrame: Identifiable, Equatable {
        let id = UUID()
        var callsite: UInt32   // 24-bit
        var target:   UInt32   // 24-bit
        var kind:     UInt8    // 0=JSR, 1=JSL, 0xFF=halt site
        var label:    String?  // containing routine name from .adbg, nil if none
        var offset:   UInt32   // bytes into `label` (0 when no label)
        var file:     String?  // resolved via .adbg LINES, nil if no entry
        var line:     UInt32?  // 1-based, nil if no entry
        // CPU register snapshot. Populated only for the halt-site frame
        // (`kind == 0xFF`); older callsite frames would need per-JSR
        // snapshotting in the call hook to recover, which doubles the
        // hook's cost — defer until somebody asks for it.
        var cpu:      CpuState? = nil
    }

    /// Captured shadow callstack at the moment the CPU first transitioned
    /// to halted=true. Cleared when the CPU resumes (after rearm, reset,
    /// hot-reload). Topmost frame first (deepest call).
    @Published private(set) var crashBacktrace: [BacktraceFrame] = []

    /// Resolved metadata for the PC the CPU executed STP at — populated
    /// at the same time as `crashBacktrace`. The shadow stack only
    /// reports JSR/JSL callsites (= where the caller WAS), so without
    /// this the routine the BRK / STP actually fired in goes unnamed.
    @Published private(set) var crashSite: BacktraceFrame? = nil

    /// Effective framebuffer dimensions reported by ares last frame.
    /// The pixel data lives inside libkintsuki and is exposed via
    /// `withFramebufferPointer` — no per-tick Data copy on the hot path
    /// (Allocations called the previous `Data(bytes:count:)` out as
    /// ~33 MB/s of churn). Cold-path consumers (thumbnails) materialize
    /// a Data on demand via `framebufferData()`.
    private(set) var fbWidth: UInt32 = 0
    private(set) var fbHeight: UInt32 = 0

    private var handle: OpaquePointer?
    private var runTimer: Timer?
    private var lastFpsTime: Date = .now
    /// Snapshot of `kintsuki_frame_count` at the last fps tick. Diffing
    /// against the live count gives the *actual* emulator throughput
    /// (frames produced per wall second), not 1/tick-interval — which
    /// stays pinned to 60Hz regardless of whether ares is making progress
    /// (e.g. CPU is in STP, or runFrames is stuck synchronizing).
    private var lastFpsFrameCount: UInt64 = 0
    /// Re-entrancy guard for the run-loop tick. `Task { @MainActor }`
    /// queues every Timer fire even if the previous tick is still inside
    /// runFrames (slow path under STP / heavy DMA), and the queue piles
    /// up faster than we drain it — the main-actor backlog beach-balls
    /// the UI. Setting this to true while a tick is in flight makes
    /// subsequent enqueues no-op until the current one returns.
    private var ticking: Bool = false

    // ----- Rewind ---------------------------------------------------------
    /// Per-frame delta-compressed savestate ring. Capped at ~60s of
    /// frames @ 60 fps (3600). The buffer stores XOR-compressed deltas
    /// against periodic keyframes so the worst-case footprint is bounded
    /// at ~50 MB rather than 60s × 60fps × full state.
    private let rewindBuffer = RewindBuffer(capacity: 3600,
                                            keyframeInterval: 60)
    /// Frames currently retained in the rewind buffer (for the status pill).
    @Published private(set) var rewindFrames: Int = 0
    /// Set true while a rewind is in progress so the run loop pauses
    /// captures (otherwise we'd push the rewound state right back onto
    /// the buffer and never make progress).
    private var rewinding: Bool = false
    /// NSEvent local monitor that consumes CMD+← while we have a ROM
    /// loaded. AppKit's auto-repeat (controlled by the Keyboard
    /// preference pane) keeps firing the event while the keys are held,
    /// so a single monitor + per-event call to rewindOneFrame() is all
    /// we need for "hold to scrub backwards" UX.
    private var rewindKeyMonitor: Any?

    /// Virtual key code for the left-arrow key on every Apple keyboard.
    private let leftArrowKeyCode: UInt16 = 0x7B
    /// Virtual key code for ESC. Used as a single-tap pause toggle so
    /// the user can freeze the emulator mid-frame to capture a clean
    /// savestate without fighting menu shortcuts.
    private let escKeyCode: UInt16 = 0x35
    private var pauseKeyMonitor: Any?
    /// True while the user is actively scrubbing backwards (a CMD+←
    /// fired in the last `rewindHoldTimeout` seconds). While held, the
    /// run loop suspends forward emulation so `tick()` doesn't re-push
    /// a frame between repeats and turn the buffer into a no-op churn.
    private var rewindHolding: Bool = false
    private var rewindHoldResumeWork: DispatchWorkItem?
    private let rewindHoldTimeout: TimeInterval = 0.15

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
        loadRecents()
        installRewindKeyMonitor()
        installPauseKeyMonitor()
        // Auto-reload the most recent ROM so a fresh app launch lands
        // straight back in the previous session's game. NSOpenPanel
        // only fires when the user explicitly wants a different ROM.
        if let last = recentROMs.first {
            DispatchQueue.main.async { [weak self] in
                self?.loadROM(last)
            }
        }
        // Persist the autosave slot whenever the app is on its way out
        // so the next launch (or a hot-reload) can restore exactly here.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.saveAutosave()
            }
        }
    }

    deinit {
        if let mon = rewindKeyMonitor {
            NSEvent.removeMonitor(mon)
        }
        if let mon = pauseKeyMonitor {
            NSEvent.removeMonitor(mon)
        }
        if let h = handle {
            kintsuki_destroy(h)
        }
    }

    /// Install a window-local NSEvent monitor that intercepts CMD+←
    /// keyDowns (including auto-repeat events) and steps the rewind
    /// buffer back one frame each time. Returning nil consumes the
    /// event so it doesn't bubble up and trigger the menu shortcut a
    /// second time.
    private func installPauseKeyMonitor() {
        pauseKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown)
            { [weak self] event in
                guard let self else { return event }
                guard event.keyCode == self.escKeyCode,
                      !event.isARepeat,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                else { return event }
                guard self.loadedROM != nil else { return event }
                self.togglePause()
                return nil
            }
    }

    private func installRewindKeyMonitor() {
        rewindKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown)
            { [weak self] event in
                guard let self else { return event }
                guard event.modifierFlags.contains(.command),
                      event.keyCode == self.leftArrowKeyCode
                else { return event }
                // No ROM = nothing to rewind to; pass the event through.
                guard self.loadedROM != nil else { return event }
                // CMD+Shift+← steps back 1 second (60 frames at 60 fps);
                // bare CMD+← steps back 1 frame.
                let stride = event.modifierFlags.contains(.shift) ? 60 : 1
                self.rewindBy(frames: stride)
                return nil  // consume so the menu shortcut doesn't double-fire
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
        // New ROM = fresh timeline. Drop any rewind frames from a
        // previous session.
        clearRewindBuffer()
        rememberRecent(url)
        // Auto-load a sibling `.adbg` so the halt overlay can resolve
        // crash callstacks without an explicit user action. a816 emits
        // the debug-info file next to whichever build artifact it just
        // wrote — `.sfc.adbg` for direct SFC builds, `.ips.adbg` when
        // the user assembles a patch and applies it to a base ROM.
        // Probe a few candidates: same path with `.adbg` appended, then
        // the same stem with `.adbg` swapped for the extension, then
        // `.ips.adbg` against the stem.
        let stem = (url.path as NSString).deletingPathExtension
        let candidates = [
            url.path + ".adbg",
            stem + ".adbg",
            stem + ".ips.adbg",
        ]
        var loaded = false
        for c in candidates {
            guard FileManager.default.fileExists(atPath: c) else { continue }
            let ok = c.withCString { kintsuki_load_adbg(h, $0) }
            NSLog("kintsuki: load_adbg \((c as NSString).lastPathComponent) -> \(ok != 0 ? "ok" : "failed")")
            if ok != 0 { loaded = true; break }
        }
        if !loaded {
            kintsuki_clear_adbg(h)
            NSLog("kintsuki: no .adbg found next to \(url.lastPathComponent) "
                  + "(tried .sfc.adbg, .adbg, .ips.adbg)")
        }
        startRunLoop()
    }

    func clearRecents() {
        recentROMs = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func loadRecents() {
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recentROMs = paths.compactMap { p in
            FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
        }
    }

    private func rememberRecent(_ url: URL) {
        var list = recentROMs.filter { $0.path != url.path }
        list.insert(url, at: 0)
        if list.count > recentsLimit { list = Array(list.prefix(recentsLimit)) }
        recentROMs = list
        UserDefaults.standard.set(list.map(\.path), forKey: recentsKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Soft reset: power-cycle the emulator without re-reading the ROM
    /// from disk. Cart SRAM survives. Use `reloadROMFromDisk()` for the
    /// full re-read + IPS reapply flow.
    func reset() {
        guard let h = handle, loadedROM != nil else { return }
        kintsuki_reset(h)
        clearRewindBuffer()
        snapshotFramebuffer()
        snapshotCpuState()
        if !running {
            running = true
            startRunLoop()
        }
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
        // Reset the FPS window so the first sample uses the post-load
        // frame count, not stale values from a previous session that
        // would either inflate or zero the first reading.
        if let h = handle {
            lastFpsFrameCount = kintsuki_frame_count(h)
        }
        lastFpsTime = .now
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
        // Re-entrancy guard: a slow runFrames (heavy DMA, halted CPU,
        // host hiccup) lets the next Timer fire enqueue another Task on
        // the main actor before this one returns. Without this skip the
        // backlog beach-balls the UI.
        if ticking { return }
        ticking = true
        defer { ticking = false }
        if rewindHolding { return }
        // Read CPU state cheaply before runFrames so we can short-circuit
        // when the CPU is already halted — runFrames would otherwise spin
        // a full frame's worth of cycles on STP for no progress.
        var rawCpu = kintsuki_cpu_state_t()
        kintsuki_get_state(h, &rawCpu)
        if rawCpu.stp != 0 {
            snapshotCpuState()
            return
        }
        kintsuki_run_frames(h, 1)
        captureRewindFrame()
        snapshotFramebuffer()
        snapshotCpuState()
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastFpsTime)
        if elapsed >= 0.5 {
            let count = kintsuki_frame_count(h)
            fps = Double(count - lastFpsFrameCount) / elapsed
            lastFpsFrameCount = count
            lastFpsTime = now
        }
    }

    /// Push the post-tick state into the rewind buffer. Skipped during
    /// an active rewind (otherwise the buffer would re-record the
    /// rewound state and we'd never make progress backwards).
    ///
    /// Hot path optimisation: the C save_state copy stays on main (it's
    /// the cheap part), but the XOR + LZ4 compression that follows is
    /// dispatched to a serial background queue so the run loop doesn't
    /// pay it. push order is preserved by the queue's serial nature.
    private func captureRewindFrame() {
        guard !rewinding, let h = handle else { return }
        let needed = kintsuki_save_state(h, nil, 0)
        guard needed > 0 else { return }
        // Producer-style push: ares writes the savestate straight into
        // the rewind buffer's pre-allocated keyframe slot (or shared
        // scratch for delta frames). No per-tick Data allocation, no
        // queue + closure capture pinning blobs in flight — the prior
        // path was the source of the multi-GB transient churn.
        rewindBuffer.push(count: Int(needed)) { [h] dst in
            guard let base = dst.baseAddress else { return 0 }
            let written = kintsuki_save_state(h, base, UInt32(dst.count))
            return Int(written)
        }
        let n = rewindBuffer.count
        if rewindFrames != n { rewindFrames = n }
    }

    /// Pop the most-recent retained frame and load it. Returns true if
    /// the buffer had something to rewind to. Triggered by the UI's
    /// CMD+← shortcut.
    @discardableResult
    func rewindOneFrame() -> Bool {
        return rewindBy(frames: 1)
    }

    /// Step the emulator back by `frames` retained frames. Used by the
    /// CMD+← (1 frame) and CMD+Shift+← (1 second = 60 frames) shortcuts.
    @discardableResult
    func rewindBy(frames n: Int) -> Bool {
        guard let h = handle, n >= 1 else { return false }
        // Mark the run loop as "user is scrubbing"; tick() will skip
        // forward emulation until the hold timeout fires.
        rewindHolding = true
        rewindHoldResumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rewindHolding = false
            self?.rewindHoldResumeWork = nil
        }
        rewindHoldResumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rewindHoldTimeout,
                                      execute: work)

        rewinding = true
        defer { rewinding = false }
        // Pop n+1 frames and load the last one popped: the first pop
        // discards the current state (already live in the emulator),
        // the next n step backward by n frames. If the buffer is
        // shallower than that, we land on the oldest frame retained.
        var lastPopped: Data?
        for _ in 0..<(n + 1) {
            guard let b = rewindBuffer.popLast() else { break }
            lastPopped = b
        }
        guard let blob = lastPopped else {
            rewindFrames = rewindBuffer.count
            return false
        }
        let ok = blob.withUnsafeBytes { raw -> Int32 in
            kintsuki_load_state(h, raw.baseAddress, UInt32(blob.count))
        }
        rewindFrames = rewindBuffer.count
        if ok != 0 {
            // ares doesn't serialize the libco coroutine RIP, so the
            // next run_frames would otherwise wake the coroutine inside
            // whatever wait loop it suspended in — rearm gives us a
            // fresh coroutine that picks up the restored register file.
            kintsuki_rearm_cpu(h)
            // The savestate restores PPU registers but not the live
            // render output buffer. Advance one frame so the PPU
            // re-paints the restored scene; otherwise the MTKView
            // keeps showing whatever was last drawn before the rewind.
            kintsuki_run_frames(h, 1)
            snapshotFramebuffer()
            snapshotCpuState()
            return true
        }
        return false
    }

    /// Drop every retained rewind frame (e.g., on ROM unload).
    func clearRewindBuffer() {
        rewindBuffer.clear()
        rewindFrames = 0
    }

    private func snapshotCpuState() {
        guard let h = handle else { return }
        var raw = kintsuki_cpu_state_t()
        kintsuki_get_state(h, &raw)
        // Only republish on change so SwiftUI doesn't redraw 60Hz for nothing.
        let s = CpuState(a: raw.a, x: raw.x, y: raw.y, s: raw.s, d: raw.d,
                         b: raw.b, p: raw.p, pc: raw.pc, e: raw.e != 0,
                         stp: raw.stp != 0, wai: raw.wai != 0)
        if s != cpuState { cpuState = s }
        if halted != s.stp {
            halted = s.stp
            // Capture once on the rising edge of the halt — calling the
            // C ABI is cheap but doing it 60Hz while the CPU is idle in
            // STP would churn @Published for nothing.
            if s.stp {
                // Python-traceback ordering: shallowest call first,
                // deepest call (the BRK/STP site) last. The shadow
                // stack from C is already shallowest-first, so we just
                // append the resolved halt site at the end and let the
                // overlay walk top-to-bottom.
                //
                // Decrement the lookup PC by 1: STP advances PC past
                // its own opcode before halting, so `s.pc` lands one
                // byte beyond the instruction and `lookup_label_
                // containing` would resolve against the *next* routine
                // instead of the brk_handler the STP actually lives in.
                // Wrap inside the 16-bit page so a halt at the start
                // of a bank stays in the same bank.
                let pcLow = s.pc & 0xFFFF
                let prev = (pcLow == 0)
                    ? (s.pc & 0xFF0000) | 0xFFFF
                    : s.pc - 1
                var site = resolveFrame(at: prev, kind: 0xFF, target: 0)
                site.cpu = s
                let stack = captureBacktrace()  // shallowest → newest
                crashBacktrace = stack + [site]
                crashSite = site
            } else {
                crashBacktrace = []
                crashSite = nil
            }
        }
    }

    /// Snapshot the native shadow callstack and resolve each frame's
    /// callsite via the loaded `.adbg` (if any). Top-of-stack last so the
    /// SwiftUI rendering can iterate frame[0] = deepest call.
    private func captureBacktrace(maxFrames: Int = 32) -> [BacktraceFrame] {
        guard let h = handle else { return [] }
        var buf = [kintsuki_call_frame_t](repeating: kintsuki_call_frame_t(),
                                           count: maxFrames)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> UInt32 in
            kintsuki_callstack_snapshot(h, ptr.baseAddress, UInt32(maxFrames))
        }
        var out: [BacktraceFrame] = []
        out.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            let f = buf[i]
            out.append(resolveFrame(at: f.callsite_pc, kind: f.kind,
                                    target: f.target_pc))
        }
        return out
    }

    /// Resolve a 24-bit PC into a `BacktraceFrame` with `.adbg`-backed
    /// containing-label, offset, and source location. Used both for
    /// shadow-stack frames (callsite PC) and the BRK / STP halt site
    /// (current PC at the moment of halt).
    private func resolveFrame(at pc: UInt32, kind: UInt8,
                              target: UInt32) -> BacktraceFrame {
        guard let h = handle else {
            return BacktraceFrame(callsite: pc, target: target, kind: kind,
                                  label: nil, offset: 0, file: nil, line: nil)
        }
        var labelOffset: UInt32 = 0
        let label = kintsuki_lookup_label_containing(h, pc, &labelOffset).map {
            String(cString: $0)
        }
        var filePtr: UnsafePointer<CChar>? = nil
        var lineNum: UInt32 = 0
        var colNum: UInt16 = 0
        let hasSrc = kintsuki_lookup_source(h, pc, &filePtr,
                                            &lineNum, &colNum) != 0
        let file = (hasSrc && filePtr != nil) ? String(cString: filePtr!) : nil
        let line: UInt32? = hasSrc ? lineNum : nil
        return BacktraceFrame(callsite: pc, target: target, kind: kind,
                              label: label,
                              offset: label != nil ? labelOffset : 0,
                              file: file, line: line)
    }

    // ----- Memory snapshot for hex/palette/tile views ---------------------
    enum MemRegion: String, CaseIterable, Identifiable {
        case wram = "WRAM", rom = "ROM", sram = "SRAM"
        case vram = "VRAM", cgram = "CGRAM", oam = "OAM"
        var id: String { rawValue }
        // Length of the addressable window for the stepper.
        var size: UInt32 {
            switch self {
            case .wram:  return 0x20000   // 128 KB
            case .rom:   return 0x800000  // generous; reads return open bus past end
            case .sram:  return 0x10000   // up to 64 KB SRAM (mapped via bus)
            case .vram:  return 0x10000
            case .cgram: return 0x200
            case .oam:   return 0x220
            }
        }
    }

    func readRegion(_ region: MemRegion, offset: UInt32, length: Int) -> Data {
        guard let h = handle else { return Data() }
        var buf = [UInt8](repeating: 0, count: length)
        buf.withUnsafeMutableBufferPointer { ptr in
            switch region {
            case .wram:
                _ = kintsuki_read_range(h, 0x7E0000 + offset, UInt32(length), ptr.baseAddress)
            case .rom:
                // LoROM: bank 00-7D, $8000-$FFFF. Walk the bus to surface
                // whatever the cart mapping sees.
                for i in 0..<length {
                    let abs = offset + UInt32(i)
                    let bank = abs / 0x8000
                    let addr = (bank << 16) | 0x8000 | (abs & 0x7FFF)
                    ptr[i] = kintsuki_read_u8(h, addr)
                }
            case .sram:
                // LoROM SRAM: $70:0000-$7D:FFFF. Mirror per-bank.
                for i in 0..<length {
                    let abs = offset + UInt32(i)
                    let addr = (UInt32(0x70) << 16) | (abs & 0xFFFF)
                    ptr[i] = kintsuki_read_u8(h, addr)
                }
            case .vram:
                for i in 0..<length { ptr[i] = kintsuki_vram_read(h, offset + UInt32(i)) }
            case .cgram:
                for i in 0..<length { ptr[i] = kintsuki_cgram_read(h, offset + UInt32(i)) }
            case .oam:
                for i in 0..<length { ptr[i] = kintsuki_oam_read(h, offset + UInt32(i)) }
            }
        }
        return Data(buf)
    }

    // ----- Cached PPU dumps (rebuilt at most ~6 Hz) -----------------------
    private var vramCache = Data(count: 0x10000)
    private var cgramCache = Data(count: 0x200)
    private var paletteCache = [(UInt8, UInt8, UInt8)](repeating: (0,0,0), count: 256)
    private var tileImageCache: [Int: NSImage] = [:]      // keyed by base+sub-palette
    private var lastInspectorRefresh: UInt64 = 0

    /// Returns true if we just refreshed (caller can rebuild images).
    @discardableResult
    func refreshInspectorCachesIfDue() -> Bool {
        // Refresh every 10 emulated frames (~6 Hz). Cheap enough.
        if lastFrameID < lastInspectorRefresh + 10 { return false }
        lastInspectorRefresh = lastFrameID
        guard let h = handle else { return false }
        vramCache.withUnsafeMutableBytes {
            _ = kintsuki_vram_dump(h, $0.bindMemory(to: UInt8.self).baseAddress, 0x10000)
        }
        cgramCache.withUnsafeMutableBytes {
            _ = kintsuki_cgram_dump(h, $0.bindMemory(to: UInt8.self).baseAddress, 0x200)
        }
        for i in 0..<256 {
            let lo = cgramCache[i*2]
            let hi = cgramCache[i*2 + 1]
            let bgr = UInt16(lo) | (UInt16(hi) << 8)
            let r5 = UInt8((bgr >>  0) & 0x1F)
            let g5 = UInt8((bgr >>  5) & 0x1F)
            let b5 = UInt8((bgr >> 10) & 0x1F)
            paletteCache[i] = ((r5 << 3) | (r5 >> 2),
                               (g5 << 3) | (g5 >> 2),
                               (b5 << 3) | (b5 >> 2))
        }
        tileImageCache.removeAll(keepingCapacity: true)
        return true
    }

    func paletteRGB() -> [(UInt8, UInt8, UInt8)] {
        refreshInspectorCachesIfDue()
        return paletteCache
    }

    /// Render a 16x8 grid of 4bpp tiles starting at VRAM offset `base`,
    /// using the given 16-colour sub-palette index. Returns a cached
    /// NSImage (128x64 px, nearest-neighbor).
    func tileGridImage(base: UInt32, paletteIndex: Int) -> NSImage? {
        refreshInspectorCachesIfDue()
        let key = (Int(base) << 8) | (paletteIndex & 0xFF)
        if let img = tileImageCache[key] { return img }

        let cols = 16, rows = 8, tileSize = 8
        let w = cols * tileSize
        let h = rows * tileSize
        var rgba = [UInt8](repeating: 0, count: w * h * 4)

        let palOff = paletteIndex * 16
        for tileRow in 0..<rows {
            for tileCol in 0..<cols {
                let tileIndex = tileRow * cols + tileCol
                let tileBase = Int(base) + tileIndex * 32
                if tileBase + 32 > vramCache.count { continue }
                for y in 0..<8 {
                    let p01_lo = vramCache[tileBase + y*2]
                    let p01_hi = vramCache[tileBase + y*2 + 1]
                    let p23_lo = vramCache[tileBase + 16 + y*2]
                    let p23_hi = vramCache[tileBase + 16 + y*2 + 1]
                    for x in 0..<8 {
                        let bit = UInt8(7 - x)
                        let mask: UInt8 = 1 << bit
                        var idx: UInt8 = 0
                        if (p01_lo & mask) != 0 { idx |= 1 }
                        if (p01_hi & mask) != 0 { idx |= 2 }
                        if (p23_lo & mask) != 0 { idx |= 4 }
                        if (p23_hi & mask) != 0 { idx |= 8 }
                        let pal = palOff + Int(idx)
                        let c = paletteCache[pal & 0xFF]
                        let dx = tileCol * 8 + x
                        let dy = tileRow * 8 + y
                        let off = (dy * w + dx) * 4
                        rgba[off + 0] = c.0
                        rgba[off + 1] = c.1
                        rgba[off + 2] = c.2
                        rgba[off + 3] = 0xFF
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let cg = CGImage(width: w, height: h, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        tileImageCache[key] = img
        return img
    }

    // ----- Save states (per-ROM, SwiftData-backed) ------------------------
    /// Capture current emulator state + framebuffer thumbnail and persist
    /// under the loaded ROM's path. No-op if no ROM or no ModelContext.
    @discardableResult
    func saveState(named name: String) -> SaveStateEntry? {
        guard let h = handle, let rom = loadedROM, let ctx = modelContext else { return nil }
        let size = kintsuki_save_state(h, nil, 0)
        guard size > 0 else { return nil }
        var blob = Data(count: Int(size))
        blob.withUnsafeMutableBytes { _ = kintsuki_save_state(h, $0.baseAddress, size) }
        let thumb = (framebufferData().flatMap {
            SaveStateThumbnail.png(fromBGRA: $0,
                                   width: Int(fbWidth), height: Int(fbHeight))
        }) ?? Data()
        let entry = SaveStateEntry(romPath: rom.path,
                                   name: name.isEmpty ? defaultStateName() : name,
                                   blob: blob, thumbnailPNG: thumb)
        ctx.insert(entry)
        do { try ctx.save() } catch { NSLog("kintsuki: save state failed: \(error)") }
        NSLog("kintsuki: saved state \"\(entry.name)\" (\(size) bytes)")
        return entry
    }

    func loadState(_ entry: SaveStateEntry) {
        guard let h = handle else { return }
        let ok = entry.blob.withUnsafeBytes { raw in
            kintsuki_load_state(h, raw.baseAddress, UInt32(entry.blob.count))
        }
        guard ok != 0 else { return }
        // ares serializes r.stp/r.wai + register file but not the libco
        // coroutine RIP. Without rearming, the next scheduler tick wakes
        // the coroutine inside whatever wait loop it happened to suspend
        // in (commonly STP/WAI), so PC sits frozen even though registers
        // were restored cleanly.
        kintsuki_rearm_cpu(h)
        NSLog("kintsuki: loaded state \"\(entry.name)\"")
    }

    /// Read a `.srm` file and push it into the cart's in-memory SRAM.
    /// The file on disk is never touched: emulator writes stay in RAM
    /// and don't propagate back. Resets the emulator after injection so
    /// the game boots with the new save data visible. Returns false on
    /// I/O failure or if no cart SRAM region exists.
    func loadSRM(url: URL) -> Bool {
        guard let h = handle else { return false }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            NSLog("kintsuki: loadSRM read failed: \(url.path)")
            return false
        }
        let copied: UInt32 = data.withUnsafeBytes { raw -> UInt32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return kintsuki_inject_sram(h, base, UInt32(data.count))
        }
        guard copied > 0 else {
            NSLog("kintsuki: loadSRM cart has no SRAM (or 0 copied)")
            return false
        }
        kintsuki_reset(h)
        snapshotFramebuffer()
        snapshotCpuState()
        clearRewindBuffer()
        NSLog("kintsuki: injected \(copied) bytes from \(url.lastPathComponent), reset emu")
        return true
    }

    /// Re-read the current ROM file from disk (re-applies any IPS
    /// sidecar) and reboot. Different from `reset()` only insofar as
    /// `kintsuki_load_rom` re-parses the cart manifest from the file -
    /// useful when the patched ROM on disk has been rebuilt.
    func reloadROMFromDisk() {
        guard let url = loadedROM else { return }
        stopRunLoop()
        loadROM(url)
    }

    /// Reserved name for the per-ROM autosave slot. Hidden from the
    /// state browser and overwritten in place by `saveAutosave()`.
    static let autosaveSlotName = "__autosave__"

    /// Snapshot the running emulator into the per-ROM autosave slot,
    /// overwriting whatever was there. Used both by app-quit and by
    /// hot-reload to ferry state across a `kintsuki_load_rom` call.
    @discardableResult
    func saveAutosave() -> SaveStateEntry? {
        guard let h = handle, let rom = loadedROM, let ctx = modelContext else { return nil }
        let size = kintsuki_save_state(h, nil, 0)
        guard size > 0 else { return nil }
        var blob = Data(count: Int(size))
        blob.withUnsafeMutableBytes { _ = kintsuki_save_state(h, $0.baseAddress, size) }
        let thumb = (framebufferData().flatMap {
            SaveStateThumbnail.png(fromBGRA: $0,
                                   width: Int(fbWidth), height: Int(fbHeight))
        }) ?? Data()
        let romPath = rom.path
        let slot = Self.autosaveSlotName
        let predicate = #Predicate<SaveStateEntry> { $0.romPath == romPath && $0.name == slot }
        let descriptor = FetchDescriptor<SaveStateEntry>(predicate: predicate)
        if let existing = (try? ctx.fetch(descriptor))?.first {
            existing.blob = blob
            existing.thumbnailPNG = thumb
            existing.createdAt = .now
            do { try ctx.save() } catch { NSLog("kintsuki: autosave update failed: \(error)") }
            return existing
        }
        let entry = SaveStateEntry(romPath: romPath, name: slot,
                                   blob: blob, thumbnailPNG: thumb)
        ctx.insert(entry)
        do { try ctx.save() } catch { NSLog("kintsuki: autosave insert failed: \(error)") }
        return entry
    }

    /// Restore the per-ROM autosave slot. Returns false when no such
    /// slot exists or the load fails — caller can fall back to a fresh
    /// boot in that case.
    @discardableResult
    func loadAutosave() -> Bool {
        guard let rom = loadedROM, let ctx = modelContext else { return false }
        let romPath = rom.path
        let slot = Self.autosaveSlotName
        let predicate = #Predicate<SaveStateEntry> { $0.romPath == romPath && $0.name == slot }
        let descriptor = FetchDescriptor<SaveStateEntry>(predicate: predicate)
        guard let entry = (try? ctx.fetch(descriptor))?.first else { return false }
        loadState(entry)
        return true
    }

    /// Reload the ROM from disk while preserving live emulator state
    /// across the swap. Captures state in-memory (skipping SwiftData so
    /// the externalStorage write/flush cycle can't race with the load)
    /// and applies it after the cart re-boots. Only sane when the new
    /// ROM is layout-compatible (typical iterative dev rebuild).
    func hotReloadKeepingState() {
        guard let url = loadedROM, let h = handle else { return }
        let needed = kintsuki_save_state(h, nil, 0)
        guard needed > 0 else {
            NSLog("kintsuki: hot-reload aborted — save_state size=0")
            return
        }
        var blob = Data(count: Int(needed))
        let written = blob.withUnsafeMutableBytes { raw -> UInt32 in
            kintsuki_save_state(h, raw.baseAddress, needed)
        }
        guard written == needed else {
            NSLog("kintsuki: hot-reload aborted — save_state short write")
            return
        }
        stopRunLoop()
        let path = url.path
        let ok = path.withCString { kintsuki_load_rom(h, $0) }
        guard ok != 0 else {
            NSLog("kintsuki: hot-reload load_rom failed at \(path)")
            return
        }
        clearRewindBuffer()
        let loaded = blob.withUnsafeBytes { raw -> Int32 in
            kintsuki_load_state(h, raw.baseAddress, UInt32(blob.count))
        }
        if loaded == 0 {
            NSLog("kintsuki: hot-reload load_state rejected blob — booting cold")
        } else {
            kintsuki_rearm_cpu(h)
        }
        snapshotFramebuffer()
        snapshotCpuState()
        running = true
        startRunLoop()
        NSLog("kintsuki: hot-reload complete")
    }

    /// Export the current emulator state to `url` as a kintsuki blob.
    func exportStateToFile(url: URL) -> Bool {
        guard let h = handle else { return false }
        let needed = kintsuki_save_state(h, nil, 0)
        guard needed > 0 else { return false }
        var blob = Data(count: Int(needed))
        let wrote = blob.withUnsafeMutableBytes { raw -> UInt32 in
            kintsuki_save_state(h, raw.baseAddress, needed)
        }
        guard wrote == needed else { return false }
        do {
            try blob.write(to: url, options: .atomic)
            NSLog("kintsuki: exported state to \(url.path) (\(wrote) bytes)")
            return true
        } catch {
            NSLog("kintsuki: exportState write failed: \(error)")
            return false
        }
    }

    /// Load an emulator state blob from `url`.
    func importStateFromFile(url: URL) -> Bool {
        guard let h = handle else { return false }
        guard let blob = try? Data(contentsOf: url), !blob.isEmpty else {
            NSLog("kintsuki: importState read failed: \(url.path)")
            return false
        }
        let ok = blob.withUnsafeBytes { raw -> Int32 in
            kintsuki_load_state(h, raw.baseAddress, UInt32(blob.count))
        }
        guard ok != 0 else {
            NSLog("kintsuki: importState rejected blob from \(url.path)")
            return false
        }
        kintsuki_rearm_cpu(h)
        kintsuki_run_frames(h, 1)
        snapshotFramebuffer()
        snapshotCpuState()
        clearRewindBuffer()
        NSLog("kintsuki: imported state from \(url.path)")
        return true
    }

    func renameState(_ entry: SaveStateEntry, to name: String) {
        guard let ctx = modelContext else { return }
        entry.name = name
        do { try ctx.save() } catch { NSLog("kintsuki: rename failed: \(error)") }
    }

    func deleteState(_ entry: SaveStateEntry) {
        guard let ctx = modelContext else { return }
        // Defer to next runloop tick so the SwiftUI cell that triggered
        // this delete can drop its `let entry` reference before SwiftData
        // detaches the backing store. Otherwise the immediate ctx.save()
        // can land while the cell is still in the view tree, and its
        // next render reads thumbnailPNG off a detached PersistentModel.
        DispatchQueue.main.async {
            ctx.delete(entry)
            do { try ctx.save() } catch { NSLog("kintsuki: delete failed: \(error)") }
        }
    }

    private func defaultStateName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: .now)
    }

    // ----- Breakpoints ----------------------------------------------------
    // Single C callback that bumps the breakpoint's hit counter via the
    // userdata pointer. We store the index into self.breakpoints there.
    private static let breakCallback: kintsuki_cb_t = { addr, _value, ud in
        guard let ud else { return }
        let ctx = Unmanaged<BreakCallbackContext>.fromOpaque(ud).takeUnretainedValue()
        ctx.fire(addr: addr)
    }
    private final class BreakCallbackContext {
        weak var owner: Emulator?
        let bpId: UUID
        init(owner: Emulator, bpId: UUID) { self.owner = owner; self.bpId = bpId }
        func fire(addr: UInt32) {
            // Hop to main since callback runs on the emulator (main) thread.
            DispatchQueue.main.async { [weak owner, bpId] in
                guard let owner else { return }
                if let i = owner.breakpoints.firstIndex(where: { $0.id == bpId }) {
                    owner.breakpoints[i].hitCount &+= 1
                    owner.breakpoints[i].lastHit = addr
                }
            }
        }
    }
    private var breakContexts: [UUID: BreakCallbackContext] = [:]

    func addBreakpoint(kind: BreakKind, lo: UInt32, hi: UInt32) {
        guard let h = handle else { return }
        var bp = Breakpoint(kind: kind, lo: lo, hi: hi)
        let ctx = BreakCallbackContext(owner: self, bpId: bp.id)
        breakContexts[bp.id] = ctx
        let opaque = Unmanaged.passUnretained(ctx).toOpaque()
        bp.nativeId = Int32(kintsuki_add_callback(h, Int32(kind.rawValue), lo, hi,
                                                  Self.breakCallback, opaque))
        breakpoints.append(bp)
    }

    func removeBreakpoint(_ bp: Breakpoint) {
        guard let h = handle else { return }
        kintsuki_remove_callback(h, Int32(bp.kind.rawValue), bp.nativeId)
        breakContexts.removeValue(forKey: bp.id)
        breakpoints.removeAll { $0.id == bp.id }
    }

    // ----- Framebuffer ------------------------------------------------------
    private func snapshotFramebuffer() {
        guard let h = handle else { return }
        var w: UInt32 = 0
        var h2: UInt32 = 0
        guard kintsuki_framebuffer(h, &w, &h2) != nil, w > 0, h2 > 0 else { return }
        fbWidth = w
        fbHeight = h2
        lastFrameID &+= 1
    }

    /// Borrow the live emulator framebuffer for the duration of `body`.
    /// Pointer is owned by libkintsuki and remains valid until the next
    /// scheduler step (we run on the main actor so the renderer always
    /// sees a consistent frame). Returns false when no frame is ready.
    @discardableResult
    func withFramebufferPointer<R>(_ body: (UnsafePointer<UInt32>, Int, Int) -> R) -> R? {
        guard let h = handle else { return nil }
        var w: UInt32 = 0
        var h2: UInt32 = 0
        guard let ptr = kintsuki_framebuffer(h, &w, &h2), w > 0, h2 > 0 else {
            return nil
        }
        return body(ptr, Int(w), Int(h2))
    }

    /// Cold-path materialization for thumbnail / save-state consumers
    /// that want an owned `Data` blob. Allocates per call — fine for
    /// the once-per-savestate frequency, never call this from the
    /// 60 Hz render loop.
    func framebufferData() -> Data? {
        withFramebufferPointer { ptr, w, h in
            Data(bytes: ptr, count: w * h * 4)
        }
    }

    // ----- Input ------------------------------------------------------------
    func press(port: Int32, button: Int32, pressed: Bool) {
        guard let h = handle else { return }
        kintsuki_press(h, port, button, pressed ? 1 : 0)
    }
}
