# Run a ROM from Python

End-to-end: install, load a ROM, advance, inspect state, capture a PNG.

## Install

```bash
pip install kintsuki                # base wheel
pip install 'kintsuki[visual]'      # + numpy / numba / Pillow for goldens
```

The wheel ships with a precompiled `libkintsuki.dylib` (or `.so` on
Linux) and the ares System pak (`boards.bml` + `ipl.rom`) bundled inside
the package — no separate ares install.

## Boot

```python
from kintsuki import Emu

with Emu() as emu:
    emu.load_rom("ff4.sfc")
    emu.run_frames(60)              # 1 second @ 60 fps
    s = emu.get_state()
    print(f"PC=${s.pc:06X}  A=${s.a:04X}")
```

`Emu()` is a context manager. The `__exit__` calls `kintsuki_destroy`
and clears all hooks so the next instance starts clean.

## Inspecting WRAM

```python
# Single byte
b = emu.read(0x7E1700)

# Bulk (zero-copy memoryview over a ctypes buffer)
mv = emu.read_range(0x7E1700, 256)
print(bytes(mv[:8]).hex())          # "ab00..."
```

VRAM / CGRAM / OAM all have `*_read_range` shapes. `emu.vram_read_range()`
with no args dumps the whole 64 KB.

## Driving input

```python
from kintsuki import Button
emu.press(port=0, button=Button.A, pressed=True)
emu.run_frames(2)
emu.press(port=0, button=Button.A, pressed=False)
```

There's also a higher-level recorder API (`kintsuki.input` / recorder
modules) for scripted sequences.

## Save state round-trip

```python
checkpoint = emu.save_state()
emu.run_frames(120)
emu.load_state(checkpoint)         # back where we were
```

The `Emu.load_state` Python wrapper rearms the libco coroutine
internally — no separate step needed.

## Screenshot

```python
emu.screenshot("after-1s.png")     # canonical RGB PNG
```

Width is hires-aware: 282×242 in normal mode, 564×242 in BGMODE 5/6 /
pseudo-hires. See [Visual oracle](../visual-oracle.md) for the
record-or-compare flow.
