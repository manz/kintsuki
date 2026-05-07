# Save states

`kintsuki_save_state` returns an opaque blob produced by ares' serializer
(register file + WRAM + SRAM + VRAM + CGRAM + OAM + APU RAM + scheduler
state). `kintsuki_load_state` consumes it.

```python
blob = emu.save_state()         # bytes
emu.load_state(blob)            # back to that point
```

## libco coroutine caveat

ares serializes `r.stp` / `r.wai` and the register file but not the
**libco coroutine RIP** the CPU was suspended on. After
`load_state`, calling `run_frames` would otherwise wake the coroutine
inside whatever wait loop it suspended in (commonly `instructionStop`
or `instructionWait`) — PC stays frozen even though registers restored
correctly.

The Python `Emu.load_state()` and Swift `Emulator.loadState()` paths
both call `kintsuki_rearm_cpu` after a successful load to rebuild the
libco coroutine cleanly. If you call `kintsuki_load_state` straight from
the C ABI, do the rearm yourself.

## Macro-level: macOS app

- **Save State** (⌘S) — capture into SwiftData with a 256×224 thumbnail.
- **Manage Save States…** (⌘⇧S) — grid browser.
- **Hot-Reload (Keep State)** (⌘⌥R) — captures into a per-ROM autosave
  slot, re-parses the cart, restores. Skips the SwiftData round-trip
  (the externalStorage flush could race with the read), so iterative
  patch development is safe.
- Autosave on `NSApplication.willTerminate` so the next launch / hot
  reload starts where you left off.

The autosave slot is stored under the reserved name `__autosave__` and
is hidden from the browser by predicate filter.

## Export / import

```python
# To file (raw blob, no header)
emu.save_state_to_file("checkpoint.kss")
emu.load_state_from_file("checkpoint.kss")
```

The macOS app exposes the same as **Export State to File…** /
**Import State from File…** under the State menu.
