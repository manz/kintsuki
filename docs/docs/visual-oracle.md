# Visual oracle

Pixel-level golden assertions against the live framebuffer. Useful for
"this scene rendered exactly like this last time we knew it was right"
regression checks.

## API

```python
from kintsuki.visual import golden, assert_pixel_match, pixel_diff

# Record-or-compare. First run writes the PNG and pytest.skip's the
# test with "commit it and re-run". Subsequent runs compare.
golden(emu, "tests/goldens/title_screen.png")

# Compare-only (raises FileNotFoundError if missing).
assert_pixel_match(emu, "tests/goldens/title_screen.png",
                   threshold=0.1, max_diff_pixels=0)

# In-memory two-buffer comparison.
n, diff_png = pixel_diff(a_rgba, b_rgba, w, h, threshold=0.1)
```

On mismatch, `assert_pixel_match` writes `<golden>.actual.png` and
`<golden>.diff.png` next to the golden so failures land in CI artifacts
ready to inspect.

## Pipeline guarantee

Both record and compare go through `Emu.screenshot()` (the C-side
`writePNG` path). The bytes a golden PNG holds are bit-identical to
what the C ABI would write at the same emulator state — there's no
"raw framebuffer fed to PIL with the wrong channel order" trap.

Earlier alphas used `Emu.framebuffer()` bytes directly, which the C ABI
delivers as `0x00RRGGBB`-packed `uint32` (i.e. `B G R 0` on disk). PIL
silently swapped red/blue and saw `alpha=0`; goldens recorded one way
diffed against goldens recorded the other way. Fixed by routing both
through `screenshot()`.

## Hires-aware geometry

`Emu.screenshot()` returns 282×242 in normal mode (every other column
of ares' always-doubled output is just a duplicate) and 564×242 in
BGMODE 5/6 / pseudo-hires (each column carries distinct data). Goldens
recorded post-fix are half the size of older ones; if you're upgrading,
re-record.

## Dependencies

The `kintsuki[visual]` extra installs `numpy`, `numba`, and `Pillow`.
Production users of the base package don't pay for it.

```bash
pip install 'kintsuki[visual]'
```
