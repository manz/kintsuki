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
    }

    deinit {
        if let mon = rewindKeyMonitor {
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
    private func installRewindKeyMonitor() {
        rewindKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown)
            { [weak self] event in
                guard let self else { return event }
                guard event.modifierFlags.contains(.command),
                      event.keyCode == self.leftArrowKeyCode
                else { return event }
                // No ROM = nothing to rewind to; pass the event through.
                guard self.loadedROM != nil else { return event }
                self.rewindOneFrame()
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
        captureRewindFrame()
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

    /// Push the post-tick state into the rewind buffer. Skipped during
    /// an active rewind (otherwise the buffer would re-record the
    /// rewound state and we'd never make progress backwards).
    private func captureRewindFrame() {
        guard !rewinding, let h = handle else { return }
        let needed = kintsuki_save_state(h, nil, 0)
        guard needed > 0 else { return }
        var blob = Data(count: Int(needed))
        let written = blob.withUnsafeMutableBytes { raw -> UInt32 in
            kintsuki_save_state(h, raw.baseAddress, UInt32(needed))
        }
        guard written > 0 else { return }
        blob.count = Int(written)
        rewindBuffer.push(blob)
        if rewindFrames != rewindBuffer.count { rewindFrames = rewindBuffer.count }
    }

    /// Pop the most-recent retained frame and load it. Returns true if
    /// the buffer had something to rewind to. Triggered by the UI's
    /// CMD+← shortcut.
    @discardableResult
    func rewindOneFrame() -> Bool {
        guard let h = handle else { return false }
        rewinding = true
        defer { rewinding = false }
        // Pop the most-recent first (current frame), then the next-most-
        // recent (previous frame) — that's the frame we actually want
        // to land on. If only one frame was retained, popping it returns
        // us to the single available point in time and the buffer is
        // empty afterwards.
        _ = rewindBuffer.popLast()
        guard let blob = rewindBuffer.popLast() else {
            rewindFrames = rewindBuffer.count
            return false
        }
        let ok = blob.withUnsafeBytes { raw -> Int32 in
            kintsuki_load_state(h, raw.baseAddress, UInt32(blob.count))
        }
        rewindFrames = rewindBuffer.count
        if ok != 0 {
            // Re-snapshot framebuffer + CPU so SwiftUI redraws.
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
                         b: raw.b, p: raw.p, pc: raw.pc, e: raw.e != 0)
        if s != cpuState { cpuState = s }
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
        let thumb = SaveStateThumbnail.png(fromBGRA: framebuffer,
                                           width: Int(fbWidth), height: Int(fbHeight))
            ?? Data()
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
        if ok != 0 { NSLog("kintsuki: loaded state \"\(entry.name)\"") }
    }

    func renameState(_ entry: SaveStateEntry, to name: String) {
        guard let ctx = modelContext else { return }
        entry.name = name
        do { try ctx.save() } catch { NSLog("kintsuki: rename failed: \(error)") }
    }

    func deleteState(_ entry: SaveStateEntry) {
        guard let ctx = modelContext else { return }
        ctx.delete(entry)
        do { try ctx.save() } catch { NSLog("kintsuki: delete failed: \(error)") }
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
