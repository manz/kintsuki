"""SPC7110: the image past the first MB loads as the data ROM.

`asm/test_spc7110.s` declares cart type $F5 (SPC7110) on a 2 MB image and
reads the 4 marker bytes at data ROM offset $1234 through the data port
into $7E:2000, then through the $D0 window into $7E:2004, then STPs.
"""

from __future__ import annotations

import pytest

from kintsuki import Emu

MARKER = bytes([0xD5, 0x7A, 0x11, 0xC0])
PORT_COPY = 0x7E2000
WINDOW_COPY = 0x7E2004


def _run_until_stp(emu: Emu, max_frames: int = 30) -> bool:
    for _ in range(max_frames):
        emu.run_frames(1)
        if emu.get_state().stp:
            return True
    return False


@pytest.fixture
def spc7110_emu(assemble_rom):
    rom = assemble_rom("test_spc7110.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        yield emu


def test_spc7110_boots_from_program_rom(spc7110_emu):
    assert _run_until_stp(spc7110_emu)


def test_spc7110_data_port_reads_data_rom(spc7110_emu):
    assert _run_until_stp(spc7110_emu)
    assert bytes(spc7110_emu.read_range(PORT_COPY, 4)) == MARKER


def test_spc7110_d0_window_reads_data_rom(spc7110_emu):
    assert _run_until_stp(spc7110_emu)
    assert bytes(spc7110_emu.read_range(WINDOW_COPY, 4)) == MARKER
