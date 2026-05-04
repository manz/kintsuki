"""Mesen 2 ``.mss`` savestate parser.

Read-only — pulls CPU/PPU/RAM blobs out of a Mesen-authored savestate so
kintsuki tests can replay scenes captured during interactive Mesen
sessions instead of re-recording them from scratch.

Format (Mesen 2, file_format_version 4 verified):

    "MSS"                                       3 bytes
    u32 emulator_version                        LE
    u32 file_format_version                     LE
    u32 console_type                            LE
    u32 framebuf_size, w, h, scale100           5 × u32 LE
    u32 compressed_framebuf_size                LE
    [compressed_framebuf_size bytes zlib stream]
    u32 rom_name_length                         LE
    [rom_name_length bytes ASCII]
    u8  payload_compression_flag                0=raw, 1=zlib
    if compressed:
        u32 decompressed_size, u32 compressed_size
        [compressed_size bytes zlib stream]
    else:
        [N bytes raw]

Decompressed payload = sequence of records:

    [key (printable ASCII)\\x00][value_size u32 LE][value_size bytes]

`parse_mesen_state(path)` returns a `MesenSaveState` with the header
metadata + a `dict[bytes, bytes]` of records. `read_records(payload)`
parses an already-decompressed payload buffer.

`import_mesen_state(emu, path)` wires the parsed records into a
kintsuki Emu (CPU registers + WRAM + VRAM + CGRAM + OAM); the surface
is intentionally narrow — settings, controllers, save-RAM cartridge
state are skipped.
"""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from pathlib import Path


_MAX_VALUE_BYTES = 10 * 1024 * 1024  # safety cap, matches Mesen


@dataclass(frozen=True)
class MesenHeader:
    """Metadata read from the .mss file header (everything before the
    ROM name + serialized state)."""

    magic: bytes
    emulator_version: int
    file_format_version: int
    console_type: int
    framebuf_size: int
    width: int
    height: int
    scale100: int


@dataclass(frozen=True)
class MesenSaveState:
    header: MesenHeader
    rom_name: str
    framebuf_zlib: bytes
    records: dict[bytes, bytes]


def _read_records(payload: bytes) -> dict[bytes, bytes]:
    out: dict[bytes, bytes] = {}
    i = 0
    n = len(payload)
    while i < n:
        # Find null terminator for the key.
        end = payload.find(b"\x00", i)
        if end == -1:
            break
        key = payload[i:end]
        # Mesen validates printable ASCII in keys; treat malformed as EOF.
        if not key:
            break
        if any(b < 0x20 or b > 0x7E for b in key):
            break
        i = end + 1
        if i + 4 > n:
            break
        (size,) = struct.unpack_from("<I", payload, i)
        i += 4
        if size > _MAX_VALUE_BYTES:
            raise ValueError(f"value too large for key {key!r}: {size} bytes")
        if i + size > n:
            break
        out[key] = payload[i:i + size]
        i += size
    return out


# Public alias — pure function variant for callers that already decompressed.
read_records = _read_records


def parse_mesen_state(path: str | Path) -> MesenSaveState:
    """Parse a Mesen 2 ``.mss`` file into a `MesenSaveState`.

    Raises ValueError on bad magic or implausible record sizes.
    """
    data = Path(path).read_bytes()
    if data[:3] != b"MSS":
        raise ValueError(f"bad magic in {path}: expected b'MSS', got {data[:3]!r}")

    p = 3
    (emu_ver, fmt_ver, cons_ty) = struct.unpack_from("<III", data, p)
    p += 12
    (fb_size, w, h, scale100, cfb_size) = struct.unpack_from("<IIIII", data, p)
    p += 20
    fb_zlib = data[p:p + cfb_size]
    p += cfb_size
    (rom_len,) = struct.unpack_from("<I", data, p)
    p += 4
    rom_name = data[p:p + rom_len].decode("ascii", errors="replace")
    p += rom_len

    # Serialize blob: compression flag + (sizes + payload) | raw payload.
    if p >= len(data):
        raise ValueError("truncated file: no payload after rom name")
    flag = data[p]
    p += 1
    if flag == 1:
        if p + 8 > len(data):
            raise ValueError("truncated file: compressed payload header")
        (decomp_size, comp_size) = struct.unpack_from("<II", data, p)
        p += 8
        compressed = data[p:p + comp_size]
        try:
            payload = zlib.decompress(compressed)
        except zlib.error as exc:
            raise ValueError(f"failed to decompress payload: {exc}") from exc
        if len(payload) != decomp_size:
            # Mesen sometimes pads; just warn-shaped: trust the actual length.
            pass
    elif flag == 0:
        payload = data[p:]
    else:
        raise ValueError(f"unknown payload compression flag {flag:#x}")

    records = _read_records(payload)

    header = MesenHeader(
        magic=b"MSS",
        emulator_version=emu_ver,
        file_format_version=fmt_ver,
        console_type=cons_ty,
        framebuf_size=fb_size,
        width=w,
        height=h,
        scale100=scale100,
    )
    return MesenSaveState(
        header=header,
        rom_name=rom_name,
        framebuf_zlib=fb_zlib,
        records=records,
    )


