// Standalone Swift test for RewindBuffer. Compile + run via:
//
//   swiftc -parse-as-library -o /tmp/rewind_buffer_test \
//          Sources/Kintsuki/RewindBuffer.swift Tests/RewindRingTest.swift && \
//   /tmp/rewind_buffer_test
//
// Pure-Swift / Foundation harness — no XCTest target, no AppKit.

import Foundation

@main
struct RewindBufferTest {
    static var failed = 0

    static func check(_ ok: Bool, _ msg: String,
                      file: StaticString = #file, line: UInt = #line) {
        if !ok {
            print("FAIL [\(file):\(line)] \(msg)")
            failed += 1
        }
    }

    static func main() {
        // Synthetic 256 KB "savestate" filled with a deterministic pattern;
        // mutated slightly per frame so deltas compress well (just like a
        // real ROM where the screen and a handful of WRAM bytes change).
        func fakeState(seed: UInt8) -> Data {
            var d = Data(count: 256 * 1024)
            d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let p = raw.bindMemory(to: UInt8.self)
                for i in 0..<p.count {
                    p[i] = UInt8((Int(seed) &+ (i % 17)) & 0xFF)
                }
                // Sprinkle ~32 random changing bytes (drives delta size).
                for j in 0..<32 {
                    p[(j * 137) % p.count] = seed &+ UInt8(j)
                }
            }
            return d
        }

        // ---- basic: capacity, count, materialize ------------------------
        do {
            let buf = RewindBuffer(capacity: 5, keyframeInterval: 2)
            check(buf.capacity == 5, "capacity stored")
            check(buf.count == 0, "fresh buffer is empty")
            check(buf.materialize(at: 0) == nil, "materialize on empty = nil")
        }

        // ---- round-trip: push then materialize each frame --------------
        do {
            let buf = RewindBuffer(capacity: 100, keyframeInterval: 3)
            let states = (0..<10).map { fakeState(seed: UInt8($0)) }
            for s in states {
                buf.push(s)
            }
            check(buf.count == 10, "count tracks pushes")
            for (i, want) in states.enumerated() {
                let got = buf.materialize(at: i)
                check(got == want,
                      "frame \(i) materializes back to original state")
            }
        }

        // ---- popLast walks backward through frames ---------------------
        do {
            let buf = RewindBuffer(capacity: 100, keyframeInterval: 4)
            let states = (0..<6).map { fakeState(seed: UInt8($0 * 5)) }
            for s in states { buf.push(s) }
            // Pop most-recent first; should match in reverse order.
            for want in states.reversed() {
                let got = buf.popLast()
                check(got == want, "popLast returns frames newest-first")
            }
            check(buf.popLast() == nil, "drained popLast = nil")
            check(buf.count == 0, "drained buffer count = 0")
        }

        // ---- capacity overflow drops oldest, keeping reconstruction ----
        do {
            let buf = RewindBuffer(capacity: 5, keyframeInterval: 2)
            let states = (0..<8).map { fakeState(seed: UInt8($0)) }
            for s in states { buf.push(s) }
            check(buf.count == 5, "overflow caps at capacity")
            // After eviction, the materialize indices are 0..<count over
            // the *retained* window, oldest-to-newest:
            let retained = Array(states.suffix(5))
            for (i, want) in retained.enumerated() {
                let got = buf.materialize(at: i)
                check(got == want,
                      "post-eviction frame \(i) reconstructs correctly")
            }
        }

        // ---- delta compression actually shrinks --------------------------
        do {
            let buf = RewindBuffer(capacity: 200, keyframeInterval: 60)
            let s0 = fakeState(seed: 0)
            buf.push(s0)
            // Push 59 nearly-identical frames; deltas should be tiny.
            for i in 1..<60 {
                buf.push(fakeState(seed: UInt8(i)))
            }
            // Memory footprint of the buffer = 1 keyframe (~256 KB) +
            // 59 small deltas. Sanity: total < 2× the keyframe size,
            // not 60× (which would mean we stored every frame uncompressed).
            let bytes = buf.byteSize
            check(bytes < 2 * s0.count,
                  "delta compression is meaningful (got \(bytes) bytes, "
                  + "raw would be \(60 * s0.count))")
        }

        // ---- clear --------------------------------------------------------
        do {
            let buf = RewindBuffer(capacity: 5, keyframeInterval: 2)
            buf.push(fakeState(seed: 1))
            buf.push(fakeState(seed: 2))
            buf.clear()
            check(buf.count == 0, "clear empties the buffer")
            check(buf.popLast() == nil, "popLast after clear = nil")
        }

        if failed == 0 {
            print("OK: RewindBuffer tests passed")
        } else {
            print("FAIL: \(failed) RewindBuffer test(s) failed")
            exit(1)
        }
    }
}
