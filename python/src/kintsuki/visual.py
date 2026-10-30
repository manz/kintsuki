"""Pixel-diff oracle for framebuffer assertions.

Both record and compare go through ``Emu.screenshot()`` so the bytes a
golden PNG holds are bit-identical to what the C ABI would write at the
same emulator state. Earlier versions used ``Emu.framebuffer()`` and
fed the raw 0x00RRGGBB-packed bytes into PIL as RGBA, which silently
swapped red/blue and lost alpha — goldens recorded one way diffed
against goldens recorded the other way.

`assert_pixel_match(emu, golden_path)` writes the current frame to a
temp PNG via the C `writePNG` path and pixelmatches it against the
golden. On mismatch it persists the actual frame as
``<golden>.actual.png`` plus a diff heatmap as ``<golden>.diff.png``
next to the golden, then fails with the diff-pixel count + paths.

`golden(emu, name)` is a record-or-compare helper: if the golden PNG
doesn't exist yet, the current frame is saved (via the same screenshot
path) and the test is `skip`-ed with a message asking the user to
commit the golden. If it exists, behaves like `assert_pixel_match`.

The dependency on numba/numpy is dev-only (declared in the
``[visual]`` extras / dev group). Production kintsuki users don't pay
for it. PNG I/O is stdlib-only (zlib + a tiny decoder in
``kintsuki._png``, encoder shared with ``kintsuki.recorder``).
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Protocol

import numpy as np
from numpy.typing import NDArray
import pytest

from ._png import decode_rgba
from ._vendor.pixelmatch_numba import pixelmatch
from .recorder import _encode_png_rgba


class _EmuLike(Protocol):
    def screenshot(self, path: str) -> bool: ...


def _screenshot_to_rgba(emu: _EmuLike) -> NDArray[np.uint8]:
    """Snapshot the current frame via the C `writePNG` path into a temp
    file and decode it as RGBA. Funneling through screenshot() is what
    keeps record + compare bit-identical."""
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        if not emu.screenshot(tmp_path):
            raise AssertionError("emu.screenshot() failed")
        return decode_rgba(tmp_path)
    finally:
        try:
            Path(tmp_path).unlink()
        except FileNotFoundError:
            pass


def _save_rgba_png(arr: NDArray[np.uint8], path: Path) -> None:
    h, w, _ = arr.shape
    path.write_bytes(_encode_png_rgba(np.ascontiguousarray(arr).tobytes(), w, h))


def pixel_diff(a_rgba: bytes, b_rgba: bytes, w: int, h: int, *,
               threshold: float = 0.1) -> tuple[int, bytes]:
    """Compare two **canonical RGBA** byte buffers (R, G, B, A per
    pixel). Returns ``(mismatch_pixel_count, diff_png_bytes)``. Use
    :func:`pixel_diff_files` if your inputs are PNGs on disk — that
    path goes through the kintsuki PNG decoder and avoids the
    BGRA-confusion that bites callers who feed ``Emu.framebuffer()``
    bytes here."""
    a = np.frombuffer(a_rgba, dtype=np.uint8).reshape((h, w, 4))
    b = np.frombuffer(b_rgba, dtype=np.uint8).reshape((h, w, 4))
    n, diff = pixelmatch(a, b, threshold=threshold)
    return n, _encode_png_rgba(np.ascontiguousarray(diff).tobytes(), w, h)


def pixel_diff_files(a_path: str | Path, b_path: str | Path, *,
                     threshold: float = 0.1) -> tuple[int, bytes]:
    """File-level companion to :func:`pixel_diff`. Decodes both PNGs as
    RGBA, runs pixelmatch, returns the same tuple."""
    a = decode_rgba(a_path)
    b = decode_rgba(b_path)
    n, diff = pixelmatch(a, b, threshold=threshold)
    h, w, _ = diff.shape
    return n, _encode_png_rgba(np.ascontiguousarray(diff).tobytes(), w, h)


def assert_pixel_match(emu: _EmuLike, golden_path: str | Path, *,
                       threshold: float = 0.1,
                       max_diff_pixels: int = 0) -> None:
    """Compare the current emulator frame to the golden PNG; raise
    ``AssertionError`` if the count exceeds ``max_diff_pixels``. Dumps
    actual + diff PNGs next to the golden on failure."""
    golden_path = Path(golden_path)
    if not golden_path.exists():
        raise FileNotFoundError(f"golden PNG not found: {golden_path}")

    actual = _screenshot_to_rgba(emu)
    gold = decode_rgba(golden_path)
    if gold.shape != actual.shape:
        gh, gw, _ = gold.shape
        ah, aw, _ = actual.shape
        raise AssertionError(
            f"size mismatch: golden is ({gw}, {gh}), "
            f"actual frame is ({aw}, {ah})")

    n, diff = pixelmatch(gold, actual, threshold=threshold)
    if n > max_diff_pixels:
        actual_path = golden_path.with_suffix(".actual.png")
        diff_path = golden_path.with_suffix(".diff.png")
        _save_rgba_png(actual, actual_path)
        _save_rgba_png(diff, diff_path)
        raise AssertionError(
            f"{n} diff pixels (threshold={threshold}, "
            f"max_diff_pixels={max_diff_pixels}); "
            f"actual={actual_path} diff={diff_path}")


def golden(emu: _EmuLike, name: str | Path, *,
           threshold: float = 0.1,
           max_diff_pixels: int = 0) -> None:
    """Record-or-compare against a golden PNG. If `name` doesn't exist
    yet, the current frame is saved via ``Emu.screenshot()`` and the
    test is ``pytest.skip``-ed with a message asking the user to commit
    the golden. Otherwise behaves like :func:`assert_pixel_match`."""
    name = Path(name)
    if not name.exists():
        name.parent.mkdir(parents=True, exist_ok=True)
        if not emu.screenshot(str(name)):
            raise AssertionError(
                f"cannot record golden: emu.screenshot({name}) failed")
        pytest.skip(f"recorded golden at {name}; commit it and re-run the test")
    assert_pixel_match(emu, name,
                       threshold=threshold, max_diff_pixels=max_diff_pixels)
