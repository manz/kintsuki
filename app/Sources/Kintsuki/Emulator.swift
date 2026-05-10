import AppKit
import Foundation
import SwiftData
import CKintsuki

/// High-level wrapper around libkintsuki. Lives on the main actor so
/// SwiftUI bindings stay safe; emulation step itself is cheap (~16ms / frame).
@MainActor
@Observable
final class Emulator {
    private(set) var running: Bool = false
    private(set) var loadedROM: URL?
    private(set) var recentROMs: [URL] = []
    private let recentsKey = "kintsuki.recentROMs"
    private let recentsLimit = 10
    private(set) var lastFrameID: UInt64 = 0
    private(set) var fps: Double = 0
    private(set) var cpuState = CpuState()
    private(set) var breakpoints: [Breakpoint] = []

    /// Set by ContentView once SwiftData's ModelContext is available.
    /// Use `setModelContext(_:)` rather than assigning directly — it
    /// pumps any auto-load that fired before the context was ready.
    private(set) var modelContext: ModelContext?

    /// Wire up the SwiftData context. Triggers a deferred autosave load
    /// when a ROM was already loaded before the context arrived
    /// (cold-launch race: `loadROM` from `Emulator.init` can race the
    /// ContentView onAppear that owns the SwiftData environment).
    func setModelContext(_ ctx: ModelContext) {
        modelContext = ctx
        if loadedROM != nil { _ = loadAutosave() }
    }

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
        /// True = pause the emulator on hit (real breakpoint).
        /// False = log/count only (tracing watchpoint).
        var halt: Bool = false
        var hitCount: Int = 0
        var lastHit: UInt32 = 0
        // Native callback id from kintsuki_add_callback.
        var nativeId: Int32 = 0
    }

    struct CpuState: Equatable, Codable {
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
    private(set) var halted: Bool = false

    /// Crash-recovery mode: emulator was launched from a `.kcr` dump,
    /// rewind capture is suppressed so the loaded ring stays a faithful
    /// pre-crash recording, and the run loop starts paused. Toggled on
    /// by `loadCrashDump(_:)` and off only by a fresh ROM load.
    private(set) var recoveryMode: Bool = false

    /// On-disk path of the most recent `.kcr` written for this session
    /// (or loaded into recovery mode). Surfaced in the UI so the user
    /// can copy it for `kintsuki --recover` or hand it to a Python
    /// reproducer script.
    private(set) var lastCrashDumpURL: URL? = nil

    /// Cross-window navigation request, e.g. the Tilemap Viewer asking
    /// the Memory Viewer to focus on a particular VRAM address. Set
    /// by `requestMemoryView`; read + cleared by MemoryViewerView when
    /// the window receives the request.
    struct MemoryNavRequest: Equatable {
        let region: MemRegion
        let offset: Int
        // Bumped on every set so two requests targeting the same
        // (region, offset) still trigger a re-jump. Without this the
        // observer's `.onChange` would no-op the second click.
        let nonce: Int
    }
    private(set) var memoryNavRequest: MemoryNavRequest? = nil
    private var memoryNavNonce: Int = 0

    /// Hand the Memory Viewer a focus request. Pair with
    /// `openWindow(id: "memory")` from the caller to make sure the
    /// window exists before the request is delivered.
    func requestMemoryView(region: MemRegion, offset: Int) {
        memoryNavNonce &+= 1
        memoryNavRequest = MemoryNavRequest(region: region,
                                            offset: offset,
                                            nonce: memoryNavNonce)
    }

    /// Called by MemoryViewerView once it has handled a request, so
    /// the same address can be focused again later without manual
    /// state hygiene at the call site.
    func clearMemoryNavRequest() {
        memoryNavRequest = nil
    }

    /// Same pattern as `MemoryNavRequest` but routed at the VRAM
    /// Viewer: select a tile by VRAM byte offset + bpp. Used by the
    /// Tilemap Viewer's "Tile addr" row to drill into the actual
    /// pixel data the cell points at.
    struct VRAMTileRequest: Equatable {
        let byteOffset: Int
        let bppRaw: Int            // 2, 4, or 8
        let nonce: Int
    }
    private(set) var vramTileRequest: VRAMTileRequest? = nil
    private var vramTileNonce: Int = 0

    func requestVRAMTile(byteOffset: Int, bpp: Int) {
        vramTileNonce &+= 1
        vramTileRequest = VRAMTileRequest(byteOffset: byteOffset & 0xFFFF,
                                          bppRaw: bpp,
                                          nonce: vramTileNonce)
    }

    /// Decoded DMA transfer event surfaced from the libkintsuki ring.
    /// Most-recent first. Deduplicated on the C side by (src+dst+size)
    /// so a per-frame buffer push collapses to one entry whose
    /// `hits` increments.
    struct DMATransfer: Identifiable, Hashable {
        let srcAddr: UInt32      // 24-bit
        let size: UInt16
        let channel: UInt8
        let direction: UInt8     // 0 = CPU->PPU
        let mode: UInt8
        let dstReg: UInt8        // PPU $21XX low byte
        /// VMADDR at fire (word address). Only meaningful when
        /// `isVRAMWrite` is true.
        let vramAddr: UInt16
        let hits: UInt32
        let lastFrame: UInt64
        var id: UInt64 {
            (UInt64(srcAddr) << 32) | (UInt64(vramAddr) << 16) | UInt64(size)
        }
        var isVRAMWrite: Bool { direction == 0 && (dstReg == 0x18 || dstReg == 0x19) }
        var isCGRAMWrite: Bool { direction == 0 && dstReg == 0x22 }
        var isOAMWrite: Bool { direction == 0 && dstReg == 0x04 }
        /// VRAM byte range covered by this transfer (when applicable).
        /// 16-bit VMADDR is a word address; bytes start at 2× and span
        /// `size` bytes. Wraps inside the 64 KB VRAM space.
        var vramByteRange: ClosedRange<Int>? {
            guard isVRAMWrite, size > 0 else { return nil }
            let lo = (Int(vramAddr) << 1) & 0xFFFF
            let hi = min(0xFFFF, lo + Int(size) - 1)
            return lo...hi
        }
    }

    /// Per-scanline HDMA channel mask for the most recently completed
    /// frame. Index = scanline; value = bitmask of channels that
    /// fired on that line (bit 0 = channel 0). Returned array is
    /// 320 entries long (covers NTSC 262 + PAL 312 with headroom).
    func hdmaScanlineMask() -> [UInt8] {
        guard let h = handle else { return Array(repeating: 0, count: 320) }
        var buf = [UInt8](repeating: 0, count: 320)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> UInt32 in
            kintsuki_hdma_scanline_mask(h, ptr.baseAddress, UInt32(ptr.count))
        }
        if n < 320 {
            for i in Int(n)..<320 { buf[i] = 0 }
        }
        return buf
    }

    func dmaTransfers() -> [DMATransfer] {
        guard let h = handle else { return [] }
        let cap = Int(kintsuki_dma_log_count(h))
        if cap == 0 { return [] }
        var raw = [kintsuki_dma_event_t](repeating: kintsuki_dma_event_t(),
                                          count: cap)
        let n = raw.withUnsafeMutableBufferPointer { buf -> UInt32 in
            kintsuki_dma_log_snapshot(h, buf.baseAddress, UInt32(buf.count))
        }
        var out: [DMATransfer] = []
        out.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            let e = raw[i]
            out.append(DMATransfer(srcAddr: e.src_addr,
                                   size: e.size,
                                   channel: e.channel,
                                   direction: e.direction,
                                   mode: e.mode,
                                   dstReg: e.dst_reg,
                                   vramAddr: e.vram_addr,
                                   hits: e.hits,
                                   lastFrame: e.last_frame))
        }
        return out
    }

    struct BacktraceFrame: Identifiable, Equatable, Codable {
        var id = UUID()
        var callsite: UInt32   // 24-bit
        var target:   UInt32   // 24-bit
        var kind:     UInt8    // 0=JSR, 1=JSL, 0xFF=halt site
        var label:    String?  // containing routine name from .adbg, nil if none
        var offset:   UInt32   // bytes into `label` (0 when no label)
        var file:     String?  // resolved via .adbg LINES, nil if no entry
        var line:     UInt32?  // 1-based, nil if no entry
        // Containing label for `target` — i.e. the routine the JSR/JSL
        // actually dispatched into. Lets the overlay print a "what was
        // called" line between frames so the chain reads top-to-bottom
        // without the user juggling addresses. Nil for the halt-site
        // frame (no target) or when the target lands in unlabeled code.
        var targetLabel: String? = nil
        // CPU register snapshot. Populated only for the halt-site frame
        // (`kind == 0xFF`); older callsite frames would need per-JSR
        // snapshotting in the call hook to recover, which doubles the
        // hook's cost — defer until somebody asks for it.
        var cpu:      CpuState? = nil
    }

    /// Captured shadow callstack at the moment the CPU first transitioned
    /// to halted=true. Cleared when the CPU resumes (after rearm, reset,
    /// hot-reload). Topmost frame first (deepest call).
    private(set) var crashBacktrace: [BacktraceFrame] = []

    /// Resolved metadata for the PC the CPU executed STP at — populated
    /// at the same time as `crashBacktrace`. The shadow stack only
    /// reports JSR/JSL callsites (= where the caller WAS), so without
    /// this the routine the BRK / STP actually fired in goes unnamed.
    private(set) var crashSite: BacktraceFrame? = nil

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
    private var rewindBuffer = RewindBuffer(capacity: 3600,
                                            keyframeInterval: 60)
    /// Frames currently retained in the rewind buffer (for the status pill).
    private(set) var rewindFrames: Int = 0
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
    /// While the user is actively rewinding, a dedicated timer drives
    /// the buffer at full frame-rate (60 Hz) instead of relying on OS
    /// key-repeat (which throttles ~30 Hz and slows rewind below 1:1).
    /// Mesen-S behaviour: hold the rewind key, watch state scrub
    /// smoothly backwards in real time.
    private var rewindTimer: Timer?
    /// Frames per rewind tick. 1 = 1:1 real-time. Bump for fast-rewind.
    private(set) var rewindStepPerTick: Int = 1

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
        // Pre-@Observable the deinit could touch @MainActor members
        // because ObservableObject classes carried implicit deinit
        // isolation; @Observable + @MainActor requires us to assert
        // we're on the main actor. Emulator is owned by the App scene
        // (always-on main), so this assertion holds.
        MainActor.assumeIsolated {
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
        // Fresh ROM = no longer reproducing a crash dump.
        recoveryMode = false
        // If the SwiftData context is already wired up, restore the
        // per-ROM autosave slot so the user lands exactly where they
        // left off. When the context isn't ready yet (cold launch race
        // — `modelContext` is set by ContentView's onAppear, which can
        // run after this auto-load), the deferred trigger in
        // `setModelContext(_:)` covers that path.
        if modelContext != nil { _ = loadAutosave() }
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
        if running {
            // Resuming after a halting BP — clear the pending signal so
            // the next frame doesn't immediately re-pause us.
            pendingBreakpointHaltId = nil
            startRunLoop()
        } else {
            stopRunLoop()
            refreshBacktrace()
        }
    }

    func stepOneFrame() {
        guard let h = handle else { return }
        kintsuki_run_frames(h, 1)
        snapshotFramebuffer()
    }

    /// Single-instruction step. Pause the run loop, advance one 65816
    /// opcode, refresh the cached CPU state. No-op when no ROM is loaded.
    func stepInstruction() {
        guard let h = handle else { return }
        if running { stopRunLoop(); running = false }
        kintsuki_step(h)
        snapshotCpuState()
        snapshotFramebuffer()
        refreshBacktrace()
    }

    /// Step Over: when the current opcode is JSR ($20)/JSL ($22), run to
    /// the instruction immediately after it. Otherwise behaves like
    /// `stepInstruction`. Caps at one emulated frame so a misbehaving
    /// callee can't lock the UI thread.
    func stepOver() {
        guard let h = handle else { return }
        if running { stopRunLoop(); running = false }
        var line = kintsuki_disasm_line_t()
        let n = kintsuki_disassemble_at(h, cpuState.pc, 1, &line)
        guard n > 0 else { kintsuki_step(h); snapshotCpuState(); snapshotFramebuffer(); return }
        let opcode = kintsuki_read_u8(h, cpuState.pc)
        if opcode == 0x20 || opcode == 0x22 || opcode == 0xFC {
            let next = (cpuState.pc & 0xFF0000) | ((cpuState.pc &+ UInt32(line.length)) & 0xFFFF)
            _ = kintsuki_run_until(h, next, 1)
        } else {
            kintsuki_step(h)
        }
        snapshotCpuState()
        snapshotFramebuffer()
        refreshBacktrace()
    }

    /// Step Out: drive the CPU until the topmost shadow-callstack frame's
    /// return address is reached. Best-effort — when the callstack is
    /// empty (e.g. ran past an RTS without a tracked JSR) falls back to a
    /// single instruction step. Caps at one frame to bound the wait.
    func stepOut() {
        guard let h = handle else { return }
        if running { stopRunLoop(); running = false }
        var frames = [kintsuki_call_frame_t](repeating: kintsuki_call_frame_t(),
                                             count: 32)
        let depth = frames.withUnsafeMutableBufferPointer { buf -> UInt32 in
            kintsuki_callstack_snapshot(h, buf.baseAddress, UInt32(buf.count))
        }
        if depth == 0 {
            kintsuki_step(h)
        } else {
            // Topmost frame = last entry (deepest first ordering per ABI).
            let top = frames[Int(depth) - 1]
            // Return address = JSR/JSL instruction's PC + length (3 for JSR,
            // 4 for JSL). Stay in-bank as the CPU would after RTS/RTL.
            let len: UInt32 = (top.kind == 0) ? 3 : 4
            let ret = (top.callsite_pc & 0xFF0000) | ((top.callsite_pc &+ len) & 0xFFFF)
            _ = kintsuki_run_until(h, ret, 1)
        }
        snapshotCpuState()
        snapshotFramebuffer()
        refreshBacktrace()
    }

    /// Run to cursor: install a one-shot halting breakpoint at `pc`,
    /// resume the run loop, and let the regular BP-halt path stop us
    /// when execution reaches the target. Falls back gracefully if the
    /// target never gets hit — the user can pause to drop the transient
    /// BP. Async-friendly (UI stays live), unlike the prior `run_until`
    /// path that blocked the main thread up to `max_frames` frames.
    @discardableResult
    func runToCursor(pc: UInt32) -> Bool {
        guard handle != nil else { return false }
        // Drop any pending halt request so the run loop doesn't
        // immediately re-pause on the previous breakpoint.
        pendingBreakpointHaltId = nil
        // One-shot halting BP at cursor. The standard BP-halt branch in
        // tick() will pause + refresh the debugger when it fires; we
        // mark it via metadata so the user's BP list isn't polluted.
        let target = pc & 0xFFFFFF
        addRunToCursorBP(target: target)
        if !running {
            running = true
            startRunLoop()
        }
        return true
    }

    /// Track transient run-to-cursor BPs so we can clean them up when
    /// they fire (or the user cancels).
    private var runToCursorBPIds: Set<UUID> = []

    private func addRunToCursorBP(target: UInt32) {
        addBreakpoint(kind: .exec, lo: target, hi: target, halt: true)
        if let bp = breakpoints.last {
            runToCursorBPIds.insert(bp.id)
        }
    }

    /// Called from tick() right after a BP halt to discard any
    /// transient run-to-cursor BPs (avoids polluting the user's BP set
    /// across multiple run-to-cursor invocations).
    fileprivate func consumeRunToCursorBPs() {
        guard !runToCursorBPIds.isEmpty else { return }
        let toRemove = breakpoints.filter { runToCursorBPIds.contains($0.id) }
        for bp in toRemove { removeBreakpoint(bp) }
        runToCursorBPIds.removeAll()
    }

    /// Disassemble `count` instructions starting at `pc`. Returns the
    /// rendered lines + per-instruction lengths. Used by the debugger
    /// window to populate its source pane.
    struct DisasmLine: Identifiable, Equatable {
        let id = UUID()
        let pc: UInt32
        let length: UInt8
        let text: String
        /// Static control-flow target when the instruction is a
        /// JMP/JML/JSR/JSL/Bxx/BRL with a constant operand. Nil for
        /// non-branching ops or indirect/indexed jumps.
        let target: UInt32?
    }

    func disassemble(at pc: UInt32, count: Int,
                     eOverride: Bool? = nil,
                     mOverride: Bool? = nil,
                     xOverride: Bool? = nil) -> [DisasmLine] {
        // Calling the disassembler before a cart is mapped derefs an
        // unmapped bus pointer (readDisassembler segfaults). Guard so the
        // debugger window can render an empty list pre-ROM.
        guard let h = handle, loadedROM != nil, count > 0 else { return [] }
        var raw = [kintsuki_disasm_line_t](repeating: kintsuki_disasm_line_t(),
                                           count: count)
        let e: Int32 = eOverride.map { $0 ? 1 : 0 } ?? -1
        let m: Int32 = mOverride.map { $0 ? 1 : 0 } ?? -1
        let x: Int32 = xOverride.map { $0 ? 1 : 0 } ?? -1
        let n = raw.withUnsafeMutableBufferPointer { buf -> UInt32 in
            kintsuki_disassemble_at_ex(h, pc & 0xFFFFFF, UInt32(buf.count),
                                       e, m, x, buf.baseAddress)
        }
        return (0..<Int(n)).map { i in
            var entry = raw[i]
            let text = withUnsafePointer(to: &entry.text) { tup in
                tup.withMemoryRebound(to: CChar.self, capacity: 128) { p in
                    String(cString: p)
                }
            }
            let target: UInt32? = entry.target == 0xFFFFFFFF ? nil : entry.target
            return DisasmLine(pc: entry.pc, length: entry.length,
                              text: text, target: target)
        }
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
        // Rewind capture goes through `kintsuki_save_state` which calls
        // `System::serialize(true)` → `scheduler.enter(Synchronize)`,
        // running every coroutine forward to a sync boundary. After a
        // halting breakpoint that advances `cpu.r.pc.d` from the BP
        // address to wherever the sync lands. Skip capture this tick
        // when a halt is pending; the next normal tick (post-resume)
        // will resume capture.
        if pendingBreakpointHaltId == nil {
            captureRewindFrame()
        }
        snapshotFramebuffer()
        snapshotCpuState()
        // Halting breakpoint hit during this frame? Pause the run loop
        // so the user can inspect. The callback's hop to main has
        // already updated `pendingBreakpointHaltId` by the time the
        // bail-induced early return lands here.
        if pendingBreakpointHaltId != nil && running {
            // Drop any one-shot run-to-cursor breakpoints so they don't
            // accumulate in the user-visible BP list.
            consumeRunToCursorBPs()
            // Re-snapshot the CPU register file at the bail boundary —
            // the earlier `snapshotCpuState()` runs before the halt
            // bookkeeping below, but we want to make absolutely sure
            // the @Published `cpuState` matches the BP address before
            // the debugger's onReceive subscribers fire.
            snapshotCpuState()
            running = false
            stopRunLoop()
            // Populate the backtrace snapshot the debugger surface
            // reads. Without this the sidebar showed
            // "(running — pause to capture)" even though we'd just
            // halted on a breakpoint.
            refreshBacktrace()
            NSLog(String(format: "kintsuki: paused on breakpoint at %06X", cpuState.pc))
        }
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
        guard !rewinding, !recoveryMode, let h = handle else { return }
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
        // `rewindFrames` is `@Published` and read by ContentView's status
        // pill + KintsukiApp's menu disabled-state. Mutating it every
        // push was firing objectWillChange 60 Hz pre-saturation — every
        // SwiftUI view holding an `@EnvironmentObject` Emulator would
        // redraw, which compounded with the Metal renderer's frame
        // present cost into a perf cliff around 50s of fill. Throttle
        // updates to ~6 Hz; status display lag is invisible at human
        // perception, hot path stays cheap.
        let n = rewindBuffer.count
        if rewindFrames != n,
           lastFrameID >= lastRewindFramesPublish + 10 {
            rewindFrames = n
            lastRewindFramesPublish = lastFrameID
        }
    }
    private var lastRewindFramesPublish: UInt64 = 0

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
        guard handle != nil, n >= 1 else { return false }
        // The actual buffer consumption is done by `rewindTimer` (60 Hz,
        // see `startRewindTimer`). This method only:
        //   1. Engages the timer if not already running.
        //   2. Pushes the hold-deadline forward so the timer keeps ticking.
        // Each OS key-repeat extends the deadline; release stops repeats
        // → deadline expires → trailing-edge work item stops the timer
        // and does the final repaint. Doing the buffer step here too
        // would race the timer and double-consume the ring, which is
        // what made rewind feel "stuck on" (timer tries to drain a
        // buffer the menu-action already chewed through).
        rewindHolding = true
        startRewindTimer()
        rewindHoldResumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rewindHolding = false
            self.rewindHoldResumeWork = nil
            self.stopRewindTimer()
            // Trailing-edge repaint: one emulated frame to refresh the
            // PPU output buffer to the post-rewind state. Per-step
            // repaints already happen inside the timer, so this is a
            // belt-and-suspenders refresh in case the user released
            // mid-tick.
            if let h = self.handle {
                kintsuki_run_frames(h, 1)
                self.snapshotFramebuffer()
                self.snapshotCpuState()
            }
        }
        rewindHoldResumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rewindHoldTimeout,
                                      execute: work)
        rewindStepPerTick = max(1, n)
        return rewindBuffer.count > 0
    }

    /// Drive the rewind buffer at 60 Hz while the user is holding the
    /// rewind shortcut. Each tick rewinds `rewindStepPerTick` frames.
    /// Stops when no rewindBy() call has happened for `rewindHoldTimeout`
    /// seconds (the existing hold-debounce work cancels us).
    private func startRewindTimer() {
        guard rewindTimer == nil, let h = handle else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.handle != nil else { return }
            // Defensive: if the hold flag flipped off behind our back
            // (e.g., the trailing-edge work item raced ahead of timer
            // invalidation), stop ourselves rather than silently drain
            // the ring. The "stuck in rewind mode" symptom maps to a
            // timer that kept ticking after a stale flag.
            guard self.rewindHolding else {
                self.stopRewindTimer()
                return
            }
            // Bypass the public rewindBy() entry — we ARE the hold loop.
            // Each tick: drop + materialize + load + rearm + repaint.
            // Visible cost per tick post-optimization is ~9-12 ms, fits
            // a 16 ms 60 Hz budget so the user sees state scrub
            // backwards in real time (Mesen-S parity).
            let n = self.rewindStepPerTick
            let dropCount = min(n + 1, self.rewindBuffer.count)
            self.rewindBuffer.dropLast(dropCount - 1)
            guard self.rewindBuffer.count > 0 else { return }
            let ok: Int32 = self.rewindBuffer.withMaterialized(
                at: self.rewindBuffer.count - 1
            ) { raw -> Int32 in
                kintsuki_load_state(h, raw.baseAddress, UInt32(raw.count))
            } ?? 0
            self.rewindBuffer.dropLast(1)
            self.rewindFrames = self.rewindBuffer.count
            if ok != 0 {
                kintsuki_rearm_cpu(h)
                kintsuki_run_frames(h, 1)
                self.snapshotFramebuffer()
                self.snapshotCpuState()
            }
        }
        timer.tolerance = 1.0 / 240.0
        RunLoop.main.add(timer, forMode: .common)
        rewindTimer = timer
    }

    private func stopRewindTimer() {
        rewindTimer?.invalidate()
        rewindTimer = nil
        // Reset stride so a subsequent ⌘← (1 frame) rewind doesn't
        // inherit a previous ⇧⌘← (60 frames) value.
        rewindStepPerTick = 1
    }

    /// Set the rewind playback speed. 1 = 1:1 (60 fps backwards),
    /// 2 = 2× fast-rewind, etc. Hooked to a future UI toggle.
    func setRewindSpeed(framesPerTick: Int) {
        rewindStepPerTick = max(1, framesPerTick)
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
                // Persist the rewind buffer + crash context for post-mortem
                // debugging. Skip when we're already in recovery mode —
                // re-dumping would overwrite the file the user is studying.
                if !recoveryMode { writeCrashDump() }
            } else {
                crashBacktrace = []
                crashSite = nil
            }
        }
    }

    /// Capture-on-pause: rebuild `crashBacktrace` from the live shadow
    /// callstack regardless of STP state. Drives the debugger window's
    /// backtrace section so the user can inspect call chain on every
    /// manual pause / step / breakpoint hit, not only on a crash.
    func refreshBacktrace() {
        let stack = captureBacktrace()
        let s = cpuState
        // Trace ordering matches the STP path: shallowest call first,
        // current site last. Use the live PC as the deepest "frame".
        var here = resolveFrame(at: s.pc, kind: s.stp ? 0xFF : 0xFE, target: 0)
        here.cpu = s
        crashBacktrace = stack + [here]
        crashSite = here
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
            var frame = resolveFrame(at: f.callsite_pc, kind: f.kind,
                                     target: f.target_pc)
            // Resolve the called routine's name so the overlay can
            // print a "→ JSR/JSL <name>" line between frames. Use exact
            // lookup here — JSR/JSL targets are routine entry points,
            // not mid-routine addresses.
            if let h = handle,
               let raw = kintsuki_lookup_label(h, f.target_pc) {
                frame.targetLabel = String(cString: raw)
            }
            out.append(frame)
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

    /// Write one byte into `region` at `offset`. Mirrors the bus
    /// mapping used by `readRegion`. Returns true when the write goes
    /// through, false if the region is read-only-from-host (currently
    /// none) or no handle is bound. ROM writes hit the cart RAM/RW
    /// portion of the bus — most LoROM banks ignore writes silently,
    /// which mirrors hardware.
    @discardableResult
    func writeRegion(_ region: MemRegion, offset: UInt32, byte: UInt8) -> Bool {
        guard let h = handle else { return false }
        switch region {
        case .wram:
            kintsuki_write_u8(h, 0x7E0000 + offset, byte)
        case .rom:
            let bank = offset / 0x8000
            let addr = (bank << 16) | 0x8000 | (offset & 0x7FFF)
            kintsuki_write_u8(h, addr, byte)
        case .sram:
            let addr = (UInt32(0x70) << 16) | (offset & 0xFFFF)
            kintsuki_write_u8(h, addr, byte)
        case .vram:
            kintsuki_vram_write(h, offset, byte)
        case .cgram:
            kintsuki_cgram_write(h, offset, byte)
        case .oam:
            kintsuki_oam_write(h, offset, byte)
        }
        return true
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
        // Tear down every async driver that touches ares state before
        // we yank the ROM out from under it. Without this, a
        // rewindTimer fires kintsuki_run_frames mid kintsuki_load_rom
        // and the app locks — Cmd+Shift+R landing on a rewind-held
        // emulator was the reproducible case. The runTimer is gated
        // on `running`, so flipping that to false before loadROM
        // (which sets it back to true) prevents any queued
        // tick-Task from re-entering ares mid-reload.
        rewindHolding = false
        rewindHoldResumeWork?.cancel()
        rewindHoldResumeWork = nil
        stopRewindTimer()
        stopRunLoop()
        running = false
        pendingBreakpointHaltId = nil
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
        // Prefer the latest rewind-buffer frame: it was captured at
        // the end of the previous tick, which is a known-good
        // boundary. A fresh `kintsuki_save_state` on quit runs
        // `scheduler.enter(Synchronize)` and may advance the CPU
        // past the user's last interaction, leaving them mid-frame
        // when they relaunch. Fall back to live save_state when the
        // ring is empty (boot, post-reset, recovery mode).
        let blob: Data
        if rewindBuffer.count > 0,
           let materialized = rewindBuffer.materialize(at: rewindBuffer.count - 1) {
            blob = materialized
        } else {
            let size = kintsuki_save_state(h, nil, 0)
            guard size > 0 else { return nil }
            var fresh = Data(count: Int(size))
            fresh.withUnsafeMutableBytes { _ = kintsuki_save_state(h, $0.baseAddress, size) }
            blob = fresh
        }
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
            // The callback runs synchronously inside kintsuki_run_frames,
            // which is itself called on the main actor. We're driven by
            // tick() on main, so it's safe to touch isolated state.
            guard let owner else { return }
            MainActor.assumeIsolated {
                guard let i = owner.breakpoints.firstIndex(where: { $0.id == bpId })
                else { return }
                let isHalt = owner.breakpoints[i].halt
                // Tracing BPs: tally silently into a non-published counter
                // so the 60 Hz hit storm doesn't churn the UI. The
                // breakpoint row exposes the silent count via a separate
                // accessor that consumers can poll on demand. Halting BPs
                // update the @Published row directly, which is fine since
                // the run loop is about to pause anyway.
                if isHalt {
                    owner.breakpoints[i].hitCount &+= 1
                    owner.breakpoints[i].lastHit = addr
                    owner.pendingBreakpointHaltId = bpId
                } else {
                    owner.silentHits[bpId, default: 0] &+= 1
                    owner.silentLastHit[bpId] = addr
                }
            }
        }
    }
    private var breakContexts: [UUID: BreakCallbackContext] = [:]

    /// Hit counters for tracing breakpoints, kept off `@Published` to
    /// avoid 60 Hz SwiftUI churn. Read via `tracingHitCount(_:)` when
    /// the user actually wants to see them (e.g. after a manual pause).
    fileprivate var silentHits: [UUID: Int] = [:]
    fileprivate var silentLastHit: [UUID: UInt32] = [:]

    /// Snapshot the silent hit counter for a tracing breakpoint. Returns
    /// 0 when none recorded. Halting BPs use `Breakpoint.hitCount`.
    func tracingHitCount(_ bp: Breakpoint) -> Int {
        return silentHits[bp.id, default: 0]
    }

    func tracingLastHit(_ bp: Breakpoint) -> UInt32? {
        return silentLastHit[bp.id]
    }

    /// Set by a halting breakpoint's callback dispatcher; consumed by
    /// `tick()` after each `kintsuki_run_frames` call. Drives the
    /// run-loop pause + UI focus jump to the breakpoint's PC.
    private(set) var pendingBreakpointHaltId: UUID? = nil

    /// Add a breakpoint. `halt: true` pauses the emulator on hit; default
    /// is `false` (tracing — counters update, execution continues). The
    /// debugger window asks for halting BPs; the inspector's quick-add
    /// watchpoints stay tracing-only.
    func addBreakpoint(kind: BreakKind, lo: UInt32, hi: UInt32, halt: Bool = false) {
        guard let h = handle else { return }
        var bp = Breakpoint(kind: kind, lo: lo, hi: hi, halt: halt)
        let ctx = BreakCallbackContext(owner: self, bpId: bp.id)
        breakContexts[bp.id] = ctx
        let opaque = Unmanaged.passUnretained(ctx).toOpaque()
        bp.nativeId = Int32(kintsuki_add_callback_ex(
            h, Int32(kind.rawValue), lo, hi, halt ? 1 : 0,
            Self.breakCallback, opaque))
        breakpoints.append(bp)
    }

    func removeBreakpoint(_ bp: Breakpoint) {
        guard let h = handle else { return }
        kintsuki_remove_callback(h, Int32(bp.kind.rawValue), bp.nativeId)
        breakContexts.removeValue(forKey: bp.id)
        silentHits.removeValue(forKey: bp.id)
        silentLastHit.removeValue(forKey: bp.id)
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

    // ----- PPU snapshot for viewers (tilemap, sprites, ...) ----------------
    /// Read-only snapshot of write-only PPU registers. Backed by
    /// `kintsuki_get_ppu_state`. Returns nil before a ROM is loaded.
    func ppuState() -> kintsuki_ppu_state_t? {
        guard let h = handle else { return nil }
        var s = kintsuki_ppu_state_t()
        kintsuki_get_ppu_state(h, &s)
        return s
    }

    /// VRAM snapshot from the inspector cache (refreshed at most ~6 Hz).
    /// Triggers a refresh if the cache is stale. Cheap when fresh — the
    /// returned `Data` shares the cache's storage via copy-on-write.
    func vramSnapshot() -> Data {
        refreshInspectorCachesIfDue()
        return vramCache
    }

    /// CGRAM snapshot from the inspector cache. Same semantics as
    /// `vramSnapshot`. 512 bytes (256 BGR555 entries).
    func cgramSnapshot() -> Data {
        refreshInspectorCachesIfDue()
        return cgramCache
    }

    // ----- .adbg label surface (debugger UI) ------------------------------
    struct Label: Identifiable, Hashable {
        let addr: UInt32        // 24-bit
        let name: String
        var id: UInt32 { addr }
    }

    /// All labels loaded from the active `.adbg` sidecar, sorted by
    /// address ascending. Empty when no .adbg is loaded. Cached snapshot
    /// — invalidated on `loadADBG` (caller responsibility to re-fetch).
    func allLabels() -> [Label] {
        guard let h = handle else { return [] }
        let count = Int(kintsuki_label_count(h))
        if count == 0 { return [] }
        var raw = [kintsuki_label_entry_t](repeating: kintsuki_label_entry_t(),
                                           count: count)
        let n = raw.withUnsafeMutableBufferPointer { buf -> UInt32 in
            kintsuki_label_snapshot(h, buf.baseAddress, UInt32(buf.count))
        }
        var out: [Label] = []
        out.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            let e = raw[i]
            guard let p = e.name else { continue }
            out.append(Label(addr: e.addr, name: String(cString: p)))
        }
        return out
    }

    /// Resolve a label by name → 24-bit PC. Returns nil when no .adbg is
    /// loaded or no label by that name exists.
    func resolveSymbol(_ name: String) -> UInt32? {
        guard let h = handle else { return nil }
        var addr: UInt32 = 0
        let ok = name.withCString { kintsuki_lookup_symbol_addr(h, $0, &addr) }
        return ok != 0 ? addr : nil
    }

    /// Containing-routine resolution for an arbitrary PC. Returns
    /// `(name, offset_in_routine)` when the .adbg has any label whose
    /// address is ≤ pc; nil otherwise.
    func containingLabel(at pc: UInt32) -> (name: String, offset: UInt32)? {
        guard let h = handle else { return nil }
        var off: UInt32 = 0
        guard let p = kintsuki_lookup_label_containing(h, pc, &off) else {
            return nil
        }
        return (String(cString: p), off)
    }

    /// Exact-address label lookup. Cheaper than `containingLabel` when
    /// the caller wants to know "is this PC the start of a routine?".
    func exactLabel(at pc: UInt32) -> String? {
        guard let h = handle else { return nil }
        guard let p = kintsuki_lookup_label(h, pc) else { return nil }
        return String(cString: p)
    }

    /// `.adbg` source-line lookup. Returns `(file, line, column)` when
    /// the loaded debug info has a LINES entry covering `pc`; nil when
    /// no .adbg is loaded or the PC predates the first emitted line.
    func sourceLine(at pc: UInt32) -> (file: String, line: UInt32, column: UInt16)? {
        guard let h = handle else { return nil }
        var filePtr: UnsafePointer<CChar>? = nil
        var line: UInt32 = 0
        var col: UInt16 = 0
        let ok = kintsuki_lookup_source(h, pc, &filePtr, &line, &col)
        guard ok != 0, let p = filePtr else { return nil }
        return (String(cString: p), line, col)
    }

    // ----- Crash recovery --------------------------------------------------
    /// Persistent location for `.kcr` dumps:
    /// `~/Library/Application Support/Kintsuki/crashes/`. The directory is
    /// created on demand.
    static var crashDumpsDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory,
                           in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Kintsuki/crashes",
                                              isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Snapshot the live rewind buffer + crash backtrace into a `.kcr`
    /// file. Triggered on the STP edge (see `snapshotCpuState`). Rotates
    /// older dumps so disk doesn't grow unbounded across dev iterations.
    @discardableResult
    func writeCrashDump() -> URL? {
        guard let rom = loadedROM else { return nil }
        let romHash = CrashDump.sha256(of: rom)
        let adbg = rom.deletingPathExtension().appendingPathExtension("adbg")
        let adbgHash: Data? = FileManager.default.fileExists(atPath: adbg.path)
            ? CrashDump.sha256(of: adbg) : nil
        let bt = (try? JSONEncoder().encode(crashBacktrace)) ?? Data("[]".utf8)
        let dump = CrashDump(
            romPath: rom.path,
            romSHA256: romHash,
            adbgSHA256: adbgHash,
            crashPC: crashSite?.callsite ?? cpuState.pc,
            crashCpu: cpuState,
            backtraceJSON: bt,
            keyframeInterval: 60,
            capacity: 3600,
            frames: rewindBuffer.serializedFrames()
        )
        let stem = rom.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: .now)
        let url = Self.crashDumpsDirectory
            .appendingPathComponent("\(stem)-\(stamp).kcr")
        do {
            try dump.write(to: url)
            lastCrashDumpURL = url
            NSLog("kintsuki: wrote crash dump \(url.path)")
            rotateCrashDumps(keeping: 10)
            return url
        } catch {
            NSLog("kintsuki: crash dump write failed: \(error)")
            return nil
        }
    }

    /// Load a `.kcr` dump and put the emulator into recovery mode. The
    /// referenced ROM is reloaded if needed; the rewind buffer is
    /// repopulated; recovery mode pauses the run loop and disables
    /// future captures so the loaded ring stays a faithful recording.
    /// Returns false on read errors or ROM mismatch.
    @discardableResult
    func loadCrashDump(_ url: URL) -> Bool {
        let dump: CrashDump
        do { dump = try CrashDump.read(from: url) }
        catch {
            NSLog("kintsuki: crash dump read failed: \(error)")
            return false
        }
        // ROM resolution: the dump records the absolute path. Re-load it
        // if not already live; mismatched ROM hashes get a warning but
        // proceed — the user may have rebuilt with the same code.
        let romURL = URL(fileURLWithPath: dump.romPath)
        if loadedROM?.path != dump.romPath {
            stopRunLoop()
            loadROM(romURL)
        }
        let liveHash = CrashDump.sha256(of: romURL)
        if liveHash != dump.romSHA256 {
            NSLog("kintsuki: crash dump ROM hash mismatch — proceeding anyway")
        }
        // Rebuild the rewind buffer from serialized frames.
        clearRewindBuffer()
        let restored = RewindBuffer(restoring: dump.frames,
                                    capacity: dump.capacity,
                                    keyframeInterval: dump.keyframeInterval)
        rewindBuffer_replace(with: restored)
        rewindFrames = restored.count
        // Seek to the last (= most recent / pre-crash) frame, load it
        // into the live emulator so the UI matches the dump's PC.
        if let lastBlob = restored.materialize(at: restored.count - 1),
           let h = handle {
            let ok = lastBlob.withUnsafeBytes { raw -> Int32 in
                kintsuki_load_state(h, raw.baseAddress, UInt32(lastBlob.count))
            }
            if ok != 0 { kintsuki_rearm_cpu(h); kintsuki_run_frames(h, 1) }
        }
        recoveryMode = true
        running = false
        stopRunLoop()
        snapshotFramebuffer()
        snapshotCpuState()
        // Replay the dump's backtrace into the UI so the overlay matches
        // the original crash even though the live CPU may not be in STP
        // post-load (loading a savestate clears r.stp).
        if let frames = try? JSONDecoder().decode([BacktraceFrame].self,
                                                   from: dump.backtraceJSON) {
            crashBacktrace = frames
            crashSite = frames.last
        }
        halted = true
        lastCrashDumpURL = url
        NSLog("kintsuki: recovery mode active for \(url.lastPathComponent)")
        return true
    }

    /// Swap the rewind buffer for a freshly-deserialized one. The
    /// existing buffer is left for ARC to reclaim once references drop.
    private func rewindBuffer_replace(with new: RewindBuffer) {
        rewindBuffer = new
    }

    private func rotateCrashDumps(keeping limit: Int) {
        let fm = FileManager.default
        let dir = Self.crashDumpsDirectory
        guard let entries = try? fm.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let kcr = entries.filter { $0.pathExtension == "kcr" }
        let sorted = kcr.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return da > db
        }
        for stale in sorted.dropFirst(limit) {
            try? fm.removeItem(at: stale)
        }
    }
}