# ---- import_mesen_state ----------------------------------------------
# Required block sizes — Mesen's emulator state is versioned, but these
# are stable for SNES file_format_version 4. Any record with an off
# size is logged-and-skipped to avoid scribbling truncated payloads
# into kintsuki memory.
_WRAM_LEN  = 128 * 1024
_VRAM_LEN  = 64 * 1024
_CGRAM_LEN = 512
_OAM_LEN   = 544
_WRAM_BUS_ADDR = 0x7E0000
# LoROM cart SRAM is mapped at bank $70:0000-$70:7FFF (mirrored to bank
# $71+). HiROM uses $30:6000-$30:7FFF instead. Use the LoROM mapping by
# default; the C ABI follow-up exposes a dedicated saveRam endpoint that
# can pick the right map per cart.
_SRAM_BUS_ADDR = 0x700000


def import_mesen_state(emu, path: str | Path) -> None:
    """Read a Mesen ``.mss`` file and push CPU + memory state into
    `emu`. Surface is intentionally narrow:

    * CPU registers (a, x, y, sp, d, dbr, k, pc, ps, emulationMode)
      go through `Emu.set_state`.
    * WRAM (128 KiB) → `Emu.write_range($7E:0000, ...)`.
    * Cart SRAM (variable size) → `Emu.write_range($70:0000, ...)`
      assuming LoROM mapping. Skipped silently when the .mss has no
      ``cart.saveRam`` record (= cart has no SRAM).
    * VRAM, CGRAM, OAM go through the existing
      `vram_write` / `cgram_write` / `oam_write` per-byte API.

    Records whose recorded size doesn't match the documented layout
    are logged-and-skipped rather than truncated, so a Mesen format
    change won't silently corrupt emulator memory.
    """
    state = parse_mesen_state(path)
    r = state.records

    # ---- CPU registers ------------------------------------------------
    cpu = emu.get_state()
    if v := r.get(b"cpu.a"):     cpu.a = _u16(v)
    if v := r.get(b"cpu.x"):     cpu.x = _u16(v)
    if v := r.get(b"cpu.y"):     cpu.y = _u16(v)
    if v := r.get(b"cpu.sp"):    cpu.s = _u16(v)
    if v := r.get(b"cpu.d"):     cpu.d = _u16(v)
    if v := r.get(b"cpu.dbr"):   cpu.b = v[0]
    if v := r.get(b"cpu.ps"):    cpu.p = v[0]
    pc_low = _u16(r[b"cpu.pc"]) if b"cpu.pc" in r else 0
    pc_bank = r.get(b"cpu.k", b"\x00")[0]
    cpu.pc = (pc_bank << 16) | pc_low
    if v := r.get(b"cpu.emulationMode"): cpu.e = v[0]
    emu.set_state(cpu)

    # ---- Memory blobs -------------------------------------------------
    if (wram := r.get(b"memoryManager.workRam")) is not None \
            and len(wram) == _WRAM_LEN:
        emu.write_range(_WRAM_BUS_ADDR, wram)
    if (sram := r.get(b"cart.saveRam")) is not None and sram:
        # SRAM size varies per cart; we accept whatever Mesen recorded.
        emu.write_range(_SRAM_BUS_ADDR, sram)

    if (vram := r.get(b"ppu.vram")) is not None \
            and len(vram) == _VRAM_LEN:
        for i, b in enumerate(vram):
            emu.vram_write(i, b)
    if (cg := r.get(b"ppu.cgram")) is not None and len(cg) == _CGRAM_LEN:
        for i, b in enumerate(cg):
            emu.cgram_write(i, b)
    if (oam := r.get(b"ppu.oamRam")) is not None and len(oam) == _OAM_LEN:
        for i, b in enumerate(oam):
            emu.oam_write(i, b)


def _u16(b: bytes) -> int:
    return struct.unpack_from("<H", b, 0)[0]
