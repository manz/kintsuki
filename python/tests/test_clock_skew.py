"""load_state keeps the CPU in step with the PPU: HDMA writes (timed by the
CPU) land on the scanlines the PPU draws them on."""

from __future__ import annotations

import struct

from kintsuki import Emu


_CPU_FREQUENCY = 21477273


def _frame_after(state: bytes, rom: str) -> bytes:
    with Emu() as emu:
        emu.load_rom(rom)
        emu.load_state(state)
        emu.run_frames(3)
        return emu.framebuffer()[0]


def _shifted(state: bytes, cycles: int, threads: int) -> bytes:
    """The state with the clocks of its first `threads` threads at the CPU's
    frequency (the CPU, then the PPU) moved `cycles` master cycles. ares writes
    each thread as frequency, scalar, clock (u64s)."""
    out, at = bytearray(state), 0
    for _ in range(threads):
        at = state.find(struct.pack("<Q", _CPU_FREQUENCY), at)
        assert at >= 0, "thread record not found"
        scalar, clock = struct.unpack_from("<QQ", state, at + 8)
        struct.pack_into("<Q", out, at + 16, clock + cycles * scalar)
        at += 24
    return bytes(out)


def _state(rom: str) -> bytes:
    with Emu() as emu:
        emu.load_rom(rom)
        emu.run_frames(10)
        return emu.save_state()


def test_load_realigns_a_skewed_cpu_clock(assemble_rom):
    """A state whose CPU clock is off the PPU's (as an old rearm_cpu left it)
    loads with the CPU back in step: same picture as the clean state."""
    rom = str(assemble_rom("test_hdma_bands.s"))
    state = _state(rom)
    skewed = _shifted(state, 640, threads=1)
    with Emu() as emu:
        emu.load_rom(rom)
        emu.load_state(skewed)
        assert emu.clock_skew == 0
    assert _frame_after(skewed, rom) == _frame_after(state, rom)

