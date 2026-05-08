# kintsuki

A debugger-grade SNES / Super Famicom emulator core, packaged for ROM-hacking
workflows that want more than a window with pixels in it.

Under the hood is a stripped-down [ares](https://ares-emulator.github.io/)
performance PPU + WDC65816 CPU. On top of that:

- A tiny C ABI (`libkintsuki.dylib` / `.so`) that exposes the live framebuffer,
  CPU + PPU state, save-state round-trips, and a formatted instruction tracer.
- A Python wrapper (`pip install kintsuki`) for test harnesses, golden-image
  pipelines, and automation.
- A Swift macOS app (Kintsuki.app) with a hardware-accelerated Metal renderer,
  a 60-second rewind ring, hot-reload-with-state, and a crash overlay that
  symbolicates the call stack against your assembler's `.adbg` debug info.

## Quick taste

```python
from kintsuki import Emu

with Emu() as emu:
    emu.load_rom("ff4.sfc")
    emu.load_adbg("ff4.sfc.adbg")            # symbol + line resolution
    emu.run_frames(60)
    emu.screenshot("after-1s.png")           # canonical PNG
    print(emu.lookup_label_containing(emu.get_state().pc))
```

## What's in the box

- **[Python API](python-api.md)** — `Emu` class, framebuffer / state / SRAM access,
  `.adbg` integration.
- **[Tracer](tracer.md)** — Mesen-style per-instruction log with native label
  injection and JSR/JSL/JMP target symbolication.
- **[Shadow callstack](shadow-callstack.md)** — JSR/JSL hooks + crash backtraces
  resolved against `.adbg`.
- **[Rewind buffer](rewind.md)** — preallocated keyframe pool + LZ4 deltas.
  Memory bounded; push/evict O(1) at the ring level.
- **[Visual oracle](visual-oracle.md)** — pixel-diff goldens via `pixelmatch`,
  shared pixel pipeline with `Emu.screenshot()` so record/compare can't
  desync.
- **[macOS app](macos-app.md)** — Metal renderer, save-state browser, hot-reload,
  rewind, crash overlay, ⌘⌥R hot-reload-with-state.
- **[C ABI reference](c-abi.md)** — every entry point in `libkintsuki.h`.

## Status

Pre-1.0; alpha tags are cut from `master` (`v0.0.0aN`). Public API can still
move between alphas — pin a version when integrating.
