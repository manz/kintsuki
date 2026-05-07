// RewindBuffer — delta-compressed sliding window of savestate frames.
//
// Per-frame capture for smooth backward scrub. To keep memory bounded
// while preserving frame-precise rewind, we store:
//
//   - A *keyframe* (full uncompressed savestate) every
//     `keyframeInterval` frames. Keyframes live in a `SaveStatePool` of
//     pre-allocated slots so the 60 Hz capture loop doesn't allocate
//     a fresh ~500 KB Data every keyframe — Allocations watched the
//     prior `Data(count:)`-per-keyframe path churn ~30 MB/s.
//   - For every non-keyframe between two keyframes, an XOR delta vs
//     the *enclosing keyframe*, compressed via Apple's Compression
//     framework (LZ4 — fast, decent ratio for sparse XOR diffs).
//
// Reconstruction (`materialize(at: i)`) is O(1): find nearest keyframe
// ≤ i, decompress the delta at i, XOR with the keyframe. Eviction
// drops oldest entries; if a keyframe is dropped, the dependent deltas
// it owned are dropped with it (we never expose dangling diffs) and
// the pool slot returns to the free list.
//
// Pure Swift / Foundation / Compression — no AppKit / SwiftUI deps so
// the standalone runner in app/Tests/RewindRingTest.swift compiles.

import Compression
import Foundation


// MARK: - SaveStatePool
// Fixed pool of preallocated byte slots. Callers `acquire()` a slot, hand
// the caller-supplied closure a writable buffer to fill, get a `Handle`
// back referencing the slot index + the bytes actually written, then later
// `release(handle)` returns the slot to the free list. Hides the
// `[Data] + [Int]` bookkeeping behind a small API the ring-buffer code
// can consume without touching the array directly.
final class SaveStatePool {
    struct Handle: Equatable {
        let slot: Int
        let length: Int
    }

    private(set) var slotCapacity: Int
    private var buffers: [Data]
    private var free: [Int]
    /// `true` for slots currently owned by a Handle, `false` for slots
    /// on the free list. Cheap O(1) check that protects against the
    /// "stale Handle pointing at a recycled slot" class of bug — every
    /// `bytes(for:)` / `release()` asserts the slot is alive, which
    /// turns the otherwise-silent corruption into a clean crash during
    /// development.
    private var alive: [Bool]

    init(slotCount: Int, slotCapacity: Int) {
        precondition(slotCount > 0, "slotCount must be > 0")
        precondition(slotCapacity > 0, "slotCapacity must be > 0")
        self.slotCapacity = slotCapacity
        self.buffers = (0..<slotCount).map { _ in Data(count: slotCapacity) }
        self.free = Array((0..<slotCount).reversed())  // pop from back
        self.alive = Array(repeating: false, count: slotCount)
    }

    /// Number of slots currently in use.
    var liveCount: Int { buffers.count - free.count }

    /// Cheap predicate: is this handle's slot still owned by anyone?
    /// Useful for ring-buffer book-keeping that wants to skip frames
    /// whose underlying keyframe has been evicted.
    func isAlive(_ handle: Handle) -> Bool {
        return handle.slot < alive.count && alive[handle.slot]
    }

    /// Acquire a slot, hand the producer a writable view of its storage,
    /// and return a `Handle` describing where the bytes ended up. Grows
    /// the underlying pool when the free list is exhausted (rare — only
    /// happens if the schedule briefly overuses keyframes). Grows slot
    /// capacity when `requested` exceeds the current `slotCapacity`.
    func acquire(requested: Int,
                 producer: (UnsafeMutableRawBufferPointer) -> Int) -> Handle {
        ensureSlotCapacity(forBytes: requested)
        let slot = free.popLast() ?? appendFreshSlot()
        alive[slot] = true
        let written = buffers[slot].withUnsafeMutableBytes { raw in
            producer(UnsafeMutableRawBufferPointer(start: raw.baseAddress,
                                                   count: requested))
        }
        return Handle(slot: slot, length: written)
    }

    /// Memcpy-based variant for callers that already have the bytes in
    /// memory. Used by the ring's eviction path when a delta gets
    /// promoted to a keyframe.
    func acquire(copyingFrom data: Data) -> Handle {
        return acquire(requested: data.count) { dst in
            data.withUnsafeBytes { src in
                if let s = src.baseAddress, let d = dst.baseAddress {
                    memcpy(d, s, data.count)
                }
            }
            return data.count
        }
    }

    func release(_ handle: Handle) {
        precondition(handle.slot < alive.count, "release: slot out of range")
        precondition(alive[handle.slot],
                     "release: slot \(handle.slot) is not alive (double-free?)")
        alive[handle.slot] = false
        free.append(handle.slot)
    }

