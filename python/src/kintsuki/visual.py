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

The dependency on Pillow/numba/numpy is dev-only (declared in the
``[visual]`` extras / dev group). Production kintsuki users don't pay
for it.
"""

from __future__ import annotations

import tempfile
from io import BytesIO
from pathlib import Path
from typing import Protocol

import numpy as np
import pytest
from PIL import Image

from ._vendor.pixelmatch_numba import pixelmatch


class _EmuLike(Protocol):
    def screenshot(self, path: str) -> bool: ...


def _open_rgba(path: str | Path) -> Image.Image:
    """Decode a PNG and force it into RGBA so pixelmatch sees uniform
    channel layout regardless of how the writer stored it (writePNG
    emits RGB; PIL adds alpha=255 on convert)."""
    return Image.open(path).convert("RGBA")


def _screenshot_to_image(emu: _EmuLike) -> Image.Image:
    """Snapshot the current frame via the C `writePNG` path into a temp
    file and decode it as RGBA. Funneling through screenshot() is what
    keeps record + compare bit-identical."""
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        if not emu.screenshot(tmp_path):
            raise AssertionError("emu.screenshot() failed")
        return _open_rgba(tmp_path).copy()  # detach from disk
    finally:
        try:
            Path(tmp_path).unlink()
        except FileNotFoundError:
            pass


def pixel_diff(a_rgba: bytes, b_rgba: bytes, w: int, h: int, *,
               threshold: float = 0.1) -> tuple[int, bytes]:
    """Compare two **canonical RGBA** byte buffers (R, G, B, A per
    pixel). Returns ``(mismatch_pixel_count, diff_png_bytes)``. Use
    :func:`pixel_diff_files` if your inputs are PNGs on disk — that
    path goes through Pillow's decoder and avoids the BGRA-confusion
    that bites callers who feed ``Emu.framebuffer()`` bytes here."""
    a = Image.fromarray(np.frombuffer(a_rgba, dtype=np.uint8).reshape((h, w, 4)),
                        "RGBA")
    b = Image.fromarray(np.frombuffer(b_rgba, dtype=np.uint8).reshape((h, w, 4)),
                        "RGBA")
    n, diff = pixelmatch(a, b, threshold=threshold)
    buf = BytesIO()
    diff.save(buf, format="PNG")
    return n, buf.getvalue()


def pixel_diff_files(a_path: str | Path, b_path: str | Path, *,
                     threshold: float = 0.1) -> tuple[int, bytes]:
    """File-level companion to :func:`pixel_diff`. Decodes both PNGs as
    RGBA, runs pixelmatch, returns the same tuple."""
    a = _open_rgba(a_path)
    b = _open_rgba(b_path)
    n, diff = pixelmatch(a, b, threshold=threshold)
    buf = BytesIO()
    diff.save(buf, format="PNG")
    return n, buf.getvalue()


def assert_pixel_match(emu: _EmuLike, golden_path: str | Path, *,
                       threshold: float = 0.1,
                       max_diff_pixels: int = 0) -> None:
    """Compare the current emulator frame to the golden PNG; raise
    ``AssertionError`` if the count exceeds ``max_diff_pixels``. Dumps
    actual + diff PNGs next to the golden on failure."""
    golden_path = Path(golden_path)
    if not golden_path.exists():
        raise FileNotFoundError(f"golden PNG not found: {golden_path}")

    actual_img = _screenshot_to_image(emu)
    golden_img = _open_rgba(golden_path)
    if golden_img.size != actual_img.size:
        raise AssertionError(
            f"size mismatch: golden is {golden_img.size}, "
            f"actual frame is {actual_img.size}")

    n, diff = pixelmatch(golden_img, actual_img, threshold=threshold)
    if n > max_diff_pixels:
        actual_path = golden_path.with_suffix(".actual.png")
        diff_path = golden_path.with_suffix(".diff.png")
        actual_img.save(actual_path, format="PNG")
        diff.save(diff_path, format="PNG")
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
