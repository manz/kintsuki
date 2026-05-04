// RewindBuffer — delta-compressed sliding window of savestate frames.
//
// Per-frame capture for smooth backward scrub. To keep memory bounded
// while preserving frame-precise rewind, we store:
//
//   - A *keyframe* (full uncompressed savestate) every
//     `keyframeInterval` frames.
//   - For every non-keyframe between two keyframes, an XOR delta vs
//     the *enclosing keyframe*, compressed via Apple's Compression
//     framework (LZ4 — fast, decent ratio for sparse XOR diffs).
//
// Reconstruction (`materialize(at: i)`) is O(1): find nearest keyframe
// ≤ i, decompress the delta at i, XOR with the keyframe. Eviction
// drops oldest entries; if a keyframe is dropped, the dependent deltas
// it owned are dropped with it (we never expose dangling diffs).
//
// Pure Swift / Foundation / Compression — no AppKit / SwiftUI deps so
// the standalone runner in app/Tests/RewindRingTest.swift compiles.

import Compression
import Foundation

private enum FrameEntry {
    /// Full uncompressed state (keyframe).
    case keyframe(Data)
    /// XOR delta vs the keyframe at `keyframeIndex`, compressed.
    case delta(keyframeIndex: Int, compressed: Data)
}

final class RewindBuffer {
    /// Maximum frames retained. New pushes past this evict the oldest.
    let capacity: Int

    /// Frames between consecutive keyframes. Smaller = more memory but
    /// faster materialize() (smaller delta to decompress); larger =
    /// less memory.
    let keyframeInterval: Int

    /// Logical frames buffered, oldest-to-newest. Each entry is either
    /// a keyframe or a delta against an earlier keyframe in the same
    /// vector.
    private var frames: [FrameEntry] = []

    /// Cached aggregate byte count for `byteSize`.
    private var bytes: Int = 0

    init(capacity: Int, keyframeInterval: Int = 60) {
        precondition(capacity > 0, "capacity must be > 0")
        precondition(keyframeInterval > 0, "keyframeInterval must be > 0")
        self.capacity = capacity
        self.keyframeInterval = keyframeInterval
        frames.reserveCapacity(capacity)
    }

    var count: Int { frames.count }

    /// Approximate retained byte size (keyframes + compressed deltas).
    var byteSize: Int { bytes }

    /// Append a frame. The first frame is always a keyframe; thereafter
    /// every `keyframeInterval`-th frame is a keyframe.
    func push(_ state: Data) {
        let isKeyframe = (frames.count % keyframeInterval) == 0
        let entry: FrameEntry
        if isKeyframe {
            entry = .keyframe(state)
            bytes += state.count
        } else {
            // XOR vs nearest preceding keyframe, then compress.
            let kfIndex = nearestKeyframeIndex(forFrameIndex: frames.count)
            let kf = keyframeData(at: kfIndex)
            let xored = xor(state, kf)
            let compressed = compress(xored)
            entry = .delta(keyframeIndex: kfIndex, compressed: compressed)
            bytes += compressed.count
        }
        frames.append(entry)
        evictExcess()
    }

    /// Reconstruct the state at index `i` (0..<count) over the retained
    /// window. Returns nil if the index is out of range.
    func materialize(at i: Int) -> Data? {
        guard i >= 0, i < frames.count else { return nil }
        switch frames[i] {
        case .keyframe(let data):
            return data
        case .delta(let kfIndex, let compressed):
            // kfIndex is the array index of a keyframe in `frames`.
            let kf = keyframeData(at: kfIndex)
            let xored = decompress(compressed)
            return xor(xored, kf)
        }
    }

    /// Materialize the most-recent frame and remove it. Returns nil if
    /// empty. Subtracts the popped entry's byte cost from `byteSize`.
    func popLast() -> Data? {
        guard let last = frames.last else { return nil }
        let result = materialize(at: frames.count - 1)
        switch last {
        case .keyframe(let d):           bytes -= d.count
        case .delta(_, let compressed):  bytes -= compressed.count
        }
        frames.removeLast()
        return result
    }

    func clear() {
        frames.removeAll(keepingCapacity: true)
        bytes = 0
    }

    // ----- internals ---------------------------------------------------

