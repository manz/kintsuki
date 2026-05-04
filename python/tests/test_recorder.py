"""Phase 4d — frame ring buffer + failure-dump fixture.

`FrameRecorder` snapshots the framebuffer once per logical step, stored
in a bounded ring (last N frames). On test failure, an autouse pytest
fixture dumps every retained frame as a PNG into
`/tmp/kintsuki_<test_name>/frame_NNN.png` so Claude can scrub them
without re-running the test.

Snapshots are stored as the raw `(rgba, w, h)` tuple `Emu.framebuffer()`
returns; PNG encoding only happens at dump time so capture stays cheap.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from kintsuki.recorder import FrameRecorder, FrameSnapshot


# Synthetic 8x4 RGBA frames so tests don't need a ROM.
def _frame(w: int, h: int, fill: int) -> bytes:
    """Solid-colour RGBA buffer (4 bytes per pixel, A=255)."""
    pixel = bytes([fill, fill, fill, 0xFF])
    return pixel * (w * h)


class _FakeEmu:
    """Stub Emu exposing the minimum surface FrameRecorder.capture() needs."""

    def __init__(self, w: int = 8, h: int = 4) -> None:
        self.w = w
        self.h = h
        self.tick = 0

    def framebuffer(self) -> tuple[bytes, int, int]:
        # Vary the fill so each captured frame is distinguishable.
        fill = (self.tick * 17) & 0xFF
        return (_frame(self.w, self.h, fill), self.w, self.h)


def test_recorder_captures_one_snapshot_per_call():
    rec = FrameRecorder(capacity=10)
    emu = _FakeEmu()
    for i in range(3):
        emu.tick = i
        rec.capture(emu)
    snaps = rec.snapshots()
    assert len(snaps) == 3
    assert all(isinstance(s, FrameSnapshot) for s in snaps)
    # Each snapshot has the right shape.
    assert snaps[0].width == 8
    assert snaps[0].height == 4
    assert len(snaps[0].rgba) == 8 * 4 * 4


def test_recorder_evicts_oldest_at_capacity():
    rec = FrameRecorder(capacity=3)
    emu = _FakeEmu()
    for i in range(5):
        emu.tick = i
        rec.capture(emu)
    snaps = rec.snapshots()
    # Capacity bounded; only last 3 retained.
    assert len(snaps) == 3
    # Oldest retained is tick=2, newest is tick=4.
    assert snaps[0].rgba[0] == (2 * 17) & 0xFF
    assert snaps[-1].rgba[0] == (4 * 17) & 0xFF


def test_recorder_dump_pngs(tmp_path: Path):
    rec = FrameRecorder(capacity=5)
    emu = _FakeEmu()
    for i in range(3):
        emu.tick = i
        rec.capture(emu)

    out_dir = tmp_path / "dump"
    paths = rec.dump_pngs(out_dir)
    assert len(paths) == 3
    for p in paths:
        assert p.exists()
        assert p.suffix == ".png"
        # PNG signature: 89 50 4E 47 0D 0A 1A 0A
        assert p.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
    # Filenames are zero-padded so directory listings sort frame-order.
    names = [p.name for p in paths]
    assert names == sorted(names)


def test_recorder_clear_resets_ring():
    rec = FrameRecorder(capacity=4)
    emu = _FakeEmu()
    rec.capture(emu)
    rec.capture(emu)
    rec.clear()
    assert rec.snapshots() == []


def test_recorder_capacity_must_be_positive():
    with pytest.raises(ValueError):
        FrameRecorder(capacity=0)
    with pytest.raises(ValueError):
        FrameRecorder(capacity=-1)


def test_recorder_skips_empty_framebuffer():
    """Mesen returns (b'', 0, 0) before the first frame is rendered.
    capture() should silently no-op on that — calling capture pre-boot
    shouldn't pollute the ring with a degenerate frame."""

    class _PreBootEmu:
        def framebuffer(self):
            return (b"", 0, 0)

    rec = FrameRecorder(capacity=4)
    rec.capture(_PreBootEmu())
    assert rec.snapshots() == []
