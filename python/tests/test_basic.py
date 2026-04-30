"""Smoke test: load FF4 ROM, run frames, exercise full surface."""

from __future__ import annotations

import os
import struct
from pathlib import Path

import pytest

import kintsuki
from kintsuki import Emu


ROM_PATH = os.environ.get(
    "KINTSUKI_TEST_ROM", str(Path.home() / "PyCharmProjects/ff4/build/ff4.sfc")
)


def _need_rom():
    if not Path(ROM_PATH).exists():
        pytest.skip(f"test ROM not present at {ROM_PATH}")


def test_load_run_read():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        emu.run_frames(60)
        assert emu.frame_count == 60
        # WRAM peek (FF4 boot leaves something here).
        b = emu.read(0x7E1700)
        assert 0 <= b <= 255


def test_savestate_roundtrip():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        emu.run_frames(120)
        before = emu.read(0x7E1700)
        blob = emu.save_state()
        assert len(blob) > 1000
        emu.run_frames(60)
        emu.load_state(blob)
        # After restore, byte should match snapshot.
        assert emu.read(0x7E1700) == before


def test_input_press():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        emu.press(0, kintsuki.Button.START)
        emu.run_frames(30)
        emu.release(0, kintsuki.Button.START)
        # Just verify no crash + frame counter advanced.
        assert emu.frame_count == 30


def test_cpu_state():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        emu.run_frames(60)
        s = emu.get_state()
        # PC must be inside ROM space after boot.
        assert s.pc >= 0x008000


def test_framebuffer_shape():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        emu.run_frames(60)
        rgba, w, h = emu.framebuffer()
        assert (w, h) == (256, 240)
        assert len(rgba) == w * h * 4


def test_write_callback():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        hits = []
        cb_id = emu.add_write_callback(0x4200, 0x4200, lambda a, v: hits.append((a, v)))
        emu.run_frames(60)
        emu.remove_callback(kintsuki.CallbackKind.WRITE, cb_id)
        # FF4 boot sets up NMITIMEN at $4200 a few times.
        assert len(hits) > 0
        for addr, _ in hits:
            assert addr == 0x4200


def test_read_range():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        emu.run_frames(60)
        blob = emu.read_range(0x7E0000, 256)
        assert len(blob) == 256
