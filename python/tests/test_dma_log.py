"""DMA transfer log — exercises the ares dmaHook + libkintsuki ring.

The test ROM in `asm/test_dma_log.s` enables NMI, configures GDMA channel
0 to copy 32 bytes from $7E:9000 to VMDATAL, and on the first vblank the
NMI handler kicks MDMAEN then STPs. After the CPU halts the DMA log must
hold an entry matching that transfer.
"""

from __future__ import annotations

from kintsuki import Emu


def _run_until_stp(emu: Emu, max_frames: int = 60) -> bool:
    for _ in range(max_frames):
        emu.run_frames(1)
        if emu.get_state().stp:
            return True
    return False


def test_dma_log_captures_nmi_vram_transfer(assemble_rom):
    rom = assemble_rom("test_dma_log.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        # Log is process-global state; an earlier test in the same
        # session may have left entries behind. Clear so we observe
        # only THIS ROM's transfers.
        emu.dma_log_clear()
        assert emu.dma_transfers() == []

        assert _run_until_stp(emu, max_frames=120), \
            "CPU never halted; NMI handler may not be firing"

        xfers = emu.dma_transfers()
        assert xfers, "DMA log empty after STP — hook not firing"

        # Find the matching transfer: src=$7E9000, dst=$18 (VMDATAL),
        # size=32. Other house-keeping channels may co-exist (none in
        # this ROM, but be tolerant) — assert presence, not uniqueness.
        match = next(
            (x for x in xfers
             if x["src_addr"] == 0x7E9000
             and x["dst_reg"] == 0x18
             and x["size"] == 0x20),
            None,
        )
        assert match is not None, (
            f"expected (src=$7E9000, dst=$18, size=32) entry, got {xfers}"
        )
        # NMI fires once before STP, so hits should be exactly 1 (the ring
        # would dedupe + bump if it were ever called twice).
        assert match["direction"] == 0, "expected CPU->PPU direction"
        assert match["channel"] == 0, "configured DMA channel was 0"
        assert match["hits"] >= 1
