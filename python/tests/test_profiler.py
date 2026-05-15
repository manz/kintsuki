"""Per-function profiler — JSR/JSL/RTS/RTL push/pop sampling on top of
kintsuki's existing call hooks.

The ROM `asm/test_profiler.s` drives a 5-deep call chain in an infinite
loop with one slow leaf (64 nops) and one fast leaf (1 nop). With the
profiler running over a multi-frame window we expect identical call
counts across the chain and the slow leaf to dominate exclusive cycles.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from kintsuki import Emu, FnStat


def _by_pc(stats: list[FnStat]) -> dict[int, FnStat]:
    return {s.pc: s for s in stats}


def test_profiler_aggregates_chain(assemble_rom):
    rom = assemble_rom("test_profiler.s")
    adbg = Path(str(rom) + ".adbg")
    with Emu() as emu:
        emu.load_rom(str(rom))
        if adbg.exists():
            emu.load_adbg(adbg)

        emu.profile_start()
        emu.run_frames(10)
        stats = emu.profile_stop()

        assert len(stats) == 5, f"expected 5 fns, got {[hex(s.pc) for s in stats]}"

        by_pc = _by_pc(stats)
        outer     = by_pc[0x008100]
        mid_a     = by_pc[0x008200]
        mid_b     = by_pc[0x008300]
        leaf_fast = by_pc[0x008400]
        leaf_slow = by_pc[0x008500]

        # Call counts: mid_b calls both leaves once per iteration; the
        # other rungs are 1:1. leaf_fast may be ahead by one when the
        # snapshot lands between leaf_fast and leaf_slow.
        assert outer.calls == mid_a.calls == mid_b.calls
        assert leaf_slow.calls == mid_b.calls
        assert leaf_fast.calls in (mid_b.calls, mid_b.calls + 1)

        # Slow leaf must dominate exclusive cycles — 64 nops vs 1 nop in
        # the asm. Allow a wide margin; static cycle counts aren't being
        # asserted, only the ordering.
        assert leaf_slow.excl_cycles > leaf_fast.excl_cycles * 10

        # Leaves call nothing → excl == incl.
        assert leaf_fast.excl_cycles == leaf_fast.incl_cycles
        assert leaf_slow.excl_cycles == leaf_slow.incl_cycles

        # outer.incl ≥ mid_a.incl ≥ mid_b.incl ≥ each leaf.incl
        # (parent inclusive bounds children's inclusive)
        assert outer.incl_cycles >= mid_a.incl_cycles
        assert mid_a.incl_cycles >= mid_b.incl_cycles
        assert mid_b.incl_cycles >= leaf_slow.incl_cycles + leaf_fast.incl_cycles - 1

        # min ≤ max per fn.
        for s in stats:
            assert s.min_cycles <= s.max_cycles
            assert s.min_cycles > 0


def test_profiler_resolves_names(assemble_rom):
    rom = assemble_rom("test_profiler.s")
    adbg = Path(str(rom) + ".adbg")
    if not adbg.exists():
        pytest.skip(f"missing .adbg next to {rom.name}")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.load_adbg(adbg)
        emu.profile_start()
        emu.run_frames(3)
        stats = emu.profile_stop()
        names = {s.name for s in stats}
        assert {"outer", "mid_a", "mid_b", "leaf_fast", "leaf_slow"} <= names


def test_profiler_pc_range_filter(assemble_rom):
    rom = assemble_rom("test_profiler.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        # Range covering only the two leaves.
        emu.profile_start(lo=0x008400, hi=0x008500)
        emu.run_frames(5)
        stats = emu.profile_stop()
        pcs = {s.pc for s in stats}
        assert pcs == {0x008400, 0x008500}, f"unexpected pcs in filtered profile: {pcs}"


def test_profiler_reset_and_restart(assemble_rom):
    rom = assemble_rom("test_profiler.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.profile_start()
        emu.run_frames(3)
        first = emu.profile_stop()
        assert first

        # Starting again clears prior state — counts must not accumulate.
        emu.profile_start()
        emu.run_frames(3)
        second = emu.profile_stop()
        first_by_pc = _by_pc(first)
        second_by_pc = _by_pc(second)
        common = set(first_by_pc) & set(second_by_pc)
        for pc in common:
            # Window 2's call count should be roughly the same magnitude
            # as window 1's, not its sum.
            assert second_by_pc[pc].calls < first_by_pc[pc].calls * 2


def test_profiler_master_cycles_property(assemble_rom):
    rom = assemble_rom("test_profiler.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        before = emu.master_cycles
        emu.run_frames(2)
        after = emu.master_cycles
        # Within a single short burst the ares scheduler should not have
        # reduced; raw clock progresses forward. (Across many run_frames
        # calls the absolute value is non-monotonic — documented caveat.)
        assert after > before