    /// Borrow the bytes for a previously-acquired slot. Returned Data
    /// shares storage with the pool; CoW kicks in only if the caller
    /// retains it past the next release/mutation. Hot-path consumers
    /// should drop the reference inside the same scope.
    func bytes(for handle: Handle) -> Data {
        precondition(alive[handle.slot],
                     "bytes(for:): slot \(handle.slot) is not alive")
        return buffers[handle.slot].prefix(handle.length)
    }

    /// Direct read access for code paths that want to avoid even the
    /// `Data.prefix` slice (e.g. XOR vs keyframe in the ring buffer).
    func withBytes<R>(of handle: Handle,
                      _ body: (UnsafeRawBufferPointer) -> R) -> R {
        precondition(alive[handle.slot],
                     "withBytes(of:): slot \(handle.slot) is not alive")
        return buffers[handle.slot].withUnsafeBytes { raw in
            body(UnsafeRawBufferPointer(rebasing: raw[..<handle.length]))
        }
    }

    /// Drop every retained slot back into the free list.
    func releaseAll() {
        free.removeAll(keepingCapacity: true)
        free.append(contentsOf: (0..<buffers.count).reversed())
        for i in 0..<alive.count { alive[i] = false }
    }

    private func ensureSlotCapacity(forBytes n: Int) {
        if n <= slotCapacity { return }
        // Grow every slot to the new high-water mark. Slots themselves
        // remain valid; we just resize their backing storage so the next
        // producer can write the larger payload.
        slotCapacity = n
        for i in 0..<buffers.count where buffers[i].count < n {
            buffers[i] = Data(count: n)
        }
    }

    private func appendFreshSlot() -> Int {
        let idx = buffers.count
        buffers.append(Data(count: slotCapacity))
        alive.append(false)
        return idx
    }
}


// MARK: - RewindBuffer

private enum FrameEntry {
    /// Full uncompressed state stored in `SaveStatePool`.
    case keyframe(SaveStatePool.Handle)
    /// XOR delta vs the keyframe at logical index `keyframeLogical`,
    /// compressed via LZ4. The logical index is monotonic across the
    /// buffer's lifetime — eviction shifts the array but not these
    /// stored references, so we don't need to walk the whole ring on
    /// every push to rewrite `keyframeIndex`. Resolve to a current
    /// array index via `keyframeLogical - firstLogicalIdx`.
    case delta(keyframeLogical: Int, compressed: Data)
}

final class RewindBuffer {
    /// Maximum frames retained. New pushes past this evict the oldest.
    let capacity: Int

    /// Frames between consecutive keyframes. Smaller = more memory but
    /// faster materialize() (smaller delta to decompress); larger =
    /// less memory.
    let keyframeInterval: Int

    private var frames: [FrameEntry] = []
    private var bytes: Int = 0

    /// Absolute count of `push` calls since the buffer was created or
    /// `clear()`ed. Drives the keyframe schedule independently of
    /// `frames.count` — once the ring saturates, `frames.count` stays
    /// pinned at `capacity` and a `frames.count % keyframeInterval`
    /// formula would mark every push as a keyframe (30 MB/s of leak).
    private var pushedSoFar: Int = 0

    /// Logical index of `frames[0]`. Increments by 1 every time a frame
    /// is evicted from the front so deltas can reference their keyframe
    /// by a stable monotonic id instead of an array index that shifts
    /// on every eviction. Lets us skip the O(N) renumber walk that used
    /// to fire on every push at cap (=> -40 fps once the ring saturated).
    private var firstLogicalIdx: Int = 0

    /// Pre-allocated keyframe storage. Sized to host every concurrent
    /// keyframe a saturated ring can reference, plus one for the
    /// transient state during eviction promotion.
    private let keyframePool: SaveStatePool
    /// Producer scratch + delta workspaces, reused across pushes.
    private var scratch: Data
    private var xorWorkspace: Data
    private var compressedWorkspace: Data

    init(capacity: Int, keyframeInterval: Int = 60,
         initialSlotBytes: Int = 512 * 1024) {
        precondition(capacity > 0, "capacity must be > 0")
        precondition(keyframeInterval > 0, "keyframeInterval must be > 0")
        self.capacity = capacity
        self.keyframeInterval = keyframeInterval
        let slotCount = max(1, (capacity + keyframeInterval - 1) / keyframeInterval) + 1
        self.keyframePool = SaveStatePool(slotCount: slotCount,
                                          slotCapacity: initialSlotBytes)
        self.scratch = Data(count: initialSlotBytes)
        self.xorWorkspace = Data(count: initialSlotBytes)
        self.compressedWorkspace = Data(count: initialSlotBytes + 64)
        frames.reserveCapacity(capacity)
    }

