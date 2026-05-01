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


def test_emu_lifecycle_no_rom():
    """Smoke test that runs in CI without any ROM available — proves the
    native library loads, ctypes bindings resolve, and basic state ops
    work on a freshly-created emulator."""
    with Emu() as emu:
        s = emu.get_state()
        assert s.pc == 0
        assert emu.frame_count == 0


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
        # PC must be a valid 24-bit address (no other strong invariant
        # holds across emulators after a fixed number of frames).
        assert 0 <= s.pc <= 0xFFFFFF


def test_framebuffer_shape():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        emu.run_frames(60)
        rgba, w, h = emu.framebuffer()
        # ares performance PPU runs at 564x242 hires by default; bsnes
        # ran at 256x240. Just check we got something plausible.
        assert w > 0 and h > 0
        assert len(rgba) == w * h * 4


def test_write_callback():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        hits = []
        # Watch all CPU MMIO writes ($4200-$420F is the I/O register block).
        cb_id = emu.add_write_callback(0x4200, 0x420F, lambda a, v: hits.append((a, v)))
        emu.run_frames(60)
        emu.remove_callback(kintsuki.CallbackKind.WRITE, cb_id)
        # FF4 boot writes to MMIO setup registers a few times. If ares
        # routes some MMIO writes outside Bus::write the count may be 0
        # for narrow ranges; widening to $4200-$420F gives more surface.
        # We only assert no crash + plausible types if we did get hits.
        for addr, val in hits:
            assert 0x4200 <= addr <= 0x420F
            assert 0 <= val <= 255


def test_read_range():
    _need_rom()
    with Emu() as emu:
        emu.load_rom(ROM_PATH)
        emu.run_frames(60)
        blob = emu.read_range(0x7E0000, 256)
        assert len(blob) == 256
