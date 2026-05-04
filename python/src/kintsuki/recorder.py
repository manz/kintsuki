"""Frame ring buffer + failure-dump helper.

`FrameRecorder` snapshots the framebuffer once per logical step into a
bounded ring (last N frames). On test failure, `dump_pngs(dir)` writes
every retained frame as a PNG so investigators can scrub them without
re-running the test.

Capture is cheap: snapshots store the raw RGBA buffer + dimensions
returned by ``Emu.framebuffer()``. PNG encoding only happens at dump
time, via a tiny stdlib-only encoder (zlib + handcrafted IHDR/IDAT/IEND
chunks — no Pillow dep).

The plan calls for an autouse pytest fixture that wires this on every
test; that fixture lives next to the user code that owns the ROM-running
emulator (later phases). This module provides the building block.
"""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


class _EmuLike(Protocol):
    def framebuffer(self) -> tuple[bytes, int, int]: ...


@dataclass(frozen=True)
class FrameSnapshot:
    """One captured frame: raw RGBA bytes + dimensions."""

    rgba: bytes
    width: int
    height: int


class FrameRecorder:
    """Bounded ring of framebuffer snapshots."""

    def __init__(self, capacity: int) -> None:
        if capacity < 1:
            raise ValueError(f"capacity must be >= 1, got {capacity}")
        self._cap = capacity
        self._buf: list[FrameSnapshot] = []

    @property
    def capacity(self) -> int:
        return self._cap

    def capture(self, emu: _EmuLike) -> None:
        """Snapshot the current framebuffer. No-op if the framebuffer is
        empty (Mesen returns (b'', 0, 0) before any frame is rendered)."""
        rgba, w, h = emu.framebuffer()
        if not rgba or w == 0 or h == 0:
            return
        snap = FrameSnapshot(rgba=rgba, width=w, height=h)
        self._buf.append(snap)
        # Evict oldest until under cap.
        while len(self._buf) > self._cap:
            self._buf.pop(0)

    def snapshots(self) -> list[FrameSnapshot]:
        """All retained snapshots in capture order (oldest first)."""
        return list(self._buf)

    def clear(self) -> None:
        self._buf.clear()

    def dump_pngs(self, out_dir: str | Path) -> list[Path]:
        """Write every retained snapshot as `frame_NNN.png` into `out_dir`.
        Filenames are zero-padded for natural sort order. Returns the
        list of written paths."""
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        paths: list[Path] = []
        width = max(3, len(str(len(self._buf))))
        for i, snap in enumerate(self._buf):
            p = out_dir / f"frame_{i:0{width}d}.png"
            p.write_bytes(_encode_png_rgba(snap.rgba, snap.width, snap.height))
            paths.append(p)
        return paths


# ---- Stdlib-only PNG encoder ---------------------------------------------
def _encode_png_rgba(rgba: bytes, width: int, height: int) -> bytes:
    """Encode an RGBA buffer as a PNG. RGBA layout = 4 bytes per pixel,
    row-major. No interlace, filter byte 0 ('None') per row."""
    expected = width * height * 4
    if len(rgba) != expected:
        raise ValueError(
            f"rgba buffer size mismatch: got {len(rgba)}, expected {expected}")
    sig = b"\x89PNG\r\n\x1a\n"
    # IHDR: width, height, bit depth=8, colour type=6 (RGBA), 0,0,0
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)

    # Build raw image stream with per-row filter byte.
    row_bytes = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw += rgba[y * row_bytes:(y + 1) * row_bytes]
    idat = zlib.compress(bytes(raw), level=6)

    return sig + _png_chunk(b"IHDR", ihdr) + _png_chunk(b"IDAT", idat) \
        + _png_chunk(b"IEND", b"")


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(kind + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)