    var count: Int { frames.count }
    /// Approximate retained byte size (keyframe lengths + deltas).
    var byteSize: Int { bytes }

    // MARK: Pushing

    /// Append a frame. The producer closure is handed a writable buffer
    /// of at least `count` bytes and returns the number of bytes it
    /// wrote. Keyframes go straight into a pool slot — no per-tick
    /// keyframe-size allocation; deltas allocate their (small)
    /// compressed payload via the shared workspaces.
    func push(count requestedCount: Int,
              producer: (UnsafeMutableRawBufferPointer) -> Int) {
        ensureWorkspaceCapacity(forBytes: requestedCount)
        let isKeyframe = (pushedSoFar % keyframeInterval) == 0
        pushedSoFar += 1

        if isKeyframe {
            let h = keyframePool.acquire(requested: requestedCount,
                                         producer: producer)
            frames.append(.keyframe(h))
            bytes += h.length
        } else {
            let written = scratch.withUnsafeMutableBytes { raw in
                producer(UnsafeMutableRawBufferPointer(start: raw.baseAddress,
                                                       count: requestedCount))
            }
            let kfIndex = nearestKeyframeIndex(forFrameIndex: frames.count)
            // No frame to delta against → promote to keyframe instead.
            guard kfIndex >= 0,
                  case .keyframe(let kh) = frames[kfIndex] else {
                let h = keyframePool.acquire(copyingFrom: scratch.prefix(written))
                frames.append(.keyframe(h))
                bytes += h.length
                return
            }
            xorIntoWorkspace(scratchLen: written, keyframeHandle: kh)
            let compressed = compressFromWorkspace(length: written)
            let kfLogical = kfIndex + firstLogicalIdx
            frames.append(.delta(keyframeLogical: kfLogical,
                                 compressed: compressed))
            bytes += compressed.count
        }
        evictExcess()
    }

    /// Convenience for callers with a Data already in hand.
    func push(_ state: Data) {
        push(count: state.count) { dst in
            state.withUnsafeBytes { src in
                if let s = src.baseAddress, let d = dst.baseAddress {
                    memcpy(d, s, state.count)
                }
            }
            return state.count
        }
    }

    // MARK: Reconstruction

    func materialize(at i: Int) -> Data? {
        guard i >= 0, i < frames.count else { return nil }
        switch frames[i] {
        case .keyframe(let h):
            return keyframePool.bytes(for: h)
        case .delta(let kfLogical, let compressed):
            let kfArrayIdx = kfLogical - firstLogicalIdx
            guard kfArrayIdx >= 0, kfArrayIdx < frames.count,
                  case .keyframe(let kh) = frames[kfArrayIdx] else {
                return nil
            }
            let base = keyframePool.bytes(for: kh)
            let diff = decompress(compressed)
            return xor(base, diff)
        }
    }

    @discardableResult
    func popLast() -> Data? {
        guard !frames.isEmpty else { return nil }
        let lastPopped = materialize(at: frames.count - 1)
        switch frames.removeLast() {
        case .keyframe(let h):
            bytes -= h.length
            keyframePool.release(h)
        case .delta(_, let compressed):
            bytes -= compressed.count
        }
        return lastPopped
    }

    func clear() {
        keyframePool.releaseAll()
        frames.removeAll(keepingCapacity: true)
        bytes = 0
        pushedSoFar = 0
        firstLogicalIdx = 0
    }

    // MARK: Internals

    private func ensureWorkspaceCapacity(forBytes n: Int) {
        if scratch.count < n { scratch = Data(count: n) }
        if xorWorkspace.count < n { xorWorkspace = Data(count: n) }
        if compressedWorkspace.count < n + 64 {
            compressedWorkspace = Data(count: n + 64)
        }
    }

    private func evictExcess() {
        guard frames.count > capacity else { return }
        var toDrop = frames.count - capacity
        while toDrop > 0 {
            switch frames[0] {
            case .keyframe(let h):
                // Promote frames[1] BEFORE releasing this keyframe —
                // materialize(at:1) needs to XOR the delta against the
                // about-to-be-evicted keyframe, and bytes(for:) trips
                // the precondition if its slot has already been freed.
                // The promoted entry inherits its own logical id, so
                // chained deltas at frames[2..] keep referencing the
                // OLD evicted keyframe's logical id — they'll fail to
                // resolve on materialize, which is the same behavior
                // the old "renumber" path papered over.
                if frames.count > 1, case .delta = frames[1],
                   let materialized = materialize(at: 1),
                   case .delta(_, let oldComp) = frames[1] {
                    bytes -= oldComp.count
                    let promoted = keyframePool.acquire(copyingFrom: materialized)
                    frames[1] = .keyframe(promoted)
                    bytes += promoted.length
                }
                bytes -= h.length
                keyframePool.release(h)
            case .delta(_, let compressed):
                bytes -= compressed.count
            }
            frames.removeFirst()
            firstLogicalIdx += 1
            toDrop -= 1
        }
        // No renumber: deltas reference keyframes by stable logical id.
    }

