"""Shadow callstack — pushes/pops driven by ares' WDC65816 JSR/JSL/RTS/RTL
instruction implementations via call/return hooks.

The test ROM in `asm/test_callstack.s` runs a JSL → JSR → STP chain so by
the time the CPU halts the live stack has two frames in it (deepest first).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from kintsuki import Emu


def _run_until_stp(emu: Emu, max_frames: int = 60) -> bool:
    """Spin the emulator until the CPU enters STP. Returns False if the
    timeout fires first so failures point at the run loop, not the assert."""
    for _ in range(max_frames):
        emu.run_frames(1)
        s = emu.get_state()
        if s.stp:
            return True
    return False


def test_callstack_jsl_jsr_stp_chain(assemble_rom):
    rom = assemble_rom("test_callstack.s")
    adbg = Path(str(rom) + ".adbg")
    if not adbg.exists():
        pytest.skip(f"missing .adbg next to {rom.name}")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.load_adbg(adbg)
        # Fresh boot: no calls executed yet → empty shadow stack.
        assert emu.callstack() == []
        assert _run_until_stp(emu), "CPU never halted at the inner STP"

        frames = emu.callstack()
        assert len(frames) == 2, f"expected 2 frames, got {frames}"

        # Frame 0 = JSL from `outer_call_jsl` to `outer` (kind 1).
        outer_call_jsl = (
            int.from_bytes(b"", "little")  # placeholder, resolved below
        )
        sym = {
            "outer_call_jsl": None,
            "outer_call_jsr": None,
            "outer":          None,
            "inner":          None,
        }
        # Resolve via the .adbg label table — same source of truth the
        # native shim uses.
        for addr in range(0x008000, 0x008300):
            name = emu.lookup_label(addr)
            if name in sym:
                sym[name] = addr
        for k, v in sym.items():
            assert v is not None, f"label {k!r} not resolved from .adbg"

        callsite0, target0, kind0 = frames[0]
        callsite1, target1, kind1 = frames[1]
        assert kind0 == 1, "outer call should be JSL (kind=1)"
        assert kind1 == 0, "inner call should be JSR (kind=0)"
        assert callsite0 == sym["outer_call_jsl"]
        assert target0   == sym["outer"]
        assert callsite1 == sym["outer_call_jsr"]
        assert target1   == sym["inner"]


def test_callstack_explicit_clear(assemble_rom):
    """`callstack_clear` drops every retained frame regardless of CPU
    state — covers the path used internally by ``kintsuki_load_state`` /
    ``kintsuki_rearm_cpu`` to keep the shadow stack consistent across
    a state swap. We skip a save/load round-trip here on purpose: the
    only state we could capture mid-test would be the post-STP halt,
    which serializing+restoring is itself unsafe (libco coroutine RIP
    would point inside instructionStop's wait loop)."""
    rom = assemble_rom("test_callstack.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        assert _run_until_stp(emu), "CPU never halted at STP"
        assert len(emu.callstack()) == 2
        emu.callstack_clear()
        assert emu.callstack() == []
