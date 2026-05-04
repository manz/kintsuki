"""Phase 4f — state snapshot + structural diff.

`snapshot(emu)` captures CPU + PPU + memory blobs into a `StateSnapshot`
so two scenarios (e.g. "field menu after scroll" vs "treasure menu
after scroll") can be compared structurally. `diff(a, b)` produces a
text report showing only fields that differ — surfaces the smallest
set of register / memory differences that explain a divergence.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from kintsuki.diff import StateSnapshot, snapshot, diff


# ---- Stub Emu surface --------------------------------------------------
@dataclass
class _Cpu:
    a: int = 0
    pc: int = 0
    p: int = 0


@dataclass
class _Ch:
    ctrl: int = 0
    dest: int = 0
    src_addr: int = 0
    src_bank: int = 0
    enabled: int = 0


@dataclass
class _Ppu:
    bgmode: int = 0
    tm: int = 0
    bg3vofs: int = 0
    dma: tuple = ()


class _FakeEmu:
    def __init__(self, cpu: _Cpu, ppu: _Ppu, *, vram_byte: int = 0,
                 cgram_byte: int = 0, oam_byte: int = 0,
                 wram_byte: int = 0) -> None:
        self._cpu = cpu
        self._ppu = ppu
        self._vram = vram_byte
        self._cgram = cgram_byte
        self._oam = oam_byte
        self._wram = wram_byte

    def get_state(self) -> _Cpu:
        return self._cpu

    def get_ppu_state(self) -> _Ppu:
        return self._ppu

    def read_range(self, addr: int, length: int) -> bytes:
        return bytes([self._wram] * length)

    def vram_read(self, addr: int) -> int:
        return self._vram

    def cgram_read(self, addr: int) -> int:
        return self._cgram

    def oam_read(self, addr: int) -> int:
        return self._oam


def _make_emu(*, a: int = 0, pc: int = 0, p: int = 0,
              bgmode: int = 0, tm: int = 0, bg3vofs: int = 0,
              vram: int = 0, cgram: int = 0, oam: int = 0,
              wram: int = 0) -> _FakeEmu:
    return _FakeEmu(
        cpu=_Cpu(a=a, pc=pc, p=p),
        ppu=_Ppu(bgmode=bgmode, tm=tm, bg3vofs=bg3vofs,
                 dma=tuple(_Ch() for _ in range(8))),
        vram_byte=vram, cgram_byte=cgram, oam_byte=oam, wram_byte=wram,
    )


def test_snapshot_captures_cpu_ppu_memory():
    emu = _make_emu(a=0x1234, pc=0x008000, bgmode=1, tm=0x07,
                    bg3vofs=0xFF88, vram=0x42)
    s = snapshot(emu)
    assert isinstance(s, StateSnapshot)
    assert s.cpu.a == 0x1234
    assert s.cpu.pc == 0x008000
    assert s.ppu.bgmode == 1
    assert s.ppu.tm == 0x07
    assert s.ppu.bg3vofs == 0xFF88
    # Memory dumps are bytes-typed and non-empty.
    assert isinstance(s.vram, (bytes, bytearray))
    assert isinstance(s.cgram, (bytes, bytearray))
    assert isinstance(s.oam, (bytes, bytearray))


def test_diff_identical_snapshots_empty():
    a = snapshot(_make_emu(a=0x10, bgmode=1, tm=0x07))
    b = snapshot(_make_emu(a=0x10, bgmode=1, tm=0x07))
    out = diff(a, b)
    assert out == "", f"identical states should diff to empty, got {out!r}"


def test_diff_lists_changed_fields():
    a = snapshot(_make_emu(a=0x10, bgmode=1, tm=0x07, bg3vofs=0xFF88))
    b = snapshot(_make_emu(a=0x10, bgmode=1, tm=0x04, bg3vofs=0xFF98))
    out = diff(a, b)
    assert "tm" in out, out
    assert "bg3vofs" in out, out
    assert "bgmode" not in out, "bgmode unchanged should not appear"


def test_diff_includes_memory_byte_count():
    a = snapshot(_make_emu(vram=0x00))
    b = snapshot(_make_emu(vram=0xFF))
    out = diff(a, b)
    # Memory blobs differ → diff mentions vram and a byte count rather
    # than dumping the raw bytes.
    assert "vram" in out, out
    assert "byte" in out, out


def test_diff_format_is_unified_diff_style():
    """Output uses a familiar `- expected / + actual` shape so the diff
    is greppable in CI logs."""
    a = snapshot(_make_emu(tm=0x07))
    b = snapshot(_make_emu(tm=0x04))
    out = diff(a, b)
    # Two minus/plus or arrow lines somewhere.
    assert ("- " in out and "+ " in out) or ("→" in out), out
