"""State snapshot + structural diff.

`snapshot(emu)` captures CPU + PPU + memory blobs into an immutable
`StateSnapshot`. `diff(a, b)` produces a unified-diff-style text report
listing only fields that differ — surfaces the smallest set of
register / memory differences that explain a divergence between two
emulator runs (e.g. "field menu after scroll" vs "treasure menu after
scroll").

Snapshot scope:
- CPU register dump (whatever `Emu.get_state()` returns)
- PPU register dump (`Emu.get_ppu_state()`)
- WRAM bytes ($7E:0000..$80:0000 = 128 KiB)
- VRAM bytes (64 KiB)
- CGRAM bytes (512 B)
- OAM bytes (544 B)

Memory blobs intentionally compared as opaque bytes — diff() reports
"vram differs in N bytes" rather than dumping the contents. Callers who
need byte-level inspection use `emu.read_range()` / `vram_dump()`
directly.
"""

from __future__ import annotations

from dataclasses import dataclass, fields, is_dataclass
from typing import Any


_WRAM_LEN = 128 * 1024
_VRAM_LEN = 64 * 1024
_CGRAM_LEN = 512
_OAM_LEN = 544


@dataclass(frozen=True)
class StateSnapshot:
    cpu: Any        # whatever Emu.get_state() returns (CpuState / dataclass)
    ppu: Any        # PpuState
    wram: bytes
    vram: bytes
    cgram: bytes
    oam: bytes


def snapshot(emu: Any) -> StateSnapshot:
    """Capture a `StateSnapshot` from `emu`. Memory dumps fall back to
    per-byte reads if a `_dump` bulk function isn't exposed."""
    cpu = emu.get_state()
    ppu = emu.get_ppu_state()
    wram = _read_block(emu, 0x7E0000, _WRAM_LEN, kind="cpu")
    vram = _read_block(emu, 0, _VRAM_LEN, kind="vram")
    cgram = _read_block(emu, 0, _CGRAM_LEN, kind="cgram")
    oam = _read_block(emu, 0, _OAM_LEN, kind="oam")
    return StateSnapshot(cpu=cpu, ppu=ppu,
                         wram=wram, vram=vram, cgram=cgram, oam=oam)


def _read_block(emu: Any, base: int, length: int, *, kind: str) -> bytes:
    """Try the bulk-dump path; fall back to per-byte reads."""
    if kind == "cpu" and hasattr(emu, "read_range"):
        return emu.read_range(base, length)
    bulk_name = f"{kind}_dump"
    if hasattr(emu, bulk_name):
        return bytes(getattr(emu, bulk_name)())
    per_byte = f"{kind}_read"
    if not hasattr(emu, per_byte):
        return b""
    fn = getattr(emu, per_byte)
    return bytes(fn(base + i) for i in range(length))


# ---- diff ------------------------------------------------------------
def diff(a: StateSnapshot, b: StateSnapshot) -> str:
    """Compare two snapshots; return a unified-diff-style text report
    listing only fields that differ. Empty string when `a == b`."""
    out: list[str] = []
    out.extend(_diff_struct("cpu", a.cpu, b.cpu))
    out.extend(_diff_struct("ppu", a.ppu, b.ppu))
    out.extend(_diff_blob("wram", a.wram, b.wram))
    out.extend(_diff_blob("vram", a.vram, b.vram))
    out.extend(_diff_blob("cgram", a.cgram, b.cgram))
    out.extend(_diff_blob("oam", a.oam, b.oam))
    return "\n".join(out)


def _diff_struct(prefix: str, a: Any, b: Any) -> list[str]:
    """Field-by-field compare for dataclass-like objects with public attrs."""
    out: list[str] = []
    names = _public_attr_names(a)
    for name in names:
        va = getattr(a, name, None)
        vb = getattr(b, name, None)
        # Recurse through nested dataclasses (e.g., DmaChannelState).
        if is_dataclass(va) and is_dataclass(vb):
            out.extend(_diff_struct(f"{prefix}.{name}", va, vb))
            continue
        if isinstance(va, tuple) and isinstance(vb, tuple) and \
           va and vb and is_dataclass(va[0]):
            for i, (xa, xb) in enumerate(zip(va, vb)):
                out.extend(_diff_struct(f"{prefix}.{name}[{i}]", xa, xb))
            continue
        if va != vb:
            out.append(f"- {prefix}.{name}: {_fmt(va)}")
            out.append(f"+ {prefix}.{name}: {_fmt(vb)}")
    return out


def _public_attr_names(obj: Any) -> list[str]:
    if is_dataclass(obj):
        return [f.name for f in fields(obj)]
    return [n for n in dir(obj)
            if not n.startswith("_") and not callable(getattr(obj, n, None))]


def _fmt(v: Any) -> str:
    if isinstance(v, int):
        return f"{v} (0x{v:X})" if v >= 0 else str(v)
    return repr(v)


def _diff_blob(name: str, a: bytes, b: bytes) -> list[str]:
    if a == b:
        return []
    if len(a) != len(b):
        return [f"~ {name}: size {len(a)} vs {len(b)} bytes (differ)"]
    differing = sum(1 for x, y in zip(a, b) if x != y)
    return [f"~ {name}: {differing} byte(s) differ (of {len(a)})"]
