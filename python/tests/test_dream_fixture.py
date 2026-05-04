"""Phase 4g — autouse pytest fixture wiring FrameRecorder + state dump.

The `kintsuki.testing.dream_fixture` module exposes a pair of helpers
that together provide the "test fails → dump everything I need" loop:

  - `frame_recorder` fixture: yields a FrameRecorder bound to the
    current test. Tests use it directly (record per frame, drain, etc.).
  - `dump_on_failure(emu, recorder, *, out_dir)`: dumps the last N
    captured frames as PNGs + a state snapshot JSON when called from
    a failing test. Intended to be called from the user's own test
    fixture / hook (no autouse magic the user can't see).

This module is opt-in: tests that don't use the fixtures get nothing.
That's deliberate — autouse hooks are surprising; explicit > implicit.
"""

from __future__ import annotations

import json
from pathlib import Path

from kintsuki.recorder import FrameRecorder
from kintsuki.testing.dream import (
    dump_on_failure,
    snapshot_to_json,
)


class _FakeEmu:
    """Minimal stub: framebuffer + register snapshot stubs."""

    def __init__(self) -> None:
        self.tick = 0

    def framebuffer(self) -> tuple[bytes, int, int]:
        rgba = bytes([self.tick & 0xFF, 0, 0, 0xFF]) * (8 * 4)
        return (rgba, 8, 4)

    def get_state(self):
        class _Cpu:
            a = 0x1234
            pc = 0x008000
        return _Cpu()

    def get_ppu_state(self):
        class _Ppu:
            bgmode = 1
            tm = 0x07
            bg3vofs = 0xFF88
            dma = ()
        return _Ppu()

    def read_range(self, addr: int, length: int) -> bytes:
        return b"\x00" * length

    def vram_read(self, addr: int) -> int:
        return 0

    def cgram_read(self, addr: int) -> int:
        return 0

    def oam_read(self, addr: int) -> int:
        return 0


def test_dump_on_failure_writes_pngs_and_state_json(tmp_path: Path):
    emu = _FakeEmu()
    rec = FrameRecorder(capacity=10)
    for i in range(4):
        emu.tick = i
        rec.capture(emu)

    out_dir = tmp_path / "dream_dump"
    paths = dump_on_failure(emu, rec, out_dir=out_dir)

    # All retained frames written.
    pngs = sorted(out_dir.glob("frame_*.png"))
    assert len(pngs) == 4, f"expected 4 PNGs, got {len(pngs)}"
    for p in pngs:
        assert p.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"

    # State snapshot JSON written and parses.
    state_json = out_dir / "state.json"
    assert state_json.exists()
    blob = json.loads(state_json.read_text())
    # Must include the headline registers.
    assert "cpu" in blob and blob["cpu"]["a"] == 0x1234
    assert "ppu" in blob and blob["ppu"]["bg3vofs"] == 0xFF88

    # Returned paths cover both PNGs and state.json.
    assert state_json in paths
    for p in pngs:
        assert p in paths


def test_snapshot_to_json_round_trip():
    """`snapshot_to_json` produces a JSON-serializable dict that excludes
    raw memory blobs (those would inflate the file). Memory included as
    sha-1 fingerprints + sizes for diffing."""
    from kintsuki.diff import snapshot

    emu = _FakeEmu()
    blob = snapshot_to_json(snapshot(emu))
    text = json.dumps(blob)         # must round-trip via stdlib json
    parsed = json.loads(text)
    assert parsed["cpu"]["a"] == 0x1234
    assert "vram_sha1" in parsed
    assert "vram_size" in parsed
    # Raw bytes excluded — the JSON shouldn't be dominated by memory dumps.
    assert "vram" not in parsed or not isinstance(parsed["vram"], str) \
        or len(parsed["vram"]) < 200


def test_dump_on_failure_uses_recorder_capacity(tmp_path: Path):
    """If recorder has fewer frames than capacity, dump only what's there."""
    emu = _FakeEmu()
    rec = FrameRecorder(capacity=60)
    rec.capture(emu)
    paths = dump_on_failure(emu, rec, out_dir=tmp_path / "small")
    pngs = [p for p in paths if p.suffix == ".png"]
    assert len(pngs) == 1
