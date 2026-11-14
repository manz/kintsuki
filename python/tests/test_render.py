"""Emu.render: with it off the PPU skips drawing, nothing else.

`asm/test_render.s` puts 40 sprites on one line (range over in $213E), copies $213E to WRAM each NMI and steps the
backdrop colour, so every frame's picture differs. The FF4 checks run a battle from a savestate when one is on disk.
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from pathlib import Path

import pytest

from kintsuki import Emu

FLAGS = 0x7E0010
RANGE_OVER = 0x40
WRAM = 0x7E0000
WRAM_BYTES = 0x20000
FRAMES = 30
BUTTON_A = 1 << 5

_FF4_DIR = Path.home() / "PyCharmProjects/betaplayer/local/ff4-2386211"
FF4_ROM = Path(os.environ.get("KINTSUKI_FF4_ROM", _FF4_DIR / "ff4.sfc"))
FF4_FIGHT = Path(os.environ.get(
    "KINTSUKI_FF4_FIGHT_STATE", _FF4_DIR / "fights/20261113-213338-F0dc-lost.state"))
FF4_FRAMES = 240


def _run(emu: Emu, frames: int, *, render: bool) -> None:
    """Advance `frames` frames, tapping A two frames in every eight so a battle moves along."""
    emu.render = render
    for _ in range(frames):
        emu.set_input(0, BUTTON_A if emu.frame_count % 8 < 2 else 0)
        emu.run_frames(1)


def _wram(emu: Emu) -> bytes:
    return bytes(emu.read_range(WRAM, WRAM_BYTES))


def _load(emu: Emu, rom: Path) -> None:
    """Load `rom` with WRAM zeroed: ares fills it with noise at power-on, which differs run to run."""
    emu.load_rom(str(rom))
    emu.write_range(WRAM, bytes(WRAM_BYTES))


@pytest.fixture
def rom(assemble_rom) -> Path:
    return assemble_rom("test_render.s")


@pytest.fixture
def emu(rom: Path) -> Iterator[Emu]:
    with Emu() as emu:
        _load(emu, rom)
        yield emu


def _test_rom_run(rom: Path, *, render: bool) -> tuple[bytes, bytes]:
    """WRAM and the last frame after FRAMES frames, all with `render` but the last, which draws."""
    with Emu() as emu:
        _load(emu, rom)
        _run(emu, FRAMES - 1, render=render)
        _run(emu, 1, render=True)
        return _wram(emu), emu.framebuffer()[0]


def test_render_is_on_by_default() -> None:
    with Emu() as emu:
        assert emu.render is True


def test_render_off_leaves_the_last_frame(emu: Emu) -> None:
    _run(emu, 2, render=True)
    drawn = emu.framebuffer()[0]
    _run(emu, 2, render=False)
    assert (emu.render, emu.framebuffer()[0]) == (False, drawn)


def test_frames_still_count_with_render_off(emu: Emu) -> None:
    _run(emu, FRAMES, render=False)
    assert emu.frame_count == FRAMES


def test_range_over_still_latches_with_render_off(emu: Emu) -> None:
    _run(emu, FRAMES, render=False)
    assert emu.read(FLAGS) & RANGE_OVER


def test_test_rom_wram_matches_with_render_off(rom: Path) -> None:
    assert _test_rom_run(rom, render=False)[0] == _test_rom_run(rom, render=True)[0]


def test_test_rom_frame_after_render_off_matches(rom: Path) -> None:
    assert _test_rom_run(rom, render=False)[1] == _test_rom_run(rom, render=True)[1]


def _ff4_run(*, render: bool) -> tuple[bytes, bytes]:
    if not FF4_ROM.exists() or not FF4_FIGHT.exists():
        pytest.skip(f"FF4 ROM / fight state not present ({FF4_ROM}, {FF4_FIGHT})")
    with Emu() as emu:
        emu.load_rom(str(FF4_ROM))
        emu.load_state(FF4_FIGHT.read_bytes())
        _run(emu, FF4_FRAMES - 1, render=render)
        _run(emu, 1, render=True)
        return _wram(emu), emu.framebuffer()[0]


def test_ff4_battle_wram_matches_with_render_off() -> None:
    assert _ff4_run(render=False)[0] == _ff4_run(render=True)[0]


def test_ff4_battle_frame_after_render_off_matches() -> None:
    assert _ff4_run(render=False)[1] == _ff4_run(render=True)[1]
