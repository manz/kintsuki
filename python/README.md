# kintsuki

SNES emulator core for Lua-driven testing and DAP debug adapters,
built on bsnes via a thin C ABI.

```python
import kintsuki

emu = kintsuki.Emu()
emu.load_rom("game.sfc")
emu.run_frames(60)
print(f"$7E1700 = {emu.read(0x7E1700):#04x}")
emu.screenshot("frame.png")
```

## Build

This package ships `libkintsuki.dylib` (macOS) / `.so` (Linux) /
`.dll` (Windows) in `src/kintsuki/_lib/`. Rebuild from source:

```sh
make -C ../bsnes/bsnes target=kintsuki binary=library
cp ../bsnes/bsnes/out/libkintsuki.dylib src/kintsuki/_lib/
pip install -e .
```

## License

GPL-3.0-or-later (matches bsnes).
