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
    @Published private(set) var breakpoints: [Breakpoint] = []

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

    /// 256 CGRAM entries decoded to RGB (8-bit per channel).
    func paletteRGB() -> [(UInt8, UInt8, UInt8)] {
        guard let h = handle else { return [] }
        var out: [(UInt8, UInt8, UInt8)] = []
        out.reserveCapacity(256)
        for i in 0..<256 {
            let lo = kintsuki_cgram_read(h, UInt32(i*2))
            let hi = kintsuki_cgram_read(h, UInt32(i*2 + 1))
            let bgr = UInt16(lo) | (UInt16(hi) << 8)
            // 0bbbbb gggggrrrrr
            let r5 = UInt8((bgr >>  0) & 0x1F)
            let g5 = UInt8((bgr >>  5) & 0x1F)
            let b5 = UInt8((bgr >> 10) & 0x1F)
            // 5-bit → 8-bit (replicate top bits to low bits).
            out.append(((r5 << 3) | (r5 >> 2),
                        (g5 << 3) | (g5 >> 2),
                        (b5 << 3) | (b5 >> 2)))
        }
        return out
    }

    /// Decode a 4bpp 8x8 tile from VRAM at byte offset `addr`. Returns 64
    /// palette indices (0-15). Caller pairs them with a 16-color sub-palette.
    func decodeTile4bpp(addr: UInt32) -> [UInt8] {
        guard let h = handle else { return [] }
        var pixels = [UInt8](repeating: 0, count: 64)
        // 4bpp tile = 32 bytes. Planes interleaved 16 bytes / 16 bytes.
        var raw = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { raw[i] = kintsuki_vram_read(h, addr + UInt32(i)) }
        for y in 0..<8 {
            let p01_lo = raw[y*2]
            let p01_hi = raw[y*2 + 1]
            let p23_lo = raw[16 + y*2]
            let p23_hi = raw[16 + y*2 + 1]
            for x in 0..<8 {
                let bit = UInt8(7 - x)
                let mask: UInt8 = 1 << bit
                let p0: UInt8 = (p01_lo & mask) != 0 ? 1 : 0
                let p1: UInt8 = (p01_hi & mask) != 0 ? 2 : 0
                let p2: UInt8 = (p23_lo & mask) != 0 ? 4 : 0
                let p3: UInt8 = (p23_hi & mask) != 0 ? 8 : 0
                pixels[y*8 + x] = p0 | p1 | p2 | p3
            }
        }
        return pixels
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
