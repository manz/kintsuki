# Python API

The `kintsuki` package is a thin wrapper over `libkintsuki`. Single-instance
for now (the underlying ares core uses globals); construct via
`Emu()` as a context manager so the native handle is destroyed
deterministically.

## Lifecycle

```python
from kintsuki import Emu

with Emu() as emu:
    emu.load_rom("ff4.sfc")           # boots the cart
    emu.run_frames(60)
    state = emu.get_state()           # CpuState snapshot
```

| Method                                  | Purpose                                                      |
|-----------------------------------------|--------------------------------------------------------------|
| `Emu(load_srm_sidecar=None)`            | Construct. `load_srm_sidecar=False` skips `<rom>.srm` read.  |
| `load_rom(path, *, adbg=None)`          | Load ROM. `adbg=` also loads a `.adbg` debug-info file.      |
| `reset()`                               | Soft reset. Cart SRAM survives.                              |
| `run_frames(n)` / `run_until(pc, max)`  | Advance the emulator.                                        |
| `step()`                                | One instruction.                                             |
| `frame_count`                           | Frames rendered so far.                                      |

## CPU + memory

| Method                                | Returns                                                       |
|---------------------------------------|---------------------------------------------------------------|
| `get_state()` / `set_state(cs)`       | `CpuState` (a/x/y/s/d/b/p/pc/e/stp/wai)                       |
| `read(addr)` / `write(addr, v)`       | One byte, 24-bit address                                      |
| `read_range(addr, n)`                 | `memoryview` (zero-copy over a ctypes buffer)                 |
| `write_range(addr, data)`             | Bulk write                                                    |
| `read16(addr)`                        | 16-bit little-endian read                                     |

## PPU state

```python
ppu = emu.get_ppu_state()           # PpuState dataclass
ppu.bgmode, ppu.bg1sc, ppu.tm, ...
ppu.bg_tilemap_word_base(layer=3)   # VRAM word base from BGxSC
```

VRAM/CGRAM/OAM all expose `*_read`, `*_read_range`, `*_write`,
`*_write_range`. Defaults dump the whole region: `emu.vram_read_range()`
returns 64 KB.

## .adbg integration

```python
emu.load_adbg("rom.sfc.adbg")
emu.lookup_label(0x008000)              # exact match, "reset" | None
emu.lookup_label_containing(0x008010)   # ("reset", 0x10) — range-aware
emu.lookup_symbol_addr("DrawHUD")       # name → 24-bit | None
emu.lookup_source(0x008000)             # ("test_ppu_state.s", 14, 1) | None
```

Use `lookup_label_containing` for runtime PCs (callsites rarely land on
a label boundary). `lookup_label` is exact-match and only useful for the
"is this address a labeled entry point?" question.

## Framebuffer + screenshots

```python
raw, w, h = emu.framebuffer()       # raw bytes (B G R 0 per pixel — see below)
emu.screenshot("frame.png")         # canonical RGB PNG (the recommended path)
```

`framebuffer()` returns raw bytes with each pixel as a little-endian
`uint32` packed `0x00RRGGBB`, so on disk they read as **B G R 0** per pixel,
not RGBA. The output is hires-aware: 564×N in BGMODE 5/6 / pseudo-hires,
half that (single column per pixel) in normal mode.

Use `Emu.screenshot()` for canonical PNG output and
`kintsuki.visual.golden()` for record-or-compare assertions; both share the
hires-aware C path so their pixels are bit-identical.

## Save states

```python
blob = emu.save_state()
# ... mutate ...
emu.load_state(blob)              # rearms libco internally
```

Mid-test `Emu.callstack_clear()` and the load_state path clear the shadow
callstack; the ares-side `r.stp` / `r.wai` flags don't survive the
serializer's round-trip cleanly without the rearm, so always go through
`load_state` (don't poke the C ABI directly unless you handle the rearm
yourself).

## Tracer

See [Tracer](tracer.md). One-liner:

```python
emu.tracer_start(lo=0x008000, hi=0x00FFFF, path="trace.log")
emu.run_frames(30)
emu.tracer_stop()
```

## Shadow callstack

See [Shadow callstack](shadow-callstack.md).

```python
for callsite, target, kind in emu.callstack():
    name, off = emu.lookup_label_containing(callsite) or ("?", 0)
    print(f"{callsite:06X} (+0x{off:X}) {['JSR','JSL'][kind]} → {target:06X} {name}")
```
