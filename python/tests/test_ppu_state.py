"""Phase 1 — PPU register state probing.

Loads `tests/asm/test_ppu_state.s` (assembled on demand by the
`assemble_rom` fixture) which programs PPU registers + HDMA channel 5
to deterministic values, then asserts `Emu.get_ppu_state()` returns
those exact values. Self-contained — no external FF4 dependency.
"""

from __future__ import annotations

from kintsuki import Emu


def test_get_ppu_state_returns_struct():
    """Smoke: API exists, exposes documented fields, no native crash."""
    with Emu() as emu:
        p = emu.get_ppu_state()
        for fld in ("bgmode", "bg3vofs", "bg3sc", "tm", "ts", "hdmaen", "dma"):
            assert hasattr(p, fld), f"PpuState missing field {fld}"
        assert len(p.dma) == 8, "expect 8 DMA channels"
        ch = p.dma[5]
        for fld in ("ctrl", "dest", "src_addr", "src_bank", "enabled"):
            assert hasattr(ch, fld), f"DMA channel missing {fld}"


def test_ppu_state_after_test_rom_setup(assemble_rom):
    """The test ROM sets BGMODE=$01, BG3SC=$70, TM=$07, BG3VOFS=$1234, and
    configures DMA channel 5 registers (DMAP5=$02, BBAD5=$12, A1T5=$9800,
    A1B5=$7E) without enabling the HDMAEN bit. Snapshot must reflect each
    value after the ROM has run far enough for those writes to settle."""
    rom = assemble_rom("test_ppu_state.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.run_frames(30)
        p = emu.get_ppu_state()
        assert p.bgmode == 0x01, f"BGMODE want $01 got ${p.bgmode:02X}"
        assert p.bg3sc == 0x70, f"BG3SC want $70 got ${p.bg3sc:02X}"
        assert p.tm == 0x07, f"TM want $07 (BG1+2+3) got ${p.tm:02X}"
        assert p.bg3vofs == 0x1234, f"BG3VOFS want $1234 got ${p.bg3vofs:04X}"
        # DMA channel 5 registers — configured but not HDMA-enabled
        ch5 = p.dma[5]
        assert ch5.ctrl == 0x02, f"DMAP5 want $02 got ${ch5.ctrl:02X}"
        assert ch5.dest == 0x12, f"BBAD5 want $12 got ${ch5.dest:02X}"
        assert ch5.src_addr == 0x9800, f"A1T5 want $9800 got ${ch5.src_addr:04X}"
        assert ch5.src_bank == 0x7E, f"A1B5 want $7E got ${ch5.src_bank:02X}"
        # HDMAEN not enabled in this ROM: bit 5 must be clear.
        assert (p.hdmaen & 0x20) == 0, f"HDMAEN bit5 unexpectedly set: ${p.hdmaen:02X}"
        assert ch5.enabled == 0, "ch5.enabled should mirror HDMAEN bit (off)"


def test_ppu_state_field_ranges(assemble_rom):
    """All bytes are within u8/u16; no garbage from struct copy overrun."""
    rom = assemble_rom("test_ppu_state.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.run_frames(30)
        p = emu.get_ppu_state()
        for u8 in (p.bgmode, p.tm, p.ts, p.tmw, p.tsw, p.hdmaen, p.mdmaen,
                   p.bg1sc, p.bg2sc, p.bg3sc, p.bg4sc):
            assert 0 <= u8 <= 0xFF
        for u16 in (p.bg1hofs, p.bg1vofs, p.bg2hofs, p.bg2vofs,
                    p.bg3hofs, p.bg3vofs, p.bg4hofs, p.bg4vofs):
            assert 0 <= u16 <= 0xFFFF
        for ch in p.dma:
            assert 0 <= ch.ctrl <= 0xFF
            assert 0 <= ch.dest <= 0xFF
            assert 0 <= ch.src_addr <= 0xFFFF
            assert 0 <= ch.src_bank <= 0xFF
            assert ch.enabled in (0, 1)
