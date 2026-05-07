"""BG tilemap inspector.

Reads a layer's tilemap from VRAM (via ``BGxSC`` for the base + screen
size) and decodes each cell into ``TilemapCell(tile, palette, priority,
hflip, vflip)``. Tests can then assert "row 3, col 2 is the icon's tile
index" or "slot 0 isn't blank" without staring at hex dumps.

Tilemap entry (16-bit, little-endian word in VRAM):
    bits  0..9   tile character index (0..1023)
    bits 10..12  palette group (0..7)
    bit  13      priority bit (0/1)
    bit  14      hflip
    bit  15      vflip

Plane sizes from ``BGxSC`` bits 1..0:
    00 → 32×32 (single sub-plane,  256×256 px)
    01 → 64×32 (two side-by-side,  512×256 px)
    10 → 32×64 (two stacked,       256×512 px)
    11 → 64×64 (four sub-planes,   512×512 px)

VRAM layout for multi-plane sizes: each 32×32 sub-plane occupies $400
words = $800 bytes. Sub-planes are concatenated at increasing addresses.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


class _EmuLike(Protocol):
    def vram_read_range(self, addr: int = 0,
                        length: int | None = None) -> memoryview: ...
    def get_ppu_state(self): ...  # noqa: ANN201


@dataclass(frozen=True)
class TilemapCell:
    """One decoded tilemap entry."""

    tile: int       # 0..1023 (10-bit character index)
    palette: int    # 0..7 (3-bit palette group)
    priority: int   # 0 or 1
    hflip: bool
    vflip: bool

    def is_blank(self) -> bool:
        """Heuristic: tile 0x000 (default-zero VRAM) or 0x0FF (vanilla
        FF4 "empty" font slot) with no flags set is considered blank."""
        if self.priority or self.hflip or self.vflip or self.palette:
            return False
        return self.tile in (0x000, 0x0FF)


def decode_cell(raw: int) -> TilemapCell:
    """Decode a 16-bit tilemap word into a TilemapCell."""
    return TilemapCell(
        tile=raw & 0x3FF,
        palette=(raw >> 10) & 0x07,
        priority=(raw >> 13) & 0x01,
        hflip=bool((raw >> 14) & 0x01),
        vflip=bool((raw >> 15) & 0x01),
    )


_PLANE_SIZE = {
    0: (32, 32),
    1: (64, 32),
    2: (32, 64),
    3: (64, 64),
}


@dataclass(frozen=True)
class Tilemap:
    """In-memory snapshot of a BG's tilemap, decoded cell-by-cell."""

    width: int          # in tile cells
    height: int         # in tile cells
    cells: tuple[TilemapCell, ...]
    base_word: int      # VRAM word base from BGxSC bits 7..2 << 10

    def cell(self, row: int, col: int) -> TilemapCell:
        if not (0 <= row < self.height) or not (0 <= col < self.width):
            raise IndexError(
                f"cell({row}, {col}) out of range "
                f"({self.width}×{self.height})")
        # Multi-sub-plane layout: each 32×32 sub-plane is contiguous in
        # VRAM. Sub-plane index = (row // 32) * (width // 32) + (col // 32).
        sub_w = min(32, self.width)
        sub_h = min(32, self.height)
        sub_planes_w = self.width // 32
        sub_idx = (row // 32) * sub_planes_w + (col // 32)
        local_row = row % sub_h
        local_col = col % sub_w
        flat = sub_idx * 32 * 32 + local_row * 32 + local_col
        return self.cells[flat]

    def cell_is_blank(self, row: int, col: int) -> bool:
        return self.cell(row, col).is_blank()


def read_bg_tilemap(emu: _EmuLike, layer: int) -> Tilemap:
    """Snapshot the BG `layer` tilemap from `emu` (1..4)."""
    if not 1 <= layer <= 4:
        raise ValueError(f"layer must be in 1..4, got {layer}")
    p = emu.get_ppu_state()
    sc = getattr(p, f"bg{layer}sc")
    base_word = (sc & 0xFC) << 8        # tilemap base in VRAM words
    base_byte = base_word << 1          # 2 bytes per word
    size_bits = sc & 0x03
    width, height = _PLANE_SIZE[size_bits]

    cells: list[TilemapCell] = []
    sub_planes = (width // 32) * (height // 32)
    # Each 32×32 sub-plane is 1024 words = 2048 bytes contiguous in VRAM.
    # Bulk-read the whole sub-plane in one FFI hop instead of 2048 single
    # vram_read calls — same 65816-side semantics, ~1000× fewer FFI hops
    # per layer at 60 Hz inspector refresh.
    for sub in range(sub_planes):
        sub_base = base_byte + sub * 0x800
        plane_bytes = emu.vram_read_range(sub_base, 32 * 32 * 2)
        # ctypes-backed memoryviews carry format `<B` which refuses
        # subscripting on some Python versions; recast to plain `B` so
        # `plane_bytes[i]` returns an int regardless of platform.
        plane_bytes = memoryview(plane_bytes).cast("B")
        for i in range(32 * 32):
            lo = plane_bytes[i * 2]
            hi = plane_bytes[i * 2 + 1]
            cells.append(decode_cell(lo | (hi << 8)))
    return Tilemap(width=width, height=height,
                   cells=tuple(cells), base_word=base_word)
