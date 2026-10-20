"""BPS sidecar: opt-in apply at load_rom, metadata surfaced by patch_info,
CRC / truncation rejects leave the ROM unpatched."""

from __future__ import annotations

import shutil
import zlib
from pathlib import Path

import pytest

from kintsuki import Emu, PatchRejectedWarning

PATCH_OFFSET = 0x10  # LoROM: ROM offset 0x10 reads back at $00:8010
PATCH_BYTES = b"\xa5\x5a"
METADATA = '<patch name="kintsuki test"/>'

SOURCE_READ, TARGET_READ = 0, 1


def _num(x: int) -> bytes:
    out = bytearray()
    while True:
        b = x & 0x7F
        x >>= 7
        if x == 0:
            out.append(0x80 | b)
            return bytes(out)
        out.append(b)
        x -= 1


def _cmd(mode: int, length: int) -> bytes:
    return _num(((length - 1) << 2) | mode)


def _make_bps(source: bytes, *, metadata: str = METADATA, source_crc: int | None = None) -> bytes:
    """Overwrite PATCH_BYTES at PATCH_OFFSET, keep the rest of `source`."""
    target = bytearray(source)
    target[PATCH_OFFSET:PATCH_OFFSET + len(PATCH_BYTES)] = PATCH_BYTES
    meta = metadata.encode()
    tail = len(source) - PATCH_OFFSET - len(PATCH_BYTES)
    body = (b"BPS1" + _num(len(source)) + _num(len(target)) + _num(len(meta)) + meta
            + _cmd(SOURCE_READ, PATCH_OFFSET)
            + _cmd(TARGET_READ, len(PATCH_BYTES)) + PATCH_BYTES
            + _cmd(SOURCE_READ, tail))
    crc = zlib.crc32(source) if source_crc is None else source_crc
    body += crc.to_bytes(4, "little") + zlib.crc32(target).to_bytes(4, "little")
    return body + zlib.crc32(body).to_bytes(4, "little")


@pytest.fixture
def rom(assemble_rom, tmp_path) -> Path:
    dst = tmp_path / "game.sfc"
    shutil.copy(assemble_rom("test_rom.s"), dst)
    return dst


def _patched(emu: Emu) -> bool:
    return bytes(emu.read(0x8010 + i) for i in range(len(PATCH_BYTES))) == PATCH_BYTES


def test_bps_ignored_by_default(rom):
    rom.with_suffix(".bps").write_bytes(_make_bps(rom.read_bytes()))
    with Emu() as emu:
        emu.load_rom(str(rom))
        assert (emu.patch_info(), _patched(emu)) == (None, False)


def test_bps_applied_when_opted_in(rom):
    rom.with_suffix(".bps").write_bytes(_make_bps(rom.read_bytes()))
    with Emu(load_bps_sidecar=True) as emu:
        emu.load_rom(str(rom))
        assert _patched(emu)


def test_bps_metadata_exposed(rom):
    bps = rom.with_suffix(".bps")
    bps.write_bytes(_make_bps(rom.read_bytes()))
    with Emu(load_bps_sidecar=True) as emu:
        emu.load_rom(str(rom))
        info = emu.patch_info()
        assert (info.kind, info.path, info.metadata, info.applied) == ("bps", str(bps), METADATA, True)


def test_bps_full_name_sidecar_preferred(rom):
    Path(str(rom) + ".bps").write_bytes(_make_bps(rom.read_bytes(), metadata="full"))
    rom.with_suffix(".bps").write_bytes(_make_bps(rom.read_bytes(), metadata="stem"))
    with Emu(load_bps_sidecar=True) as emu:
        emu.load_rom(str(rom))
        assert emu.patch_info().metadata == "full"


def test_bps_source_crc_mismatch_rejected(rom):
    rom.with_suffix(".bps").write_bytes(_make_bps(rom.read_bytes(), source_crc=0xDEADBEEF))
    with Emu(load_bps_sidecar=True) as emu:
        with pytest.warns(PatchRejectedWarning, match="source hash mismatch"):
            emu.load_rom(str(rom))
        assert _patched(emu) is False


def test_bps_truncated_rejected(rom):
    rom.with_suffix(".bps").write_bytes(_make_bps(rom.read_bytes())[:40])
    with Emu(load_bps_sidecar=True) as emu:
        with pytest.warns(PatchRejectedWarning):
            emu.load_rom(str(rom))
        assert emu.patch_info().applied is False


def test_bps_out_of_range_source_read_rejected(rom):
    source = rom.read_bytes()
    # Claims a 2x-long target built from SourceRead: reads past `source`.
    body = (b"BPS1" + _num(len(source)) + _num(len(source) * 2) + _num(0)
            + _cmd(SOURCE_READ, len(source) * 2))
    body += b"\0" * 8
    body += zlib.crc32(body).to_bytes(4, "little")
    rom.with_suffix(".bps").write_bytes(body)
    with Emu(load_bps_sidecar=True) as emu:
        with pytest.warns(PatchRejectedWarning, match="source read out of range"):
            emu.load_rom(str(rom))


def test_ips_reported_by_patch_info(rom):
    ips = b"PATCH" + PATCH_OFFSET.to_bytes(3, "big") + len(PATCH_BYTES).to_bytes(2, "big") + PATCH_BYTES + b"EOF"
    rom.with_suffix(".ips").write_bytes(ips)
    with Emu() as emu:
        emu.load_rom(str(rom))
        info = emu.patch_info()
        assert (info.kind, info.metadata, info.applied, _patched(emu)) == ("ips", "", True, True)