    private func evictExcess() {
        guard frames.count > capacity else { return }
        var toDrop = frames.count - capacity
        while toDrop > 0 {
            // Always 1-for-1 drop the oldest. To keep the invariant
            // that frames[0] is a keyframe (so deltas have a home),
            // when frames[1] would have been a delta against the
            // dropped keyframe we promote it to a fresh keyframe by
            // materializing first.
            if case .keyframe(let d) = frames[0] {
                bytes -= d.count
                if frames.count > 1, case .delta = frames[1] {
                    // Materialize the delta as a fresh keyframe so the
                    // remainder of the chain stays valid after we drop
                    // the original.
                    if let materialized = materialize(at: 1) {
                        // Replace frames[1]'s delta entry with a
                        // keyframe; subtract old compressed cost, add
                        // full state cost.
                        if case .delta(_, let oldComp) = frames[1] {
                            bytes -= oldComp.count
                        }
                        frames[1] = .keyframe(materialized)
                        bytes += materialized.count
                    }
                }
                frames.removeFirst()
                toDrop -= 1
            } else if case .delta(_, let comp) = frames[0] {
                // Shouldn't happen post-renumber, but be safe.
                bytes -= comp.count
                frames.removeFirst()
                toDrop -= 1
            }
        }
        renumberKeyframeIndices()
    }

    private func renumberKeyframeIndices() {
        var lastKeyframe = -1
        for idx in 0..<frames.count {
            switch frames[idx] {
            case .keyframe:
                lastKeyframe = idx
            case .delta(_, let comp):
                precondition(lastKeyframe >= 0,
                             "delta at index \(idx) with no preceding keyframe")
                frames[idx] = .delta(keyframeIndex: lastKeyframe,
                                     compressed: comp)
            }
        }
    }

    private func nearestKeyframeIndex(forFrameIndex i: Int) -> Int {
        // Walk backwards from i-1 looking for a keyframe entry.
        var j = i - 1
        while j >= 0 {
            if case .keyframe = frames[j] { return j }
            j -= 1
        }
        // Should never happen — frame 0 is always a keyframe.
        preconditionFailure("no keyframe before index \(i)")
    }

    private func keyframeData(at j: Int) -> Data {
        if case .keyframe(let d) = frames[j] { return d }
        preconditionFailure("expected keyframe at index \(j)")
    }
}

// ---- Byte helpers ------------------------------------------------------
private func xor(_ a: Data, _ b: Data) -> Data {
    precondition(a.count == b.count, "xor: size mismatch \(a.count) vs \(b.count)")
    var out = Data(count: a.count)
    out.withUnsafeMutableBytes { dstRaw in
        a.withUnsafeBytes { aRaw in
            b.withUnsafeBytes { bRaw in
                // Word-at-a-time XOR over the head of the buffer; per-byte
                // tail handles any size that isn't a multiple of 8.
                let dstU64 = dstRaw.bindMemory(to: UInt64.self)
                let aU64   = aRaw.bindMemory(to: UInt64.self)
                let bU64   = bRaw.bindMemory(to: UInt64.self)
                let words  = dstU64.count
                for i in 0..<words {
                    dstU64[i] = aU64[i] ^ bU64[i]
                }
                let tailStart = words * 8
                let dst = dstRaw.bindMemory(to: UInt8.self)
                let pa  = aRaw.bindMemory(to: UInt8.self)
                let pb  = bRaw.bindMemory(to: UInt8.self)
                for i in tailStart..<dst.count {
                    dst[i] = pa[i] ^ pb[i]
                }
            }
        }
    }
    return out
}

private func compress(_ data: Data) -> Data {
    // Length-prefix the original size so decompress() can size its
    // destination buffer without ambiguity. Apple's compression_decode
    // family wants a known dst size.
    var prefix = UInt32(data.count).littleEndian
    var header = Data(bytes: &prefix, count: 4)
    let dstCap = data.count + 64
    var compressed = Data(count: dstCap)
    let written = compressed.withUnsafeMutableBytes { dstRaw -> Int in
        data.withUnsafeBytes { srcRaw -> Int in
            let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
            let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
            return compression_encode_buffer(
                dst, dstCap, src, data.count, nil, COMPRESSION_LZ4)
        }
    }
    if written == 0 {
        // Fallback: store raw bytes inline. Header bit 31 of `prefix`
        // disambiguates; we use a 0-length compressed payload as the
        // signal "data is uncompressed in the next `prefix` bytes".
        var rawHeader = UInt32(data.count).littleEndian | 0x8000_0000
        var raw = Data(bytes: &rawHeader, count: 4)
        raw.append(data)
        return raw
    }
    compressed.count = written
    header.append(compressed)
    return header
}

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
    let written = out.withUnsafeMutableBytes { dstRaw -> Int in
        payload.withUnsafeBytes { srcRaw -> Int in
            let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
            let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
            return compression_decode_buffer(
                dst, uncompressedSize, src, payload.count, nil,
                COMPRESSION_LZ4)
        }
    }
    precondition(written == uncompressedSize,
                 "decompress: size mismatch \(written) vs \(uncompressedSize)")
    return out
}