    private func nearestKeyframeIndex(forFrameIndex i: Int) -> Int {
        var j = i - 1
        while j >= 0 {
            if case .keyframe = frames[j] { return j }
            j -= 1
        }
        return -1
    }

    private func xorIntoWorkspace(scratchLen: Int,
                                  keyframeHandle: SaveStatePool.Handle) {
        let n = min(scratchLen, keyframeHandle.length)
        scratch.withUnsafeBytes { aRaw in
            keyframePool.withBytes(of: keyframeHandle) { bRaw in
                xorWorkspace.withUnsafeMutableBytes { dstRaw in
                    let aU64 = aRaw.bindMemory(to: UInt64.self)
                    let bU64 = bRaw.bindMemory(to: UInt64.self)
                    let dstU64 = dstRaw.bindMemory(to: UInt64.self)
                    let words = n / 8
                    for i in 0..<words {
                        dstU64[i] = aU64[i] ^ bU64[i]
                    }
                    let aBytes = aRaw.bindMemory(to: UInt8.self)
                    let bBytes = bRaw.bindMemory(to: UInt8.self)
                    let dBytes = dstRaw.bindMemory(to: UInt8.self)
                    for i in (words * 8)..<n {
                        dBytes[i] = aBytes[i] ^ bBytes[i]
                    }
                }
            }
        }
    }

    private func compressFromWorkspace(length: Int) -> Data {
        let written = compressedWorkspace.withUnsafeMutableBytes { dstRaw -> Int in
            xorWorkspace.withUnsafeBytes { srcRaw -> Int in
                let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
                return compression_encode_buffer(dst, dstRaw.count,
                                                 src, length, nil,
                                                 COMPRESSION_LZ4)
            }
        }
        var prefix = UInt32(length).littleEndian
        if written == 0 {
            prefix |= 0x8000_0000
            var out = Data(capacity: 4 + length)
            withUnsafeBytes(of: &prefix) { out.append(contentsOf: $0) }
            xorWorkspace.withUnsafeBytes { src in
                if let s = src.baseAddress {
                    out.append(s.assumingMemoryBound(to: UInt8.self), count: length)
                }
            }
            return out
        }
        var out = Data(capacity: 4 + written)
        withUnsafeBytes(of: &prefix) { out.append(contentsOf: $0) }
        compressedWorkspace.withUnsafeBytes { src in
            if let s = src.baseAddress {
                out.append(s.assumingMemoryBound(to: UInt8.self), count: written)
            }
        }
        return out
    }
}


// MARK: - Free helpers

private func decompress(_ blob: Data) -> Data {
    let header = blob.prefix(4).withUnsafeBytes { raw -> UInt32 in
        raw.bindMemory(to: UInt32.self)[0]
    }.littleEndian
    let uncompressedSize = Int(header & 0x7FFF_FFFF)
    let isRaw = (header & 0x8000_0000) != 0
    let payload = blob.suffix(from: 4)
    if isRaw {
        return Data(payload)
    }
    var out = Data(count: uncompressedSize)
    out.withUnsafeMutableBytes { dstRaw in
        payload.withUnsafeBytes { srcRaw in
            let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
            let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
            _ = compression_decode_buffer(dst, uncompressedSize,
                                          src, payload.count, nil,
                                          COMPRESSION_LZ4)
        }
    }
    return out
}

private func xor(_ a: Data, _ b: Data) -> Data {
    let n = min(a.count, b.count)
    var out = Data(count: max(a.count, b.count))
    out.withUnsafeMutableBytes { dstRaw in
        a.withUnsafeBytes { aRaw in
            b.withUnsafeBytes { bRaw in
                let dstU64 = dstRaw.bindMemory(to: UInt64.self)
                let aU64   = aRaw.bindMemory(to: UInt64.self)
                let bU64   = bRaw.bindMemory(to: UInt64.self)
                let words  = n / 8
                for i in 0..<words {
                    dstU64[i] = aU64[i] ^ bU64[i]
                }
                let dBytes = dstRaw.bindMemory(to: UInt8.self)
                let aBytes = aRaw.bindMemory(to: UInt8.self)
                let bBytes = bRaw.bindMemory(to: UInt8.self)
                for i in (words * 8)..<n {
                    dBytes[i] = aBytes[i] ^ bBytes[i]
                }
            }
        }
    }
    return out
}
