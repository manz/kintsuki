"""Phase 4c — BG tilemap inspector.

Reads a layer's tilemap from VRAM (using BGxSC for the base + screen
size) and decodes each cell into (tile, palette, priority, hflip,
vflip). Lets tests assert "BG3 row 3, col 2 isn't blank" or "tile at
slot 0 has the icon's tile index" without staring at hex dumps.

Tilemap entry (16-bit, little-endian in VRAM):
    bits  0-9   tile character index (0..1023)
    bits 10-12  palette group (0..7)
    bit  13     priority (0/1)
    bit  14     hflip
    bit  15     vflip

Plane sizes from BGxSC bits 1-0:
    00 → 32×32 (single sub-plane,    256×256 px)
    01 → 64×32 (two side-by-side,    512×256 px)
    10 → 32×64 (two stacked,         256×512 px)
    11 → 64×64 (four sub-planes,     512×512 px)
"""

from __future__ import annotations

import pytest

from kintsuki.tilemap import (
    Tilemap,
    TilemapCell,
    decode_cell,
    read_bg_tilemap,
)


def test_decode_cell_simple():
    """Plain tile (no flip / no priority / palette 0)."""
    cell = decode_cell(0x0042)
    assert cell.tile == 0x42
    assert cell.palette == 0
    assert cell.priority == 0
    assert cell.hflip is False
    assert cell.vflip is False


def test_decode_cell_full_attributes():
    """All flag bits + palette + tile high bits."""
    # bits: vflip=1 hflip=1 priority=1 palette=5 tile=0x123
    raw = (1 << 15) | (1 << 14) | (1 << 13) | (5 << 10) | 0x123
    cell = decode_cell(raw)
    assert cell.tile == 0x123
    assert cell.palette == 5
    assert cell.priority == 1
    assert cell.hflip is True
    assert cell.vflip is True


def test_decode_cell_blank_helper():
    """A cell with tile=$FF (vanilla "empty" font slot in FF4) is
    queryable via .is_blank()."""
    cell = decode_cell(0x00FF)
    assert cell.is_blank() is True
    cell2 = decode_cell(0x0042)
    assert cell2.is_blank() is False


class _FakeEmu:
    """Stub Emu exposing the minimum surface read_bg_tilemap needs:
    a `vram_read(addr)` byte read + `get_ppu_state()` returning a
    PpuState-like object with bgXsc fields."""

    def __init__(self, *, bg3sc: int, vram: bytes) -> None:
        self._bg3sc = bg3sc
        self._vram = vram

    def vram_read(self, addr: int) -> int:
        return self._vram[addr] if 0 <= addr < len(self._vram) else 0

    def get_ppu_state(self):
        # Object-with-attributes is enough; we don't need a real PpuState.
        class _P:
            bg1sc = 0
            bg2sc = 0
            bg3sc = self._bg3sc
            bg4sc = 0
        return _P()


def test_read_bg_tilemap_32x32_plane():
    """BGxSC bits 1-0 = 00 → 32×32 plane. Tile at row=1, col=2 should
    decode to whatever we wrote at byte (1*32 + 2)*2 = 68."""
    bg3_byte_base = 0xE000  # tilemap word $7000 → byte $E000
    vram = bytearray(0x10000)
    # Place a known tile at (row=1, col=2)
    raw = (4 << 10) | 0x0CD  # palette=4, tile=$0CD
    off = bg3_byte_base + (1 * 32 + 2) * 2
    vram[off] = raw & 0xFF
    vram[off + 1] = (raw >> 8) & 0xFF

    # bg3sc = $70 = (base $7000 word >> 8) | screenSize=00 → $70
    emu = _FakeEmu(bg3sc=0x70, vram=bytes(vram))
    tilemap = read_bg_tilemap(emu, layer=3)
    assert isinstance(tilemap, Tilemap)
    assert tilemap.width == 32
    assert tilemap.height == 32
    cell = tilemap.cell(row=1, col=2)
    assert cell.tile == 0x0CD
    assert cell.palette == 4


def test_read_bg_tilemap_32x64_plane():
    """BGxSC bits 1-0 = 10 → 32×64 plane (two sub-planes stacked)."""
    bg3_byte_base = 0xE000
    vram = bytearray(0x10000)
    # Place a tile in the LOWER sub-plane (row=33, col=0) — that lives
    # at the second 32×32 block starting $400 words later.
    second_plane_base = bg3_byte_base + 0x400 * 2  # $E800
    raw = 0x0234
    off = second_plane_base + (1 * 32 + 0) * 2  # row 33 = row 1 of 2nd block
    vram[off] = raw & 0xFF
    vram[off + 1] = (raw >> 8) & 0xFF
    # bg3sc bits 1-0 = 10 → vertical-extension; high bits same as $70.
    emu = _FakeEmu(bg3sc=0x70 | 0x02, vram=bytes(vram))
    tm = read_bg_tilemap(emu, layer=3)
    assert tm.width == 32
    assert tm.height == 64
    cell = tm.cell(row=33, col=0)
    assert cell.tile == 0x234


def test_cell_is_blank_via_tilemap():
    """Convenience: `tilemap.cell_is_blank(row, col)` returns the
    same boolean as `tilemap.cell(row, col).is_blank()`."""
    bg3_byte_base = 0xE000
    vram = bytearray(0x10000)
    # Default-zero VRAM: tile=0 is "blank-ish" — real test sets $FF.
    raw = 0x00FF
    off = bg3_byte_base + (3 * 32 + 5) * 2
    vram[off] = raw & 0xFF
    vram[off + 1] = (raw >> 8) & 0xFF
    emu = _FakeEmu(bg3sc=0x70, vram=bytes(vram))
    tm = read_bg_tilemap(emu, layer=3)
    assert tm.cell_is_blank(row=3, col=5) is True
    assert tm.cell_is_blank(row=0, col=0) is True  # default-zero is also blank-ish


def test_read_bg_tilemap_rejects_invalid_layer():
    emu = _FakeEmu(bg3sc=0x70, vram=b"\x00" * 0x10000)
    with pytest.raises(ValueError):
        read_bg_tilemap(emu, layer=5)
    with pytest.raises(ValueError):
        read_bg_tilemap(emu, layer=0)
