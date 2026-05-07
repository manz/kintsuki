# Shadow callstack

Per-instruction exec hooks would burn 3-4M trampolines per second at
SNES speed. Instead, kintsuki patches ares' four call/return instruction
methods (`CallShort`, `CallLong`, `ReturnShort`, `ReturnLong`) so the
hooks fire only on JSR/JSL/RTS/RTL — one indirect call per call/return.

Frames are kept in a 256-entry ring; older frames roll off if a misbehaving
program nests deeper. `kintsuki_load_state` and `kintsuki_rearm_cpu`
clear the stack automatically: the live call chain belongs to the
pre-load timeline.

## Frame shape

| Field         | Notes                                         |
|---------------|-----------------------------------------------|
| `callsite_pc` | 24-bit address of the JSR/JSL opcode itself   |
| `target_pc`   | 24-bit address being called                   |
| `kind`        | `0` = JSR (short), `1` = JSL (long)           |

Snapshot deepest-frame-first:

```python
for callsite, target, kind in emu.callstack():
    print(f"{callsite:06X} → {target:06X} {['JSR','JSL'][kind]}")
```

`emu.callstack_clear()` drops every retained frame. Useful between
back-to-back test stubs.

## Crash backtraces

When the CPU executes STP, the macOS app's halt overlay fetches a
backtrace and resolves each frame against `.adbg`:

```
Game stopped — CPU STP @ 5C:FFF5
#0  00:80E9  in nmi_handler+0xE9     (interrupts.s:142)
#1  00:8914  in update_actor+0x14
...
```

Symbolication uses `lookup_label_containing` (the largest label ≤ PC)
plus the `.adbg` LINES section for source file/line. Frames without a
match render the bare `BB:AAAA`.

## Caveat: chained-delta correctness on keyframe eviction

The rewind buffer's eviction path promotes a delta to a keyframe when
the oldest keyframe is dropped, but the chained deltas downstream still
reference the evicted keyframe's logical id and won't materialize
correctly after the roll-over. Documented in the source; doesn't affect
the shadow callstack, only the bytes-correctness of materializing
*older* rewind frames after a long run.
