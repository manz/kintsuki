"""Which VRAM words a run drew from and which it wrote: what :meth:`kintsuki.Emu.vram_map` returns.

While recording, every VRAM word the PPU fetches to draw gets its layer's bit (a BG's tilemap or tiles, OBJ tiles),
and every write that lands is counted with the routine that made it. The PPU's registers say where a layer starts;
the reads say how far it really reaches. Words with the same reads that were all written or all not form a
:class:`VramRun`: a `dead` run was written but never drawn from, a `free` one neither, the room a layout can pack into.
"""

from __future__ import annotations

import array
from dataclasses import dataclass

BG_MAP = tuple(1 << n for n in range(4))  # BG1-4 tilemap (mode 7: BG1's map)
BG_TILES = tuple(0x10 << n for n in range(4))  # BG1-4 tiles
OBJ_TILES = 0x100
READ, DEAD, FREE = "read", "dead", "free"


def layer_names(reads: int) -> tuple[str, ...]:
    """The layers `reads` holds the bits of: "BG1 map", "BG3 tiles", "OBJ tiles"."""
    names = [f"BG{n + 1} map" for n, bit in enumerate(BG_MAP) if reads & bit]
    names += [f"BG{n + 1} tiles" for n, bit in enumerate(BG_TILES) if reads & bit]
    return (*names, "OBJ tiles") if reads & OBJ_TILES else tuple(names)


@dataclass(frozen=True)
class VramRun:
    start: int  # word address
    end: int  # word address, inclusive
    reads: int  # the layer bits every word of the run has
    writes: int  # writes that landed in the run
    writers: frozenset[int]  # the routines (24-bit PCs) that wrote it

    @property
    def words(self) -> int:
        return self.end - self.start + 1

    @property
    def kind(self) -> str:
        """READ when a layer drew from it, else DEAD when written, else FREE."""
        return READ if self.reads else DEAD if self.writes else FREE

    @property
    def layers(self) -> tuple[str, ...]:
        return layer_names(self.reads)


@dataclass(frozen=True)
class VramMap:
    reads: array.array  # "H": layer bits per word
    writes: array.array  # "I": writes landed per word
    writers: array.array  # "I": the last write's routine per word (0 when never written)

    def runs(self) -> list[VramRun]:
        """VRAM cut where a word's reads change or it goes from written to not."""
        runs: list[VramRun] = []
        start = 0
        for word in range(1, len(self.reads) + 1):
            if word < len(self.reads) and self._key(word) == self._key(start):
                continue
            span = range(start, word)
            runs.append(VramRun(
                start, word - 1, self.reads[start], sum(self.writes[w] for w in span),
                frozenset(self.writers[w] for w in span if self.writes[w]),
            ))
            start = word
        return runs

    def unread(self) -> list[VramRun]:
        """The DEAD and FREE runs: what no layer drew from."""
        return [run for run in self.runs() if run.kind != READ]

    def _key(self, word: int) -> tuple[int, bool]:
        return self.reads[word], self.writes[word] > 0
