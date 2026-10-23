"""run_asm must start the stub from a clean instruction boundary. The CPU can
be parked mid-instruction when a frame ends (here inside the fixture ROM's
`bra idle`); resuming that instruction after redirecting PC would apply its
branch offset to the stub address and run off into random WRAM."""

from __future__ import annotations

from kintsuki import Emu

RESULT = 0x7E0010


def test_stub_runs_to_its_exit_every_time(assemble_rom) -> None:
    rom = str(assemble_rom("test_rom.s"))
    # sep #$20 ; lda #$5A ; sta.l RESULT
    code = bytes([0xE2, 0x20, 0xA9, 0x5A, 0x8F]) + RESULT.to_bytes(3, "little")
    for _ in range(40):
        with Emu(load_srm_sidecar=False) as e:
            e.load_rom(rom)
            e.run_frames(2)
            state = e.run_asm(code)
            assert state.pc & 0xFFFFFF == Emu.EXIT_PC
            assert e.read(RESULT) == 0x5A


def test_call_returns_from_the_routine_every_time(assemble_rom) -> None:
    rom = str(assemble_rom("test_rom.s"))
    routine = 0x7E0100
    for _ in range(40):
        with Emu(load_srm_sidecar=False) as e:
            e.load_rom(rom)
            e.run_frames(2)
            e.write_range(routine, bytes([0xA9, 0x5A, 0x00, 0x6B]))  # lda #$005A ; rtl
            assert e.call(routine).a == 0x5A
