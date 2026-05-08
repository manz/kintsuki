"""Read kintsuki crash dumps (`.kcr`) for post-mortem reproducers.

A `.kcr` file captures the rewind ring, crash CPU snapshot, and shadow
callstack at the instant the live emulator hit STP. Use this module to
load a dump, seek to any retained frame, and drive the emulator
deterministically through the pre-crash trajectory:

    from kintsuki import Emu
    from kintsuki.crash import CrashDump

    dump = CrashDump.read("/path/to/foo-20260508.kcr")
    emu = Emu()
    emu.load_rom(dump.rom_path)
    dump.seek(emu, frame_idx=dump.frame_count - 1)   # last frame == crash
    print(f"PC at crash: {dump.crash_pc:06X}")
    for _ in range(5):
        emu.step()
        s = emu.cpu_state()
        print(f"  {s.pc:06X}")

Format mirrors `app/Sources/Kintsuki/CrashDump.swift`. LZ4-compressed
delta frames require the `lz4` package; pure-Python fallback handles
the uncompressed-raw frames the Swift writer falls back to when LZ4
yields no win.
"""
from __future__ import annotations

import json
import os
import struct
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from kintsuki import Emu

_MAGIC = b"KCR1"
_VERSION = 1
_KEYFRAME = 0
_DELTA = 1


@dataclass(frozen=True)
class CpuSnapshot:
    """CPU register snapshot recorded at the crash site."""

    a: int
    x: int
    y: int
    s: int
    d: int
    b: int
    p: int
    pc: int
    e: bool
    stp: bool
    wai: bool


@dataclass
class _Frame:
    kind: int                # 0 keyframe, 1 delta
    bytes_: bytes = b""      # keyframe payload OR delta compressed blob
    kf_index: int = -1       # only meaningful for delta


@dataclass
class CrashDump:
    """Decoded `.kcr` file. Frames are stored in their original
    keyframe/delta form so per-frame `seek` only decompresses the one
    delta the caller asked for."""

    rom_path: str
    rom_sha256: bytes
    adbg_sha256: bytes | None
    keyframe_interval: int
    capacity: int
    crash_pc: int
    crash_cpu: CpuSnapshot
    backtrace: list[dict[str, Any]] = field(default_factory=list)
    _frames: list[_Frame] = field(default_factory=list, repr=False)

    @property
    def frame_count(self) -> int:
        return len(self._frames)

    # ---------------------------------------------------------------- Read
    @classmethod
    def read(cls, path: str | os.PathLike) -> "CrashDump":
        with open(path, "rb") as f:
            blob = f.read()
        cur = 0

        def u8() -> int:
            nonlocal cur
            v = blob[cur]; cur += 1; return v

        def u32() -> int:
            nonlocal cur
            (v,) = struct.unpack_from("<I", blob, cur)
            cur += 4
            return v

        def take(n: int) -> bytes:
            nonlocal cur
            v = blob[cur:cur + n]; cur += n
            if len(v) != n:
                raise ValueError("truncated .kcr file")
            return v

        if take(4) != _MAGIC:
            raise ValueError("bad .kcr magic")
        version = u32()
        if version != _VERSION:
            raise ValueError(f"unsupported .kcr version {version}")
        rom_hash = take(32)
        adbg_hash = take(32)
        rom_path_len = u32()
        rom_path = take(rom_path_len).decode("utf-8", errors="replace")
        kfi = u32()
        cap = u32()
        crash_pc = u32()
        cpu = _read_cpu_blob(take(32))
        bt_len = u32()
        bt_json = take(bt_len)
        backtrace = json.loads(bt_json.decode("utf-8")) if bt_json else []
        n = u32()
        frames: list[_Frame] = []
        for _ in range(n):
            kind = u8()
            if kind == _KEYFRAME:
                length = u32()
                frames.append(_Frame(kind=_KEYFRAME, bytes_=take(length)))
            elif kind == _DELTA:
                kfi_idx = u32()
                cl = u32()
                frames.append(_Frame(kind=_DELTA, bytes_=take(cl),
                                     kf_index=kfi_idx))
            else:
                raise ValueError(f"unknown frame kind {kind}")
        return cls(
            rom_path=rom_path,
            rom_sha256=rom_hash,
            adbg_sha256=None if adbg_hash == b"\x00" * 32 else adbg_hash,
            keyframe_interval=kfi,
            capacity=cap,
            crash_pc=crash_pc,
            crash_cpu=cpu,
            backtrace=backtrace,
            _frames=frames,
        )

    # ---------------------------------------------------------- Materialize
    def materialize(self, frame_idx: int) -> bytes:
        """Reconstruct the full savestate for `frame_idx`. Keyframes
        return their stored bytes verbatim; deltas decompress + XOR
        against their owning keyframe."""
        if not 0 <= frame_idx < self.frame_count:
            raise IndexError(f"frame {frame_idx} out of range")
        f = self._frames[frame_idx]
        if f.kind == _KEYFRAME:
            return f.bytes_
        # Delta: decompress XOR diff, XOR against the keyframe's bytes.
        kf = self._frames[f.kf_index]
        if kf.kind != _KEYFRAME:
            raise ValueError(
                f"delta {frame_idx} references non-keyframe {f.kf_index}"
            )
        diff = _decompress_lz4_prefixed(f.bytes_)
        base = kf.bytes_
        n = min(len(base), len(diff))
        out = bytearray(max(len(base), len(diff)))
        a = base
        b = diff
        for i in range(n):
            out[i] = a[i] ^ b[i]
        # Tail: whichever side is longer, copy through.
        if len(diff) > n:
            out[n:] = diff[n:]
        elif len(base) > n:
            out[n:] = base[n:]
        return bytes(out)

    def seek(self, emu: "Emu", frame_idx: int) -> None:
        """Restore frame `frame_idx` into the live emulator. Caller is
        responsible for `load_rom`'ing the same ROM beforehand
        (typically via `dump.rom_path`)."""
        emu.load_state(self.materialize(frame_idx))


# ---------- helpers ----------

def _read_cpu_blob(blob: bytes) -> CpuSnapshot:
    a, x, y, s, d = struct.unpack_from("<HHHHH", blob, 0)
    b, p = blob[10], blob[11]
    (pc,) = struct.unpack_from("<I", blob, 12)
    e, stp, wai = blob[16], blob[17], blob[18]
    return CpuSnapshot(a=a, x=x, y=y, s=s, d=d, b=b, p=p, pc=pc,
                       e=bool(e), stp=bool(stp), wai=bool(wai))


def _decompress_lz4_prefixed(blob: bytes) -> bytes:
    """Mirror RewindBuffer's compressed payload prefix: u32 LE where the
    low 31 bits are the uncompressed size and the top bit signals 'no
    compression — payload is raw'."""
    (header,) = struct.unpack_from("<I", blob, 0)
    size = header & 0x7FFF_FFFF
    is_raw = (header & 0x8000_0000) != 0
    payload = blob[4:]
    if is_raw:
        return payload[:size]
    try:
        import lz4.block as _lz4
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "delta frame requires the `lz4` package; "
            "install it (`pip install lz4`) or only seek to keyframes"
        ) from exc
    return _lz4.decompress(payload, uncompressed_size=size)


__all__ = ["CrashDump", "CpuSnapshot"]
