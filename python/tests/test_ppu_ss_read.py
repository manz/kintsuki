"""ppu_ss_read answers like the MiSTer core's savestate port ($C1:21xx,
PPU.vhd SS_DO): a write-only register written by the CPU reads back as the
value a savestate handler can replay."""

from __future__ import annotations

import pytest

from kintsuki import Emu

# (register, value written, value read back): unused bits read as 0.
SINGLE = [
    (0x00, 0x8F, 0x8F),
    (0x01, 0xA5, 0xA5),
    (0x05, 0xF3, 0xF3),
    (0x06, 0x5A, 0x5A),
    (0x07, 0xAD, 0xAD),
    (0x0A, 0x52, 0x52),
    (0x0B, 0x3C, 0x3C),
    (0x0C, 0xC3, 0xC3),
    (0x15, 0x8F, 0x8E),  # increment 3 is 128 words, read back as 2
    (0x1A, 0xFF, 0xC3),
    (0x23, 0x96, 0x96),
    (0x25, 0x69, 0x69),
    (0x26, 0x11, 0x11),
    (0x29, 0xEE, 0xEE),
    (0x2A, 0xB4, 0xB4),
    (0x2B, 0xFF, 0x0F),
    (0x2C, 0xFF, 0x1F),
    (0x2F, 0x15, 0x15),
    (0x30, 0xFF, 0xF3),
    (0x31, 0xBF, 0xBF),
    (0x33, 0xFF, 0x4F),
]

# (register, low byte, high byte, high-byte mask)
DOUBLE = [
    (0x0F, 0x34, 0x03, 0x03),
    (0x14, 0xCD, 0x02, 0x03),
    (0x1B, 0x78, 0x56, 0xFF),
    (0x1E, 0x9A, 0xBC, 0xFF),
    (0x1F, 0x21, 0x13, 0x1F),
    (0x20, 0x43, 0x0F, 0x1F),
]


@pytest.fixture
def emu(assemble_rom) -> Emu:
    with Emu(load_srm_sidecar=False) as e:
        e.load_rom(str(assemble_rom("test_rom.s")))
        e.run_frames(2)
        yield e


def _write_regs(emu: Emu, writes: list[tuple[int, int]]) -> None:
    code = bytearray([0xE2, 0x20])  # sep #$20
    for reg, value in writes:
        code += bytes([0xA9, value, 0x8F, reg, 0x21, 0x00])  # lda #v ; sta.l $0021rr
    emu.run_asm(bytes(code))


@pytest.mark.parametrize(("reg", "value", "expected"), SINGLE)
def test_single_write_register_reads_back(emu: Emu, reg: int, value: int, expected: int) -> None:
    _write_regs(emu, [(reg, value)])
    assert emu.ppu_ss_read(reg) == expected


@pytest.mark.parametrize(("reg", "lo", "hi", "mask"), DOUBLE)
def test_two_write_register_reads_back_both_halves(
    emu: Emu, reg: int, lo: int, hi: int, mask: int
) -> None:
    _write_regs(emu, [(reg, lo), (reg, hi)])
    assert (emu.ppu_ss_read(reg), emu.ppu_ss_read(reg + 0x40)) == (lo, hi & mask)


def test_bg1_scroll_reads_mode7_offset_in_mode7(emu: Emu) -> None:
    _write_regs(emu, [(0x05, 0x07), (0x0D, 0x89), (0x0D, 0x17)])
    assert (emu.ppu_ss_read(0x0D), emu.ppu_ss_read(0x4D)) == (0x89, 0x17)


def test_bg1_scroll_reads_bg_offset_outside_mode7(emu: Emu) -> None:
    _write_regs(emu, [(0x05, 0x01), (0x0D, 0x89), (0x0D, 0x17)])
    assert (emu.ppu_ss_read(0x0D), emu.ppu_ss_read(0x4D)) == (0x89, 0x03)


def test_oam_address_and_priority(emu: Emu) -> None:
    _write_regs(emu, [(0x02, 0x5A), (0x03, 0x81)])
    assert (emu.ppu_ss_read(0x02), emu.ppu_ss_read(0x03)) == (0x5A, 0x81)


def test_vram_address(emu: Emu) -> None:
    _write_regs(emu, [(0x16, 0x34), (0x17, 0x12)])
    assert (emu.ppu_ss_read(0x16), emu.ppu_ss_read(0x17)) == (0x34, 0x12)


def test_coldata_channels(emu: Emu) -> None:
    _write_regs(emu, [(0x32, 0x80 | 0x11), (0x32, 0x40 | 0x0A), (0x32, 0x20 | 0x1F)])
    got = (emu.ppu_ss_read(0x32), emu.ppu_ss_read(0x40), emu.ppu_ss_read(0x41))
    assert got == (0x91, 0x4A, 0x3F)


def test_cgram_address_and_pending_byte(emu: Emu) -> None:
    _write_regs(emu, [(0x21, 0x42), (0x22, 0xE7)])
    got = (emu.ppu_ss_read(0x21), emu.ppu_ss_read(0x22), emu.ppu_ss_read(0x61))
    assert got == (0x42, 0xE7, 0x01)


def test_dsp_write_register(emu: Emu) -> None:
    emu.dsp_write_register(0x0C, 0x5F)  # MVOLL
    assert emu.dsp_registers()[0x0C] == 0x5F
