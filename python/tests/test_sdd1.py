"""S-DD1 trace: exercises S-DD1 board detection, the ares sdd1Hook ring
and the offline decompressor.

`asm/test_sdd1.s` declares cart type $43 (S-DD1), arms channel 0 for
decompression and streams 0x100 bytes from $C0:8000 into VRAM word
$1000, then 0x40 bytes of the same stream into WRAM $7E:2000, then STPs.
"""

from __future__ import annotations

import pytest

from kintsuki import Emu, _native

STREAM_SIZE = 0x100
VRAM_WORD = 0x1000
WRAM_SIZE = 0x40
WRAM_ADDR = 0x7E2000


def _run_until_stp(emu: Emu, max_frames: int = 30) -> bool:
    for _ in range(max_frames):
        emu.run_frames(1)
        if emu.get_state().stp:
            return True
    return False


@pytest.fixture
def sdd1_emu(assemble_rom):
    rom = assemble_rom("test_sdd1.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.sdd1_log_clear()
        yield emu


def test_sdd1_cart_detected(sdd1_emu):
    assert sdd1_emu.sdd1_present()


def test_sdd1_registers_default_banks(sdd1_emu):
    assert sdd1_emu.sdd1_registers()["banks"] == [0, 1, 2, 3]


def test_sdd1_vram_stream_logged(sdd1_emu):
    assert _run_until_stp(sdd1_emu)
    s = sdd1_emu.sdd1_streams()[1]
    assert (s["bus_addr"], s["rom_offset"], s["size"], s["dst_reg"], s["vram_addr"],
            s["captured"], s["complete"]) == (
        0xC08000, 0x8000, STREAM_SIZE, 0x18, VRAM_WORD, STREAM_SIZE, True)


def test_sdd1_wram_stream_logged(sdd1_emu):
    assert _run_until_stp(sdd1_emu)
    s = sdd1_emu.sdd1_streams()[0]
    assert (s["dst_reg"], s["wram_addr"], s["captured"], s["complete"]) == (
        0x80, WRAM_ADDR, WRAM_SIZE, True)


def test_sdd1_wram_stream_lands_in_wram(sdd1_emu):
    assert _run_until_stp(sdd1_emu)
    live = sdd1_emu.sdd1_streams(data=True)[0]["data"]
    assert bytes(sdd1_emu.read_range(WRAM_ADDR, WRAM_SIZE)) == live


def test_sdd1_stream_consumes_input(sdd1_emu):
    assert _run_until_stp(sdd1_emu)
    assert sdd1_emu.sdd1_streams()[1]["compressed_size"] > 0


def test_sdd1_decompress_matches_live_stream(sdd1_emu):
    assert _run_until_stp(sdd1_emu)
    live = sdd1_emu.sdd1_streams(data=True)[1]
    data, consumed = sdd1_emu.sdd1_decompress(0xC08000, STREAM_SIZE)
    assert (data, consumed) == (live["data"], live["compressed_size"])


def test_sdd1_stream_lands_in_vram(sdd1_emu):
    assert _run_until_stp(sdd1_emu)
    live = sdd1_emu.sdd1_streams(data=True)[1]["data"]
    vram = bytes(sdd1_emu.vram_read_range(VRAM_WORD * 2, STREAM_SIZE))
    assert vram == live


def test_sdd1_channel_disarmed_after_stream(sdd1_emu):
    assert _run_until_stp(sdd1_emu)
    assert sdd1_emu.sdd1_registers()["decomp_enable"] == 0


def test_sdd1_log_clear(sdd1_emu):
    assert _run_until_stp(sdd1_emu)
    sdd1_emu.sdd1_log_clear()
    assert sdd1_emu.sdd1_streams() == []


def test_sdd1_decompress_rejects_non_positive_size(sdd1_emu):
    with pytest.raises(ValueError):
        sdd1_emu.sdd1_decompress(0xC08000, 0)


def test_sdd1_absent_on_plain_lorom(assemble_rom):
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_dma_log.s")))
        assert (emu.sdd1_present(), emu.sdd1_registers()) == (False, None)


def test_sdd1_decompress_raises_without_chip(assemble_rom):
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_dma_log.s")))
        with pytest.raises(RuntimeError):
            emu.sdd1_decompress(0xC08000, 16)


def test_sdd1_project_maps_mmc_banks(sdd1_emu, tmp_path):
    sdd1_emu.project_open(tmp_path / "t.kintsuki")
    assert (sdd1_emu.project_bus_to_rom(0xC08000),
            sdd1_emu.project_bus_to_rom(0x018000)) == (0x8000, 0x8000)


def test_sdd1_project_marks_compressed_span(sdd1_emu, tmp_path):
    sdd1_emu.project_open(tmp_path / "t.kintsuki")
    assert _run_until_stp(sdd1_emu)
    span = sdd1_emu.sdd1_streams()[1]["compressed_size"]
    assert sdd1_emu.project_classify(0x8000 + span - 1) == _native.BYTE_GRAPHICS


def test_sdd1_project_skips_decompressed_length(sdd1_emu, tmp_path):
    sdd1_emu.project_open(tmp_path / "t.kintsuki")
    assert _run_until_stp(sdd1_emu)
    assert sdd1_emu.project_classify(0x8000 + STREAM_SIZE - 1) == _native.BYTE_UNKNOWN
