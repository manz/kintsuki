# Tracer

A formatted execution log: one line per executed instruction, Mesen-style.
Lines carry `BB:AAAA` PC prefix, the disassembled instruction, register
context, and — when a `.adbg` is loaded — the resolved label of any
JSR/JSL/JMP/branch target inline plus `; --- name ---` headers above
labelled PCs.

## Modes

- **RING** (default): bounded byte buffer in memory, oldest evicted on
  overflow. `tracer_drain()` returns the contents and clears.
- **FILE**: lines written straight to disk. `tracer_drain()` returns
  empty.

```python
# RING — investigative window
emu.tracer_start(lo=0x008000, hi=0x0080FF, ring_capacity=4096)
emu.run_frames(2)
text = emu.tracer_drain()
emu.tracer_stop()

# FILE — long capture
emu.tracer_start(lo=0x000000, hi=0xFFFFFF, path="run.log")
emu.run_frames(60)
emu.tracer_stop()
```

## Sample output

```
00:8000 sei                              ; A:0000 X:0000 Y:0000 ...
; --- reset ---
00:8001 clc                              ; A:0000 X:0000 Y:0000 ...
00:8002 xce                              ; A:0000 X:0000 Y:0000 ...
00:800B jsl $008100             [008100] ; A:0000 ... -> outer
; --- outer ---
00:8100 nop                              ; A:0000 ...
00:8101 jsr $8200               [008200] ; A:0000 ... -> inner
; --- inner ---
00:8200 nop                              ; A:0000 ...
00:8201 stp                              ; A:0000 ...
```

The `→ name` arrow on JSR/JSL/JMP/Bxx fires only when the static target
resolves against the loaded `.adbg`. Indirect / indexed jumps are skipped
(target depends on register state).

## Label table

```python
emu.load_adbg("rom.sfc.adbg")
```

Once loaded, the native tracer prepends a `; --- name ---` header above
the first line whose PC matches a label. Tight loops at the same label
don't repeat the header.

## Symbol-scoped masking

The default `[lo, hi]` range is coarse. For per-routine traces, set a
list of `(start, size)` ranges — only PCs inside any of them fire:

```python
emu.tracer_set_ranges([(0x209845, 0x40), (0x803C00, 0x100)])
emu.tracer_start(lo=0x000000, hi=0xFFFFFF, path="masked.log")
```

Or by symbol name:

```python
unresolved = emu.tracer_mask_symbols([
    ("DrawHUD",    0x80),
    ("UpdateActor", 0x200),
])
# unresolved = ["UpdateActor"] if .adbg has no such label
```

`tracer_set_ranges(None)` clears the mask and falls back to `[lo, hi]`.
Sticky across stop/start so configure once and run multiple sessions.
