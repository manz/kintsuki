# Pixel-diff goldens

Snapshot a known-good frame, commit the PNG, and have CI fail when the
pixels drift. Useful for "does the title screen still render the same
after my refactor of the BG3 tilemap routine".

## Install the visual extra

```bash
pip install 'kintsuki[visual]'
```

Pulls in `numpy`, `numba`, `Pillow`. The base wheel doesn't ship them
so production users aren't paying for a JIT they don't use.

## Record + compare

```python
import pytest
from kintsuki import Emu
from kintsuki.visual import golden

def test_title_screen_pixels(tmp_path):
    with Emu() as emu:
        emu.load_rom("build/ff4.sfc")
        emu.run_frames(180)             # boot through to the title screen
        # First run: writes the PNG, pytest.skip's the test with
        # "commit it and re-run". Subsequent runs: assert match.
        golden(emu, "tests/goldens/title_screen.png")
```

`golden()` is record-or-compare: missing → record + skip; present →
compare and `AssertionError` on diff. Keep your goldens in tree.

On mismatch:

```
AssertionError: 4217 diff pixels (threshold=0.1, max_diff_pixels=0);
actual=tests/goldens/title_screen.actual.png
diff=tests/goldens/title_screen.diff.png
```

The actual frame and a heatmap diff land next to the golden so failures
in CI artifacts are inspectable.

## Knobs

```python
golden(emu, path,
       threshold=0.1,         # YIQ ΔE — same default as mapbox/pixelmatch
       max_diff_pixels=0)     # 0 = strict; bump for noisy filters
```

`threshold` is per-pixel sensitivity (0.0 = identical R/G/B, 1.0 =
ignore everything). `max_diff_pixels` lets you tolerate a small
absolute count (e.g. 100 px noise on a 282×242 frame).

## Why both ends share `Emu.screenshot()`

Earlier alphas used `Emu.framebuffer()` raw bytes — which is
`0x00RRGGBB`-packed `uint32`, i.e. `B G R 0` per pixel on disk. PIL
silently swapped red/blue and saw `alpha=0`; goldens recorded one way
diffed against goldens recorded with `Emu.screenshot()` (which goes
through the C `writePNG` path that unpacks correctly).

Now both record and compare go through `screenshot()`. There's exactly
one pixel pipeline; goldens are bit-identical no matter who recorded
them.

## Hires geometry

`Emu.screenshot()` returns 282-wide PNGs in normal mode and 564-wide in
BGMODE 5/6 / pseudo-hires. If you're upgrading from a kintsuki version
that emitted the always-doubled 564 width, your goldens will be twice
as wide as the new output — re-record them.
