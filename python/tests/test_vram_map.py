"""VRAM map: the words each layer drew from and who wrote what.

`asm/test_vram_map.s` draws BG1 (tile 0 everywhere, map at $1000, tiles at $2000) and one 8x8 sprite (tiles at
$4000), and DMAs 32 bytes to $3000 each NMI, a write no layer reads.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from kintsuki import Emu, VramMap
from kintsuki.vram_map import BG_MAP, BG_TILES, DEAD, FREE, OBJ_TILES, READ, layer_names

MAP_ROWS = 29  # lines 1-224 at no scroll: rows 0-28


@pytest.fixture
def emu(assemble_rom):
    rom = assemble_rom("test_vram_map.s")
    with Emu() as emu:
        emu.load_rom(str(rom), adbg=str(Path(str(rom) + ".adbg")))
        emu.run_frames(2)
        yield emu


@pytest.fixture
def recorded(emu) -> VramMap:
    emu.vram_map_start()
    emu.run_frames(3)
    emu.vram_map_stop()
    return emu.vram_map()


def _words(vram: VramMap, bit: int) -> list[int]:
    return [word for word, reads in enumerate(vram.reads) if reads & bit]


def test_vram_map_is_empty_before_a_start(emu):
    assert len(emu.vram_map().reads) == 0


def test_vram_map_covers_vram(recorded):
    assert len(recorded.reads) == len(recorded.writes) == len(recorded.writers) == 0x8000


def test_vram_map_marks_the_bg_map_rows_drawn(recorded):
    assert _words(recorded, BG_MAP[0]) == list(range(0x1000, 0x1000 + MAP_ROWS * 32))


def test_vram_map_marks_the_bg_tile_planes_drawn(recorded):
    assert _words(recorded, BG_TILES[0]) == list(range(0x2000, 0x2010))  # 4bpp: rows at +0 and +8


def test_vram_map_marks_the_obj_tiles_drawn(recorded):
    assert _words(recorded, OBJ_TILES) == list(range(0x4000, 0x4010))


def test_vram_map_leaves_disabled_layers_out(recorded):
    assert not any(reads & (BG_MAP[1] | BG_TILES[1] | BG_MAP[2] | BG_TILES[2]) for reads in recorded.reads)


def test_vram_map_counts_writes_with_their_routine(emu, recorded):
    written = [word for word, writes in enumerate(recorded.writes) if writes]
    assert written == list(range(0x3000, 0x3010))
    assert {recorded.writes[w] for w in written} == {3 * 2}  # a frame's DMA writes each word's two bytes
    assert {recorded.writers[w] for w in written} == {emu.lookup_symbol_addr("nmi")}


def test_vram_map_runs_split_read_dead_and_free(emu, recorded):
    runs = {(run.start, run.end): run for run in recorded.runs()}
    assert runs[0x1000, 0x139F].layers == ("BG1 map",)
    dead = runs[0x3000, 0x300F]
    assert (dead.kind, dead.writes, dead.writers) == (DEAD, 16 * 6, frozenset({emu.lookup_symbol_addr("nmi")}))
    assert runs[0x2010, 0x2FFF].kind == FREE
    assert sum(run.words for run in runs.values()) == 0x8000


def test_vram_map_unread_leaves_the_read_runs_out(recorded):
    unread = recorded.unread()
    assert all(run.kind != READ for run in unread)
    assert sum(run.words for run in unread) == 0x8000 - (MAP_ROWS * 32 + 16 + 16)


def test_vram_map_start_clears_the_last_map(emu, recorded):
    emu.vram_map_start()
    assert not any(emu.vram_map().writes)


def test_vram_map_stop_keeps_later_frames_out(emu, recorded):
    emu.run_frames(2)
    assert emu.vram_map().writes == recorded.writes


def test_ppu_state_rebuilds_obsel(emu):
    assert emu.get_ppu_state().obsel == 0x02


def test_layer_names_lists_maps_then_tiles():
    assert layer_names(BG_MAP[2] | BG_TILES[0] | OBJ_TILES) == ("BG3 map", "BG1 tiles", "OBJ tiles")
