"""Kintsuki project file — slice 1 smoke test.

Reuses the test_dma_log ROM (NMI -> GDMA from $7E:9000 to VMDATAL, 32
bytes, then STP) as a known-shape workload that exercises both auto-
classification paths:

1. Exec marks: CPU runs through the reset stub + NMI handler before STP.
   We expect at least *some* bytes of the ROM to be tagged CODE.
2. DMA marks: the channel copies 32 bytes from WRAM ($7E:9000) into VRAM
   via $2118. Source is WRAM not ROM, so map.bin stays untouched there —
   but the previous DMA hook still fires. To get a ROM-source DMA we
   additionally do a manual mark via project_mark + assert round-trip.

Slice 1 keeps expectations loose: existence + persistence + round-trip,
not byte-for-byte coverage (which depends on the exact program path).
"""

from __future__ import annotations

from kintsuki import Emu
from kintsuki._native import (
    BYTE_CLASS_MASK,
    BYTE_CODE,
    BYTE_DATA,
    BYTE_USER_STICKY,
)


def _run_until_stp(emu: Emu, max_frames: int = 120) -> bool:
    for _ in range(max_frames):
        emu.run_frames(1)
        if emu.get_state().stp:
            return True
    return False


def test_project_open_save_reload(assemble_rom, tmp_path):
    rom = assemble_rom("test_dma_log.s")
    project_dir = tmp_path / "test_dma_log.kintsuki"

    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.project_open(project_dir)
        assert emu.project_is_open()

        # Run the test program to populate map.bin via the exec hook.
        assert _run_until_stp(emu)

        stats = emu.project_stats()
        assert stats is not None
        assert stats["total"] > 0, "rom_size must be non-zero"
        assert stats["code"] > 0, "exec hook never marked any byte as CODE"

        # Manual mark survives across save + reopen.
        emu.project_mark(0x1000, 16, BYTE_DATA, user_sticky=True)
        emu.project_mark(0x2000, 8, BYTE_CODE, user_sticky=False)

        assert emu.project_save()
        emu.project_close()
        assert not emu.project_is_open()

    # Reopen against the same project dir w/ a fresh emu — pristine sha
    # check should pass, manual marks should round-trip.
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.project_open(project_dir)

        # User-sticky mark survived.
        b = emu.project_classify(0x1000)
        assert b & BYTE_USER_STICKY, f"sticky bit lost at $1000 (raw={b:#x})"
        assert b & BYTE_CLASS_MASK == BYTE_DATA
        # Auto mark survived too.
        assert emu.project_classify(0x2000) & BYTE_CLASS_MASK == BYTE_CODE

        # Files written.
        assert (project_dir / "project.toml").exists()
        assert (project_dir / "map.bin").exists()
        assert (project_dir / "manifest.bml").exists()


def test_project_bus_to_rom_lorom_hirom(assemble_rom, tmp_path):
    rom = assemble_rom("test_dma_log.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.project_open(tmp_path / "p.kintsuki")
        # Reset vector lives at $00:FFFC; in LoROM that's ROM offset
        # $7FFC. In HiROM it's $FFFC. The test ROM is LoROM (a816
        # default for `-f sfc`).
        off = emu.project_bus_to_rom(0x00FFFC)
        assert off is not None
        assert off in (0x7FFC, 0xFFFC), f"unexpected mapping: {off:#x}"


def test_project_labels_roundtrip(assemble_rom, tmp_path):
    rom = assemble_rom("test_dma_log.s")
    project_dir = tmp_path / "p.kintsuki"

    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.project_open(project_dir)

        # Manual set with all fields.
        emu.project_label_set(0x008000, "Reset",
                              type="function",
                              comment="cold boot entry",
                              m=1, x=1, e=1)
        # Sparse — name only.
        emu.project_label_set(0x00C000, "MainLoop")

        L = emu.project_label_get(0x008000)
        assert L is not None
        assert L["name"] == "Reset"
        assert L["type"] == "function"
        assert L["comment"] == "cold boot entry"
        assert L["m"] == 1 and L["x"] == 1 and L["e"] == 1

        L2 = emu.project_label_get(0x00C000)
        assert L2 is not None
        assert L2["name"] == "MainLoop"
        assert L2["m"] is None and L2["x"] is None and L2["e"] is None

        # Snapshot is address-ascending.
        all_labels = emu.project_labels()
        names = [x["name"] for x in all_labels]
        assert "Reset" in names and "MainLoop" in names
        assert all_labels[0]["addr"] <= all_labels[-1]["addr"]

        # Clear removes the entry.
        emu.project_label_clear(0x00C000)
        assert emu.project_label_get(0x00C000) is None

        emu.project_save()
        emu.project_close()

    # Reopen — overlay must survive on-disk roundtrip.
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.project_open(project_dir)
        L = emu.project_label_get(0x008000)
        assert L is not None
        assert L["name"] == "Reset"
        assert L["m"] == 1 and L["e"] == 1
        # Cleared entry stays gone.
        assert emu.project_label_get(0x00C000) is None
        # Sidecar file on disk.
        assert (project_dir / "labels.tsv").exists()


def test_project_entry_flags_auto_seeded(assemble_rom, tmp_path):
    """Shadow-callstack JSR/JSL hook records live M/X/E on the target so
    cold-cache disasm at any reached function knows the caller's flags."""
    rom = assemble_rom("test_dma_log.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.project_open(tmp_path / "p.kintsuki")
        # Run far enough for the reset stub + NMI handler to JSR somewhere.
        for _ in range(60):
            emu.run_frames(1)
            if emu.get_state().stp:
                break
        # The test ROM doesn't necessarily JSR anywhere, so this is a
        # weak assertion — we only care that the hook ran without
        # crashing and that *if* any labels were seeded, their flags are
        # well-formed (0/1, not garbage).
        for L in emu.project_labels():
            for f in ("m", "x", "e"):
                v = L[f]
                assert v is None or v in (0, 1), f"bad {f}={v} at {L['addr']:#x}"


def test_project_mark_dump_roundtrip(assemble_rom, tmp_path):
    rom = assemble_rom("test_dma_log.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.project_open(tmp_path / "p.kintsuki")
        emu.project_mark(0, 4, BYTE_CODE, user_sticky=True)
        m = emu.project_map_dump()
        assert len(m) > 0
        for i in range(4):
            assert m[i] == BYTE_CODE | BYTE_USER_STICKY, \
                f"offset {i}: expected code|sticky, got {m[i]:#x}"
