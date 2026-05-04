"""Phase 4a — pure-Python HDMA simulator.

Walks an HDMA table the same way the SNES PPU would, returning the byte
sequence that would land in the destination register on each scanline of
a frame. Lets tests assert "BG3VOFS at scanline 128 == 0xFF98 with
buffer_pos=1" structurally, before touching pixels.

Per fullsnes / SnesLab:

    Line-Counter byte:
      $00          end of table
      $01..$80     non-repeating: write 1 unit, then pause for the next
                   `count` lines (so a $10 count = 16 scanlines holding
                   the value).
      $81..$FF     repeating: write 1 unit per line for (count - $80)
                   scanlines.

Transfer-mode dictates how many bytes per "unit":
    mode 0: 1 byte to 1 register
    mode 1: 2 bytes to 2 registers (B, B+1)
    mode 2: 2 bytes to 1 register      ← BG?VOFS double-write style
    mode 3: 4 bytes to 2 registers
    mode 4: 4 bytes to 4 registers
    mode 5: alias for mode 1 in newer cores
    mode 6: alias for mode 2
    mode 7: alias for mode 3

For now we model modes 0, 2 (the common ones for vertical-scroll HDMA).

Visible scanline budget = 224 lines (NTSC); the simulator returns
exactly that many entries, padded with the last seen value if the table
terminates early. After the terminator, BG?VOFS holds whatever was
last written.
"""

from __future__ import annotations

import struct

import pytest

from kintsuki.hdma import simulate_direct, NTSC_VISIBLE_SCANLINES


def _table(*entries: tuple[int, int]) -> bytes:
    """Build a Mode-2 (word-per-band) HDMA table from (count, value) pairs.
    Terminator (count=0) appended automatically."""
    out = bytearray()
    for count, value in entries:
        out += struct.pack("<BH", count, value)
    out += b"\x00"
    return bytes(out)


def test_simulate_returns_one_entry_per_scanline():
    """224 scanlines of NTSC → 224 entries returned regardless of how
    much of the table is consumed."""
    table = _table((0x80, 0x1234))   # 128 lines hold 0x1234, then end.
    out = simulate_direct(table, transfer_mode=2)
    assert len(out) == NTSC_VISIBLE_SCANLINES == 224


def test_simulate_holds_value_for_band_duration():
    """count=$10 in mode-2 → 16 scanlines of the same 16-bit value."""
    table = _table((0x10, 0xCAFE))
    out = simulate_direct(table, transfer_mode=2)
    assert all(v == 0xCAFE for v in out[:16])


def test_simulate_advances_through_bands():
    """Two-band table: first 8 lines = $AAAA, next 16 = $BBBB."""
    table = _table((0x08, 0xAAAA), (0x10, 0xBBBB))
    out = simulate_direct(table, transfer_mode=2)
    assert out[0] == 0xAAAA
    assert out[7] == 0xAAAA
    assert out[8] == 0xBBBB
    assert out[23] == 0xBBBB


def test_simulate_holds_last_value_after_terminator():
    """Terminator before scanline 224 → remaining lines hold the last
    written value (real PPU just stops writing; whatever was last
    latched stays)."""
    table = _table((0x04, 0x1111), (0x08, 0x2222))
    out = simulate_direct(table, transfer_mode=2)
    assert out[12] == 0x2222   # past terminator (4 + 8 = 12)
    assert out[200] == 0x2222  # way past terminator


def test_simulate_repeat_mode_consumes_one_unit_per_line():
    """Repeat mode (bit 7 set) writes a fresh value per scanline.
    Test with 4 distinct words."""
    payload = struct.pack("<BHHHH", 0x84, 0x1111, 0x2222, 0x3333, 0x4444) + b"\x00"
    out = simulate_direct(payload, transfer_mode=2)
    assert out[0] == 0x1111
    assert out[1] == 0x2222
    assert out[2] == 0x3333
    assert out[3] == 0x4444


def test_simulate_mode0_returns_bytes():
    """Mode 0: 1 byte per unit. Output values are 0..255."""
    payload = struct.pack("<BB", 0x10, 0x42) + b"\x00"
    out = simulate_direct(payload, transfer_mode=0)
    assert out[0] == 0x42
    assert out[15] == 0x42


def test_simulate_rejects_unsupported_mode():
    """Until other transfer modes are needed, raise rather than silently
    return junk."""
    with pytest.raises(NotImplementedError):
        simulate_direct(b"\x00", transfer_mode=4)
