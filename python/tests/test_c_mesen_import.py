"""Phase: C ABI for Mesen .mss import.

The Python `kintsuki.mesen.import_mesen_state(...)` (#16) is fine for
pytest, but the Swift desktop app would need to either embed Python or
re-implement the parser. Pushing the import to libkintsuki gives both
hosts a single source of truth via one extern "C" call.

These tests round-trip a real ff4 .mss through the new
`Emu.import_mesen_state(path)` Python helper (which calls the C ABI)
and verify CPU registers + sentinel memory reads match what the
state file declares.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from kintsuki import Emu
from kintsuki.mesen import parse_mesen_state


_FF4_MSS = Path(
    "/Users/manz/PyCharmProjects/ff4-modules/tests/savestates/"
    "battle_end_before_treasure.mss"
)


def _need_fixture():
    if not _FF4_MSS.exists():
        pytest.skip(f"fixture not present: {_FF4_MSS}")


def test_emu_has_import_mesen_state():
    """Smoke: API exists on the Python wrapper."""
    with Emu() as emu:
        assert hasattr(emu, "import_mesen_state"), (
            "Emu.import_mesen_state(path) missing — wire the C ABI binding")


def test_import_mesen_state_via_c_round_trips_cpu(assemble_rom):
    """Boot a tiny ROM + import a real ff4 .mss; verify the loaded CPU
    registers match what the .mss declares. We don't need the FF4 ROM —
    set_state is honoured even when the loaded ROM differs (it's just
    setting CPU registers + memory, not running)."""
    _need_fixture()
    rom = assemble_rom("test_ppu_state.s")
    state = parse_mesen_state(_FF4_MSS)
    expected = state.records
    expected_a  = int.from_bytes(expected[b"cpu.a"],  "little")
    expected_x  = int.from_bytes(expected[b"cpu.x"],  "little")
    expected_y  = int.from_bytes(expected[b"cpu.y"],  "little")
    expected_pc = int.from_bytes(expected[b"cpu.pc"], "little") \
        | (expected[b"cpu.k"][0] << 16)
    expected_p  = expected[b"cpu.ps"][0]

    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.import_mesen_state(str(_FF4_MSS))
        s = emu.get_state()
        assert s.a == expected_a, f"A: ${s.a:04X} vs ${expected_a:04X}"
        assert s.x == expected_x, f"X: ${s.x:04X} vs ${expected_x:04X}"
        assert s.y == expected_y, f"Y: ${s.y:04X} vs ${expected_y:04X}"
        assert s.pc == expected_pc, f"PC: ${s.pc:06X} vs ${expected_pc:06X}"
        assert s.p == expected_p, f"P: ${s.p:02X} vs ${expected_p:02X}"


def test_import_mesen_state_via_c_round_trips_wram(assemble_rom):
    """Sample a few WRAM bytes after import; expect them to match the
    payload the .mss recorded."""
    _need_fixture()
    rom = assemble_rom("test_ppu_state.s")
    state = parse_mesen_state(_FF4_MSS)
    wram = state.records[b"memoryManager.workRam"]
    sample_offsets = [0, 0x1234, 0x7FFF, 0x10000, 0x1FFFF]

    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.import_mesen_state(str(_FF4_MSS))
        for off in sample_offsets:
            got = emu.read(0x7E0000 + off)
            want = wram[off]
            assert got == want, (
                f"WRAM[${off:05X}]: got ${got:02X} want ${want:02X}")


def test_import_mesen_state_returns_false_on_missing_file():
    """Bad path → graceful False, no exception that crashes the host
    Swift process."""
    with Emu() as emu:
        ok = emu.import_mesen_state("/nope/does/not/exist.mss")
        assert ok is False
