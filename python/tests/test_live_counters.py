"""Live counters: master cycles + scanline/dot at the executing instruction,
exact inside callbacks (where master_cycles and the PPU's latched counters
lag)."""

from __future__ import annotations

from kintsuki import Emu, LiveCounters

INIDISP = 0x2100


def _record(emu: Emu, frames: int = 2) -> tuple[list[LiveCounters], list[dict]]:
    samples: list[LiveCounters] = []
    emu.add_write_callback(INIDISP, INIDISP, lambda _a, _v: samples.append(emu.live_counters()))
    emu.ppu_writes_start()
    emu.run_frames(frames)
    emu.ppu_writes_stop()
    return samples, [w for w in emu.ppu_writes() if w["addr"] == INIDISP]


def test_scanline_matches_the_ppu_write_log(assemble_rom):
    """A write callback's live v/h equal the PPU write log's for the same writes."""
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_live_counters.s")))
        samples, writes = _record(emu)
    assert len(samples) == len(writes) > 100
    assert [(s.v, s.h) for s in samples] == [(w["v"], w["h"]) for w in writes]


def test_master_is_monotonic_and_paced_by_the_loop(assemble_rom):
    """Master cycles grow by roughly one loop pass between writes (the 40-nop
    loop is ~90 CPU cycles = ~540 master; DRAM refresh adds a little)."""
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_live_counters.s")))
        samples, _ = _record(emu)
    deltas = [b.master - a.master for a, b in zip(samples, samples[1:])]
    assert all(d > 0 for d in deltas)
    assert 400 < sorted(deltas)[len(deltas) // 2] < 800
