"""Stdlib + numpy PNG decoder for kintsuki.visual.

Covers the subset we actually read: 8-bit RGB (color type 2), 8-bit
RGBA (color type 6), and 8-bit palette (color type 3) with optional
tRNS. Non-interlaced only. Any PNG written by this project's own
``kintsuki.recorder._encode_png_rgba`` or the C ``stbi_write_png`` path
round-trips.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

_SIG = b"\x89PNG\r\n\x1a\n"


def decode_rgba(path: str | Path) -> NDArray[np.uint8]:
    """Decode a PNG into a ``(height, width, 4)`` uint8 RGBA array.

    RGB sources get alpha=255 appended. Palettized sources resolve
    through PLTE + tRNS when present (missing tRNS entries => 255).
    """
    data = Path(path).read_bytes()
    if data[:8] != _SIG:
        raise ValueError("not a PNG")

    off = 8
    ihdr = None
    plte: bytes | None = None
    trns: bytes | None = None
    idat_parts: list[bytes] = []
    while off < len(data):
        length = struct.unpack(">I", data[off:off + 4])[0]
        kind = data[off + 4:off + 8]
        payload = data[off + 8:off + 8 + length]
        off += 8 + length + 4  # skip trailing CRC
        if kind == b"IHDR":
            ihdr = payload
        elif kind == b"PLTE":
            plte = payload
        elif kind == b"tRNS":
            trns = payload
        elif kind == b"IDAT":
            idat_parts.append(payload)
        elif kind == b"IEND":
            break

    if ihdr is None:
        raise ValueError("PNG missing IHDR")
    width, height, bit_depth, color_type, _comp, _filt, interlace = struct.unpack(
        ">IIBBBBB", ihdr)
    if bit_depth != 8:
        raise ValueError(f"only 8-bit PNGs supported, got depth={bit_depth}")
    if interlace != 0:
        raise ValueError("interlaced PNGs not supported")
    if color_type not in (2, 3, 6):
        raise ValueError(f"color type {color_type} not supported")

    channels_in = {2: 3, 3: 1, 6: 4}[color_type]
    raw = zlib.decompress(b"".join(idat_parts))
    stride = width * channels_in
    expected = (stride + 1) * height
    if len(raw) != expected:
        raise ValueError(
            f"IDAT size mismatch: got {len(raw)}, want {expected}")

    pixels = _unfilter(raw, height, stride, channels_in)
    arr = np.frombuffer(pixels, dtype=np.uint8).reshape(height, width, channels_in)

    if color_type == 6:
        return arr.copy()
    if color_type == 2:
        out = np.empty((height, width, 4), dtype=np.uint8)
        out[..., :3] = arr
        out[..., 3] = 255
        return out
    # Palette: resolve indices through PLTE and optional tRNS.
    if plte is None:
        raise ValueError("palette PNG missing PLTE chunk")
    palette = np.frombuffer(plte, dtype=np.uint8).reshape(-1, 3)
    alpha_lut = np.full(len(palette), 255, dtype=np.uint8)
    if trns is not None:
        n = min(len(trns), len(alpha_lut))
        alpha_lut[:n] = np.frombuffer(trns, dtype=np.uint8)[:n]
    idx = arr[..., 0]
    out = np.empty((height, width, 4), dtype=np.uint8)
    out[..., :3] = palette[idx]
    out[..., 3] = alpha_lut[idx]
    return out


def _unfilter(raw: bytes, height: int, stride: int, bpp: int) -> bytes:
    """Walk the per-row filter bytes and reconstruct the scanlines.

    PNG filter spec: each scanline carries a leading byte selecting one
    of five reconstructions against the prior scanline (Up/Average/Paeth
    look at the row above; Sub/Paeth look back by ``bpp`` bytes within
    the current row). We decode in-place into one output buffer.
    """
    out = bytearray(height * stride)
    prev_start = -stride  # points one row before the output buffer start
    src = 0
    for y in range(height):
        filter_type = raw[src]
        src += 1
        dst_start = y * stride
        row = raw[src:src + stride]
        src += stride
        if filter_type == 0:
            out[dst_start:dst_start + stride] = row
        elif filter_type == 1:  # Sub
            for i in range(stride):
                left = out[dst_start + i - bpp] if i >= bpp else 0
                out[dst_start + i] = (row[i] + left) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                up = out[prev_start + i] if prev_start >= 0 else 0
                out[dst_start + i] = (row[i] + up) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = out[dst_start + i - bpp] if i >= bpp else 0
                up = out[prev_start + i] if prev_start >= 0 else 0
                out[dst_start + i] = (row[i] + (left + up) // 2) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = out[dst_start + i - bpp] if i >= bpp else 0
                up = out[prev_start + i] if prev_start >= 0 else 0
                up_left = (out[prev_start + i - bpp]
                           if prev_start >= 0 and i >= bpp else 0)
                out[dst_start + i] = (row[i] + _paeth(left, up, up_left)) & 0xFF
        else:
            raise ValueError(f"unknown PNG filter type {filter_type}")
        prev_start = dst_start
    return bytes(out)


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c
