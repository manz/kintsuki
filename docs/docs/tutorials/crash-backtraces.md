# Crash backtraces with .adbg

When a SNES ROM goes into the weeds, the symptom is usually the CPU
landing at a wild PC and eventually executing STP (often via a stray
BRK that decodes random memory). kintsuki's shadow callstack + .adbg
integration give you a real backtrace at that point.

## What you need

- An assembled ROM with a `.adbg` debug-info file next to it (a816
  emits one alongside any `-f sfc` build).
- `kintsuki.Emu` driving the cart (Python) **or** Kintsuki.app pointing
  at it (macOS).

## In Python

```python
from kintsuki import Emu

with Emu() as emu:
    emu.load_rom("ff4.sfc")
    emu.load_adbg("ff4.sfc.adbg")
    while not emu.get_state().stp:
        emu.run_frames(1)

    print(f"CPU STP @ {emu.get_state().pc:06X}")
    for i, (callsite, target, kind) in enumerate(emu.callstack()):
        op = ("JSR", "JSL")[kind]
        if hit := emu.lookup_label_containing(callsite):
            name, off = hit
            label = f"in {name}+0x{off:X}" if off else f"in {name}"
        else:
            label = ""
        if src := emu.lookup_source(callsite):
            file, line, _ = src
            label += f"  ({file}:{line})"
        print(f"#{i:<2} {callsite:06X}  ({op}) → {target:06X}  {label}")
```

Output:

```
CPU STP @ 5C:FFF5
#0  00:80E9  (JSR) → 00:8000  in nmi_handler+0xE9  (interrupts.s:142)
#1  00:8914  (JSR) → 00:8900  in update_actor+0x14
#2  00:899A  (JSL) → 03:8000  in main_loop+0x9A
...
```

## In Kintsuki.app

`Emu.loadROM` auto-loads `<rom>.adbg` if it sits next to the cart. When
the CPU executes STP, a halt overlay drops in over the framebuffer with
the resolved backtrace, a Copy button (NSPasteboard), and inline Reset
/ Reload buttons. The text is selectable so you can highlight one frame
and ⌘C it.

## Why containing-label, not exact-match

`Emu.lookup_label(addr)` is exact: matches only when `addr` is
a label start. Callsites almost never land there (they point at the
JSR/JSL opcode somewhere inside the calling routine).

`lookup_label_containing(addr)` returns the label whose address is the
largest ≤ `addr`, plus the byte offset into that symbol — which is what
you actually want for "name the routine this PC is inside".
