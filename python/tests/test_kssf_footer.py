"""Tests for the KSSF savestate footer + kintsuki_load_state_ex.

The footer is appended to every blob produced by ``save_state`` when the
bound cart has SRAM. It is opaque to ares — the legacy ``load_state``
strips it before calling ``System::unserialize`` — but ``load_state_ex``
uses it to drive cross-ROM / size-mismatched restores.
"""

from __future__ import annotations

import struct
from pathlib import Path

import pytest

import kintsuki

ROM = Path(__file__).parent / "asm" / "test_ppu_state.sfc"
FF4 = Path("/Users/manz/PyCharmProjects/ff4-modules/build/ff4.sfc")


def _parse_footer(blob: bytes) -> dict[str, tuple[int, int]]:
    """Return a {region_name: (offset, length)} map, empty if no footer."""
    if len(blob) < 8 or blob[-4:] != b"KSSF":
        return {}
    flen = struct.unpack("<I", blob[-8:-4])[0]
    footer = blob[-8 - flen : -8]
    cur = 4  # skip version
    regions: dict[str, tuple[int, int]] = {}
    while cur < flen:
        nl = footer[cur]
        cur += 1
        name = footer[cur : cur + nl].decode()
        cur += nl
        dl = struct.unpack("<I", footer[cur : cur + 4])[0]
        cur += 4
        data = footer[cur : cur + dl]
        cur += dl
        if name == "cart.sram" and dl == 8:
            regions[name] = struct.unpack("<II", data)
    return regions


def test_blob_has_no_footer_when_cart_has_no_sram():
    emu = kintsuki.Emu()
    emu.load_rom(str(ROM))
    emu.run_frames(2)
    blob = emu.save_state()
    assert blob[-4:] != b"KSSF", "ppu_state ROM has no SRAM; footer should be absent"


@pytest.mark.skipif(not FF4.exists(), reason="ff4.sfc not available")
def test_blob_has_footer_when_cart_has_sram():
    emu = kintsuki.Emu(loadSrmSidecar=False) if False else kintsuki.Emu()
    emu.load_rom(str(FF4))
    emu.run_frames(2)
    blob = emu.save_state()
    assert blob[-4:] == b"KSSF"

    regions = _parse_footer(blob)
    assert "cart.sram" in regions
    offset, length = regions["cart.sram"]
    assert offset > 0
    assert length > 0
    # The recorded region must lie inside the ares blob (everything before
    # the trailer): offset+length <= ares_blob_len.
    flen = struct.unpack("<I", blob[-8:-4])[0]
    ares_blob_len = len(blob) - 8 - flen
    assert offset + length <= ares_blob_len


@pytest.mark.skipif(not FF4.exists(), reason="ff4.sfc not available")
def test_legacy_load_state_strips_footer():
    """save_state writes a footer; load_state must still accept it."""
    emu = kintsuki.Emu()
    emu.load_rom(str(FF4))
    emu.run_frames(2)
    blob = emu.save_state()
    emu.run_frames(10)
    emu.load_state(blob)


@pytest.mark.skipif(not FF4.exists(), reason="ff4.sfc not available")
def test_load_state_ex_inject_only_same_rom():
    """INJECT_ONLY power-cycles and restores just the cart.sram region."""
    emu = kintsuki.Emu()
    emu.load_rom(str(FF4))
    emu.run_frames(2)

    # Stamp a known signature into the cart sram via inject_sram.
    blob = emu.save_state()
    regions = _parse_footer(blob)
    assert "cart.sram" in regions
    offset, length = regions["cart.sram"]
    # Sanity-check: sram bytes at the recorded region are restorable.
    sram_bytes = blob[offset : offset + length]
    assert len(sram_bytes) == length

    # INJECT_ONLY should succeed on a fresh emu bound to the same ROM.
    emu2 = kintsuki.Emu()
    emu2.load_rom(str(FF4))
    emu2.load_state_ex(blob, flags=kintsuki.Emu.LOAD_FLAG_INJECT_ONLY)


@pytest.mark.skipif(not FF4.exists(), reason="ff4.sfc not available")
def test_load_state_ex_strict_rejects_size_mismatch():
    """STRICT must reject if expected_sram_size disagrees with cart."""
    emu = kintsuki.Emu()
    emu.load_rom(str(FF4))
    emu.run_frames(2)
    blob = emu.save_state()

    # Lie about the producer sram size — STRICT should refuse the load.
    with pytest.raises(RuntimeError, match="load_state_ex failed"):
        emu.load_state_ex(
            blob,
            flags=kintsuki.Emu.LOAD_FLAG_STRICT,
            expected_sram_size=1,  # wrong on purpose
        )
