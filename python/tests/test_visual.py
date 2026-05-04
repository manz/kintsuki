"""Phase 4e — pixel-diff oracle for framebuffer assertions.

`assert_pixel_match(emu, golden_path)` decodes the golden PNG, snapshots
the emulator's framebuffer, and runs maparazzo's numba-jitted port of
mapbox/pixelmatch over the two RGBA buffers. On mismatch it writes the
actual frame as `<golden>.actual.png` plus a diff heatmap as
`<golden>.diff.png` next to the golden, then fails with the diff-pixel
count + paths.

`golden(emu, name)` is a record-or-compare helper: if the golden PNG
doesn't exist yet, the current frame is saved and the test is `skip`-ed
with a message asking the user to commit the golden. If it does exist,
behaves like `assert_pixel_match`.
"""

from __future__ import annotations

from pathlib import Path

from kintsuki.recorder import _encode_png_rgba
from kintsuki.visual import assert_pixel_match, golden, pixel_diff


class _FrameEmu:
    """Stub Emu returning a fixed RGBA framebuffer."""

    def __init__(self, rgba: bytes, w: int, h: int) -> None:
        self._rgba, self._w, self._h = rgba, w, h

    def framebuffer(self) -> tuple[bytes, int, int]:
        return self._rgba, self._w, self._h


def _solid(w: int, h: int, r: int, g: int, b: int) -> bytes:
    pixel = bytes([r, g, b, 0xFF])
    return pixel * (w * h)


def test_pixel_diff_identical_buffers_zero_mismatch():
    rgba = _solid(8, 4, 100, 200, 50)
    n, _diff_png = pixel_diff(rgba, rgba, 8, 4)
    assert n == 0


def test_pixel_diff_different_buffers_nonzero():
    a = _solid(8, 4, 0, 0, 0)
    b = _solid(8, 4, 255, 0, 0)
    n, _diff_png = pixel_diff(a, b, 8, 4)
    assert n > 0


def test_assert_pixel_match_passes_against_golden(tmp_path: Path):
    """When the framebuffer matches the golden PNG, no exception."""
    rgba = _solid(8, 4, 50, 100, 150)
    golden_path = tmp_path / "frame.png"
    golden_path.write_bytes(_encode_png_rgba(rgba, 8, 4))
    emu = _FrameEmu(rgba, 8, 4)
    # Should not raise.
    assert_pixel_match(emu, golden_path)


def test_assert_pixel_match_fails_and_dumps_artifacts(tmp_path: Path):
    """On mismatch, the helper writes <name>.actual.png + <name>.diff.png
    and fails with a count + paths in the message."""
    golden_rgba = _solid(8, 4, 0, 0, 0)
    actual_rgba = _solid(8, 4, 255, 0, 0)
    golden_path = tmp_path / "frame.png"
    golden_path.write_bytes(_encode_png_rgba(golden_rgba, 8, 4))
    emu = _FrameEmu(actual_rgba, 8, 4)
    try:
        assert_pixel_match(emu, golden_path, max_diff_pixels=0)
    except AssertionError as exc:
        msg = str(exc)
        assert "diff pixels" in msg
        assert (tmp_path / "frame.actual.png").exists()
        assert (tmp_path / "frame.diff.png").exists()
    else:
        raise AssertionError("expected AssertionError on visual mismatch")


def test_golden_records_when_missing(tmp_path: Path):
    """First run with a missing golden creates it and skips the test."""
    import pytest

    rgba = _solid(8, 4, 10, 20, 30)
    emu = _FrameEmu(rgba, 8, 4)
    name = tmp_path / "new_golden.png"
    with pytest.raises(pytest.skip.Exception, match="recorded golden"):
        golden(emu, name)
    assert name.exists()


def test_golden_compares_when_present(tmp_path: Path):
    rgba = _solid(8, 4, 33, 66, 99)
    name = tmp_path / "existing.png"
    name.write_bytes(_encode_png_rgba(rgba, 8, 4))
    emu = _FrameEmu(rgba, 8, 4)
    # Existing match: returns without skipping or raising.
    golden(emu, name)
