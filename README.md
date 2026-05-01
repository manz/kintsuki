# kintsuki

SNES emulator harness built on a stripped-down [ares](https://ares-emu.net)
Super Famicom core. Provides:

- a C ABI shared library (`libkintsuki`) for embedding in tools,
- a Python wheel for scripting tests and instruction tracing,
- a macOS app for interactive debugging.

Adds primitives on top of ares aimed at automation: mid-frame yield via
`run_until_pc` + bail flag, `clearPendingInterrupts` so external `set_state`
PC overrides survive scheduler entry, exec / read / write callbacks, CPU
coroutine rearm to recover cleanly between back-to-back STP-halted stubs.

## Layout

- `ares/` — vendored ares SNES-only core (ISC, see `ares/LICENSE`)
- `target-kintsuki/` — C ABI shim wrapping the ares core
- `python/` — Python wheel wrapping `libkintsuki`
- `app/` — macOS Xcode project

## Build

CMake entry point lives in `ares/`:

```
cmake -S ares -B build -G Ninja
ninja -C build kintsuki
```

Drops `libkintsuki.dylib` into `build/target-kintsuki/`. Copy it into
`python/src/kintsuki/_lib/` to use the Python wheel against the freshly
built core, or `app/Vendor/` for the macOS app.

## License

ISC. Vendors ares under its own ISC license — see `ares/LICENSE`.
