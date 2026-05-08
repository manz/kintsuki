# Rewind buffer

Per-frame savestate ring with delta compression. Used by the macOS app's
CMD+← scrubbing UI; nothing stops Python tests from poking the same API
for "go back 30 frames and try again" workflows.

## Capacity model

Default geometry: 3600 frames (~60 s at 60 fps), keyframe every 60. At
saturation:

- 60 keyframes × ~256 KB = ~15 MB
- 3540 LZ4-compressed XOR deltas × ~10 KB = ~35 MB
- ~50 MB total resident

Keyframe slots are **preallocated** in a `SaveStatePool`: the 60 Hz
producer never allocates a fresh ~256 KB Data per keyframe; ares writes
straight into the next free slot. Deltas reuse a shared XOR + LZ4
workspace.

## Ring buffer (true O(1))

`frames` is a fixed `[FrameEntry?]` of `capacity` slots with `ringHead`
+ `ringSize` indices. push wraps around; eviction is `head = (head+1) %
capacity`. No `Array.removeFirst()` element-shift cost.

Delta entries reference their keyframe by a **monotonic logical id**
(not an array index that shifts on eviction), so eviction never has to
walk + rewrite the buffer.

## Producer-style push

```swift
rewindBuffer.push(count: needed) { dst in
    return Int(kintsuki_save_state(h, dst.baseAddress, UInt32(dst.count)))
}
```

ares writes the savestate directly into the pool slot or the shared
scratch buffer. Eliminates the per-frame ~256 KB Data allocation that
the prior path had.

## Reading back

```swift
if let bytes = rewindBuffer.popLast() { ... }
if let bytes = rewindBuffer.materialize(at: i) { ... }
rewindBuffer.clear()
```

`popLast()` returns the most-recent frame and removes it.
`materialize(at: i)` reconstructs the frame at index `i` (XOR-decompress
if delta).

## Backpressure (no longer needed)

Earlier alphas pushed every frame onto a serial worker queue with no
cap; pending closures pinned hundreds of MB of `Data` blobs in flight.
The producer-style push runs on the main thread now (XOR + LZ4 ~1-2 ms,
fits in the 16 ms frame budget) so the queue is gone — there's no
intermediate `Data` to pin.
