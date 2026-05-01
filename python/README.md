# kintsuki

SNES emulator wheel built on a stripped-down [ares](https://ares-emu.net)
Super Famicom core via a thin C ABI. Aimed at scripted testing and
instruction tracing.

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
cmake -S ../ares -B ../build -G Ninja
ninja -C ../build kintsuki
cp ../build/target-kintsuki/libkintsuki.dylib src/kintsuki/_lib/
pip install -e .
```

## License

ISC. Vendors ares under its own ISC license — see `ares/LICENSE` in the
parent repo.
