"""Phase 3 — Mesen 2 ``.mss`` savestate parser.

Mesen 2 writes savestates as:

    "MSS" magic (3 bytes)
    u32 emulator version
    u32 file format version
    u32 console type
    u32 framebuf_size, u32 width, u32 height, u32 scale100
    u32 compressed_framebuf_size + zlib stream
    u32 rom_name_length + ASCII name
    [SerializeBlob]   <-- emulator state, optionally zlib-compressed:
        u8  compression_flag
        if compressed:
            u32 decompressed_size
            u32 compressed_size
            N bytes zlib data
        else:
            N bytes raw

The decompressed payload is a sequence of records:

    key (null-terminated printable ASCII)
    value_size (u32 LE)
    value_bytes

Tests synthesize a minimal in-memory file matching this format so we don't
depend on a checked-in binary blob from a specific Mesen version.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

import pytest

from kintsuki.mesen import (
    MesenHeader,
    MesenSaveState,
    parse_mesen_state,
    read_records,
)


def _make_minimal_mss(records: dict[bytes, bytes], *,
                     console_type: int = 1,
                     emulator_version: int = 0x00020101,
                     file_format_version: int = 4,
                     compress_payload: bool = True) -> bytes:
    """Build a parseable .mss byte string with the given record dict."""
    out = bytearray()
    out += b"MSS"
    out += struct.pack("<III", emulator_version, file_format_version, console_type)
    # framebuffer header (size/W/H/scale100/compressedSize) + 1-byte zlib stream
    fb_uncompressed = b""
    fb_compressed = zlib.compress(fb_uncompressed)
    out += struct.pack("<IIIII",
                       0, 0, 0, 100, len(fb_compressed))
    out += fb_compressed
    rom_name = b"unit-test.sfc"
    out += struct.pack("<I", len(rom_name))
    out += rom_name

    # Build records payload
    payload = bytearray()
    for k, v in records.items():
        payload += k + b"\x00"
        payload += struct.pack("<I", len(v))
        payload += v

    if compress_payload:
        compressed = zlib.compress(bytes(payload))
        out += b"\x01"  # compression flag
        out += struct.pack("<II", len(payload), len(compressed))
        out += compressed
    else:
        out += b"\x00"
        out += bytes(payload)
    return bytes(out)


def test_parse_minimal_mss(tmp_path: Path):
    """Header fields + record dict round-trip."""
    records = {b"cpu.a": b"\x42\x13", b"cpu.pc": b"\x00\x80\x00\x00"}
    blob = _make_minimal_mss(records)
    p = tmp_path / "minimal.mss"
    p.write_bytes(blob)

    state: MesenSaveState = parse_mesen_state(p)
    assert isinstance(state.header, MesenHeader)
    assert state.header.magic == b"MSS"
    assert state.header.file_format_version == 4
    assert state.header.console_type == 1
    assert state.rom_name == "unit-test.sfc"
    assert state.records[b"cpu.a"] == b"\x42\x13"
    assert state.records[b"cpu.pc"] == b"\x00\x80\x00\x00"


def test_parse_uncompressed_payload(tmp_path: Path):
    """Compression flag = 0 → payload bytes follow directly."""
    records = {b"x": b"\xCAFE"[:2]}
    blob = _make_minimal_mss(records, compress_payload=False)
    p = tmp_path / "uncompressed.mss"
    p.write_bytes(blob)

    state = parse_mesen_state(p)
    assert state.records == records


def test_read_records_pure_function():
    """`read_records` parses a raw decompressed payload — useful for callers
    that already have the bytes in memory."""
    payload = (
        b"alpha\x00" + struct.pack("<I", 4) + b"\x01\x02\x03\x04"
        + b"beta\x00" + struct.pack("<I", 1) + b"\xff"
    )
    out = read_records(payload)
    assert out == {b"alpha": b"\x01\x02\x03\x04", b"beta": b"\xff"}


def test_rejects_bad_magic(tmp_path: Path):
    p = tmp_path / "bad.mss"
    p.write_bytes(b"NOPE" + b"\x00" * 100)
    with pytest.raises(ValueError, match="magic"):
        parse_mesen_state(p)


def test_rejects_giant_value(tmp_path: Path):
    """Safety: refuse to allocate >10 MiB for a single record value."""
    records: dict[bytes, bytes] = {}
    blob = _make_minimal_mss(records)
    # Append a malformed record after compression flag with a giant size
    truncated = bytearray(blob[:-zlib.compress(b"").__sizeof__()])  # rough
    # easier: build a fresh malformed payload directly
    payload = b"big\x00" + struct.pack("<I", 100 * 1024 * 1024) + b"\x00" * 8
    fake = bytearray()
    fake += b"MSS" + struct.pack("<III", 0x00020101, 4, 1)
    fake += struct.pack("<IIIII", 0, 0, 0, 100, 8) + zlib.compress(b"")
    fake += struct.pack("<I", 0)
    fake += b"\x00" + payload
    p = tmp_path / "huge.mss"
    p.write_bytes(bytes(fake))
    with pytest.raises(ValueError, match="value too large"):
        parse_mesen_state(p)
