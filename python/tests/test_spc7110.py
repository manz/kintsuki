"""SPC7110: the image past the first MB loads as the data ROM.

`asm/test_spc7110.s` declares cart type $F5 (SPC7110) on a 2 MB image and
reads the 4 marker bytes at data ROM offset $1234 through the data port
into $7E:2000, then through the $D0 window into $7E:2004, then STPs.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from kintsuki import Emu

MARKER = bytes([0xD5, 0x7A, 0x11, 0xC0])
SRAM_SIZE = 8 * 1024
PORT_COPY = 0x7E2000
WINDOW_COPY = 0x7E2004
CART_TYPE_OFFSET = 0xFFD6


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


# The save RAM lives in the SPC7110, not cartridge.ram.

def test_spc7110_read_sram_sees_the_mcu_ram(spc7110_emu):
    assert len(spc7110_emu.read_sram()) == SRAM_SIZE


def test_spc7110_inject_sram_reaches_the_mcu_ram(spc7110_emu):
    save = bytes(range(256)) * (SRAM_SIZE // 256)
    spc7110_emu.inject_sram(save)
    assert spc7110_emu.read_sram() == save


def test_spc7110_sav_sidecar_seeds_the_mcu_ram(assemble_rom, tmp_path: Path):
    rom = tmp_path / "spc7110.sfc"
    shutil.copy(assemble_rom("test_spc7110.s"), rom)
    (tmp_path / "spc7110.sav").write_bytes(b"\x5A" * SRAM_SIZE)
    with Emu(load_srm_sidecar=True) as emu:
        emu.load_rom(str(rom))
        assert emu.read_sram() == b"\x5A" * SRAM_SIZE


def test_swapping_carts_with_and_without_rtc_keeps_running(assemble_rom, tmp_path):
    """Every load powers the system twice (power, then reset), and each
    Thread::create queued an entry point that only the first entry consumed.
    The leftover named a coroutine handle libco later reused for another
    chip, so a fresh EpsonRTC or SPC7110 thread ran the wrong main and the
    CPU spun forever waiting for its clock. Runs in a child process: a
    regression hangs instead of failing."""
    image = bytearray(assemble_rom("test_spc7110.s").read_bytes())
    roms = []
    for cart_type in (0xF5, 0xF9):  # SPC7110, SPC7110 + Epson RTC
        image[CART_TYPE_OFFSET] = cart_type
        path = tmp_path / f"spc7110-{cart_type:x}.sfc"
        path.write_bytes(image)
        roms.append(str(path))
    child = textwrap.dedent(
        f"""
        from kintsuki import Emu
        for _ in range(20):
            for rom in {roms!r}:
                with Emu(load_srm_sidecar=False) as emu:
                    emu.load_rom(rom)
                    emu.run_frames(3)
        """
    )
    subprocess.run([sys.executable, "-c", child], check=True, timeout=60)
