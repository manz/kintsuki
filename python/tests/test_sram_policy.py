"""SRAM size mismatches: incoming SRAM (inject_sram, the .srm sidecar, a
savestate's cart.sram region) whose size differs from the cart's declared SRAM
goes through Emu.sram_policy - refused with a message by default, or
truncated / extended / fitted / cleared on request.

test_sram.s declares 32 KiB of SRAM, test_sram_8k.s 8 KiB.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from kintsuki import Emu, SramSizeError, SramSizeWarning

KB = 1024


def _booted(rom: Path, policy: str = "error") -> Emu:
    emu = Emu(load_srm_sidecar=False, sram_policy=policy)
    emu.load_rom(str(rom))
    emu.run_frames(2)
    return emu


def _sram_of(emu: Emu) -> bytes:
    """Read the cart's SRAM back through a state: its KSSF footer locates it."""
    import struct
    blob = emu.save_state()
    flen = struct.unpack("<I", blob[-8:-4])[0]
    footer = blob[-8 - flen:-8]
    cur = 4
    while cur < flen:
        nl = footer[cur]
        name = footer[cur + 1:cur + 1 + nl].decode()
        cur += 1 + nl
        dl = struct.unpack("<I", footer[cur:cur + 4])[0]
        data = footer[cur + 4:cur + 4 + dl]
        cur += 4 + dl
        if name == "cart.sram":
            off, length = struct.unpack("<II", data)
            return blob[off:off + length]
    raise AssertionError("no cart.sram region in the state")


@pytest.fixture
def rom32(assemble_rom) -> Path:
    return assemble_rom("test_sram.s")


@pytest.fixture
def rom8(assemble_rom) -> Path:
    return assemble_rom("test_sram_8k.s")


# --- inject_sram ---------------------------------------------------------------

def test_inject_exact_size_loads(rom8: Path) -> None:
    with _booted(rom8) as emu:
        assert emu.inject_sram(b"\x5A" * (8 * KB)) == 8 * KB
        assert _sram_of(emu) == b"\x5A" * (8 * KB)


def test_inject_mismatch_is_refused_with_a_message(rom8: Path) -> None:
    with _booted(rom8) as emu:
        with pytest.raises(SramSizeError, match=r"2048 bytes but the cart declares 8192.*extend"):
            emu.inject_sram(b"\x11" * (2 * KB))
        assert _sram_of(emu) == bytes(8 * KB), "a refused inject touched the SRAM"


@pytest.mark.parametrize("policy,size,expect", [
    ("extend", 2 * KB, b"\x11" * (2 * KB) + bytes(6 * KB)),
    ("fit", 2 * KB, b"\x11" * (2 * KB) + bytes(6 * KB)),
    ("truncate", 32 * KB, b"\x11" * (8 * KB)),
    ("fit", 32 * KB, b"\x11" * (8 * KB)),
    ("clear", 2 * KB, bytes(8 * KB)),
])
def test_inject_policies(rom8: Path, policy: str, size: int, expect: bytes) -> None:
    with _booted(rom8, policy) as emu:
        emu.inject_sram(b"\x11" * size)
        assert _sram_of(emu) == expect


@pytest.mark.parametrize("policy,size", [("truncate", 2 * KB), ("extend", 32 * KB)])
def test_one_way_policies_refuse_the_other_way(rom8: Path, policy: str, size: int) -> None:
    with _booted(rom8, policy) as emu:
        with pytest.raises(SramSizeError):
            emu.inject_sram(b"\x11" * size)


def test_unknown_policy_is_a_value_error() -> None:
    with pytest.raises(ValueError):
        Emu(sram_policy="squash")


# --- savestates across carts with different SRAM sizes --------------------------

def _state_from(rom: Path, fill: int) -> bytes:
    with _booted(rom, "fit") as emu:
        emu.inject_sram(bytes([fill]) * (64 * KB))  # fits whatever the cart has
        return emu.save_state()


def test_a_state_from_another_sram_size_is_refused(rom8: Path, rom32: Path) -> None:
    blob = _state_from(rom32, 0x22)
    with _booted(rom8) as emu:
        with pytest.raises(SramSizeError, match=r"load_state: SRAM is 32768 bytes but the cart declares 8192"):
            emu.load_state(blob)


def test_fit_loads_a_smaller_state_and_zero_extends(rom8: Path, rom32: Path) -> None:
    blob = _state_from(rom8, 0x33)
    with _booted(rom32, "fit") as emu:
        emu.load_state(blob)
        assert _sram_of(emu) == b"\x33" * (8 * KB) + bytes(24 * KB)
        emu.run_frames(2)  # the rest of the state lines up: it still runs


def test_clear_loads_the_state_without_its_sram(rom8: Path, rom32: Path) -> None:
    blob = _state_from(rom32, 0x44)
    with _booted(rom8, "clear") as emu:
        emu.load_state(blob)
        assert _sram_of(emu) == bytes(8 * KB)
        emu.run_frames(2)


def test_a_same_size_state_ignores_the_policy(rom8: Path) -> None:
    blob = _state_from(rom8, 0x55)
    with _booted(rom8, "clear") as emu:
        emu.load_state(blob)
        assert _sram_of(emu) == b"\x55" * (8 * KB)


# --- the .srm sidecar --------------------------------------------------------------

def test_a_mismatched_sidecar_warns_and_is_ignored(rom8: Path, tmp_path: Path) -> None:
    rom = tmp_path / "sram8.sfc"
    shutil.copy(rom8, rom)
    (tmp_path / "sram8.srm").write_bytes(b"\x66" * (2 * KB))
    with Emu(load_srm_sidecar=True) as emu:
        with pytest.warns(SramSizeWarning, match="sidecar"):
            emu.load_rom(str(rom))
        assert _sram_of(emu) == bytes(8 * KB)


def test_a_mismatched_sidecar_loads_under_fit(rom8: Path, tmp_path: Path) -> None:
    rom = tmp_path / "sram8.sfc"
    shutil.copy(rom8, rom)
    (tmp_path / "sram8.srm").write_bytes(b"\x66" * (2 * KB))
    with Emu(load_srm_sidecar=True, sram_policy="fit") as emu:
        emu.load_rom(str(rom))
        assert _sram_of(emu) == b"\x66" * (2 * KB) + bytes(6 * KB)
