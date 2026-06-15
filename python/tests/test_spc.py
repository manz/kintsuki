"""SPC700 + S-DSP inspection from Python. Boots the audio core ROM-free,
installs a tiny SPC700 program into ARAM, runs it, and reads back register
and DSP state."""

from __future__ import annotations

from kintsuki import Emu


def test_spc_boot_and_state():
    with Emu() as emu:
        emu.spc_boot()
        st = emu.spc_state()
        # Registers are readable; SP/PC are real values (no exception).
        assert 0 <= st.pc <= 0xFFFF
        assert 0 <= st.a <= 0xFF
        assert isinstance(st.c, bool)
        assert st.ya == (st.y << 8) | st.a


def test_aram_roundtrip():
    with Emu() as emu:
        emu.spc_boot()
        emu.aram_write(0x4000, bytes([0xDE, 0xAD, 0xBE, 0xEF]))
        assert bytes(emu.aram_read(0x4000, 4)) == bytes([0xDE, 0xAD, 0xBE, 0xEF])
        # Full dump is 64 KB.
        assert len(emu.aram_read()) == 0x10000


def test_dsp_register_decode_shape():
    with Emu() as emu:
        emu.spc_boot()
        regs = emu.dsp_registers()
        assert len(regs) == 128
        voices = emu.dsp_voices(regs)
        assert len(voices) == 8
        assert [v.index for v in voices] == list(range(8))
        g = emu.dsp_global(regs)
        assert len(g.fir) == 8
        assert -128 <= g.main_vol_l <= 127


def test_spc_program_sets_dsp_register():
    # SPC700 program @ $0400: write $7F to DSP MVOLL ($0C) via the $F2/$F3
    # DSP address/data ports, then spin.
    program = bytes([
        0xE8, 0x0C,   # MOV A,#$0C        ; DSP addr = MVOLL
        0xC4, 0xF2,   # MOV $F2,A
        0xE8, 0x7F,   # MOV A,#$7F        ; value
        0xC4, 0xF3,   # MOV $F3,A         ; DSP data -> MVOLL
        0x2F, 0xFE,   # BRA *             ; spin
    ])
    with Emu() as emu:
        emu.spc_boot()
        emu.enable_audio()                # spc_run_samples needs a sink
        emu.aram_write(0x0400, program)
        emu.spc_set_pc(0x0400)
        emu.spc_run_samples(64)           # plenty for ~5 instructions
        assert emu.dsp_global().main_vol_l == 0x7F
        # PC is parked on the spin (BRA at $0408); a run can stop mid-
        # instruction, so accept the opcode or its operand byte.
        assert emu.spc_state().pc in (0x0408, 0x0409)
