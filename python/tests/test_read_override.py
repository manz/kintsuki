"""Read overrides let Python stand in for a memory-mapped device: the
override's return value replaces what the CPU bus would have read, for data
loads and opcode fetches alike."""

from __future__ import annotations

from pathlib import Path

import pytest

from kintsuki import Emu

RESULT = 0x7E0010
DEVICE = 0xC06000
ROM_RESET = 0x008000
SEI = 0x78


@pytest.fixture
def emu(assemble_rom) -> Emu:
    rom: Path = assemble_rom("test_rom.s")
    with Emu(load_srm_sidecar=False) as e:
        e.load_rom(str(rom))
        e.run_frames(2)
        yield e


def _load_long_to_result(emu: Emu, addr: int) -> int:
    # sep #$20 ; lda.l addr ; sta.l RESULT
    code = bytes([0xE2, 0x20, 0xAF]) + addr.to_bytes(3, "little")
    code += bytes([0x8F]) + RESULT.to_bytes(3, "little")
    emu.run_asm(code)
    return emu.read(RESULT)


def test_override_value_reaches_the_cpu(emu: Emu) -> None:
    emu.add_read_override(DEVICE, DEVICE, lambda _a, _ob: 0x5A)
    assert _load_long_to_result(emu, DEVICE) == 0x5A


def test_none_falls_through_to_the_bus(emu: Emu) -> None:
    seen: list[int] = []

    def passive(addr: int, _ob: int) -> None:
        seen.append(addr)

    emu.add_read_override(ROM_RESET, ROM_RESET, passive)
    assert _load_long_to_result(emu, ROM_RESET) == SEI
    assert ROM_RESET in seen


def test_overridden_bytes_execute(emu: Emu) -> None:
    routine = bytes([0xA9, 0x77, 0x6B])  # lda #$77 ; rtl (8-bit A)
    base = 0x018000
    emu.add_read_override(base, base + len(routine) - 1,
                          lambda addr, _ob: routine[addr - base])
    # sep #$20 ; jsl base ; sta.l RESULT
    code = bytes([0xE2, 0x20, 0x22]) + base.to_bytes(3, "little")
    code += bytes([0x8F]) + RESULT.to_bytes(3, "little")
    emu.run_asm(code)
    assert emu.read(RESULT) == 0x77


def test_read_callback_sees_the_overridden_value(emu: Emu) -> None:
    hits: list[int] = []
    emu.add_read_override(DEVICE, DEVICE, lambda _a, _ob: 0x3C)
    emu.add_read_callback(DEVICE, DEVICE, lambda _a, v: hits.append(v))
    _load_long_to_result(emu, DEVICE)
    assert hits == [0x3C]


def test_removed_override_stops_applying(emu: Emu) -> None:
    oid = emu.add_read_override(ROM_RESET, ROM_RESET, lambda _a, _ob: 0x00)
    emu.remove_read_override(oid)
    assert _load_long_to_result(emu, ROM_RESET) == SEI


def test_out_of_range_value_is_rejected(emu: Emu) -> None:
    emu.add_read_override(DEVICE, DEVICE, lambda _a, _ob: 0x100)
    with pytest.raises(ValueError):
        _load_long_to_result(emu, DEVICE)
