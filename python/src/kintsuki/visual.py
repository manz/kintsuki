"""Pixel-diff oracle for framebuffer assertions.

`assert_pixel_match(emu, golden_path)` decodes a golden PNG, snapshots
the emulator's framebuffer, and runs a numba-jitted port of
mapbox/pixelmatch over the two RGBA buffers. On mismatch it writes the
actual frame as ``<golden>.actual.png`` plus a diff heatmap as
``<golden>.diff.png`` next to the golden, then fails with the diff-pixel
count + paths.

`golden(emu, name)` is a record-or-compare helper: if the golden PNG
doesn't exist yet, the current frame is saved and the test is `skip`-ed
with a message asking the user to commit the golden. If it exists,
behaves like `assert_pixel_match`.

`pixel_diff(a, b, w, h)` is the lower-level pure function — useful when
the caller already has both buffers in memory.

The dependency on numpy/Pillow/numba is dev-only (declared in
[dependency-groups] dev). Production kintsuki users don't pay for it.
"""

from __future__ import annotations

from io import BytesIO
from pathlib import Path
from typing import Protocol

import numpy as np
import pytest
from PIL import Image

from ._vendor.pixelmatch_numba import pixelmatch


class _EmuLike(Protocol):
    def framebuffer(self) -> tuple[bytes, int, int]: ...


def _rgba_to_pil(rgba: bytes, w: int, h: int) -> Image.Image:
    arr = np.frombuffer(rgba, dtype=np.uint8).reshape((h, w, 4))
    return Image.fromarray(arr, "RGBA")


def pixel_diff(a_rgba: bytes, b_rgba: bytes, w: int, h: int, *,
               threshold: float = 0.1) -> tuple[int, bytes]:
    """Compare two RGBA buffers; returns (mismatch_pixel_count, diff_png)."""
    a = _rgba_to_pil(a_rgba, w, h)
    b = _rgba_to_pil(b_rgba, w, h)
    n, diff = pixelmatch(a, b, threshold=threshold)
    buf = BytesIO()
    diff.save(buf, format="PNG")
    return n, buf.getvalue()


def assert_pixel_match(emu: _EmuLike, golden_path: str | Path, *,
                       threshold: float = 0.1,
                       max_diff_pixels: int = 0) -> None:
    """Compare current framebuffer to the golden PNG; AssertionError if
    the count exceeds ``max_diff_pixels``. Dumps actual + diff PNGs next
    to the golden on failure."""
    golden_path = Path(golden_path)
    if not golden_path.exists():
        raise FileNotFoundError(f"golden PNG not found: {golden_path}")

    rgba, w, h = emu.framebuffer()
    if not rgba or w == 0 or h == 0:
        raise AssertionError("framebuffer is empty (no frame rendered yet)")

    golden_img = Image.open(golden_path).convert("RGBA")
    if golden_img.size != (w, h):
        raise AssertionError(
            f"size mismatch: golden is {golden_img.size}, "
            f"actual framebuffer is ({w}, {h})")

    actual_img = _rgba_to_pil(rgba, w, h)
    n, diff = pixelmatch(golden_img, actual_img, threshold=threshold)
    if n > max_diff_pixels:
        actual_path = golden_path.with_suffix(".actual.png")
        diff_path   = golden_path.with_suffix(".diff.png")
        actual_img.save(actual_path, format="PNG")
        diff.save(diff_path, format="PNG")
        raise AssertionError(
            f"{n} diff pixels (threshold={threshold}, "
            f"max_diff_pixels={max_diff_pixels}); "
            f"actual={actual_path} diff={diff_path}")


def golden(emu: _EmuLike, name: str | Path, *,
           threshold: float = 0.1,
           max_diff_pixels: int = 0) -> None:
    """Record-or-compare against a golden PNG. If `name` doesn't exist,
    the current frame is saved and the test is `pytest.skip`-ed with a
    message asking the user to commit the golden."""
    name = Path(name)
    if not name.exists():
        rgba, w, h = emu.framebuffer()
        if not rgba or w == 0 or h == 0:
            raise AssertionError(
                "cannot record golden: framebuffer empty")
        actual_img = _rgba_to_pil(rgba, w, h)
        name.parent.mkdir(parents=True, exist_ok=True)
        actual_img.save(name, format="PNG")
        pytest.skip(f"recorded golden at {name}; commit it and re-run the test")
    assert_pixel_match(emu, name,
                       threshold=threshold, max_diff_pixels=max_diff_pixels)
