"""Phase 6 — push parsed Mesen ``.mss`` records into a kintsuki Emu.

`import_mesen_state(emu, path)` reads the file via
`kintsuki.mesen.parse_mesen_state` and stuffs the bits we care about
back into the emulator:

  - CPU registers (a, x, y, sp, d, dbr, k, pc, ps, emulationMode) →
    `Emu.set_state(CpuState)`
  - WRAM → `write_range($7E:0000, ...)` for the full 128 KiB
  - VRAM → per-byte `vram_write` (or bulk if available)
  - CGRAM → per-byte `cgram_write`
  - OAM   → per-byte `oam_write`

Tests use a fake Emu that records writes; verifies the right data
lands in the right place when fed a synthesised .mss blob.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

import pytest


def _make_mss(records: dict[bytes, bytes]) -> bytes:
    """Tiny .mss synthesiser (matches kintsuki.mesen format)."""
    out = bytearray()
    out += b"MSS"
    out += struct.pack("<III", 0x00020101, 4, 0)  # ver, fmt, console
    fb = zlib.compress(b"")
    out += struct.pack("<IIIII", 0, 0, 0, 100, len(fb))
    out += fb
    rom = b"unit-test.sfc"
    out += struct.pack("<I", len(rom))
    out += rom
    payload = bytearray()
    for k, v in records.items():
        payload += k + b"\x00" + struct.pack("<I", len(v)) + v
    compressed = zlib.compress(bytes(payload))
    out += b"\x01"
    out += struct.pack("<II", len(payload), len(compressed))
    out += compressed
    return bytes(out)


class _RecordingEmu:
    """Stub Emu surface: records every set_state / write call."""

    def __init__(self) -> None:
        self.set_state_calls: list[object] = []
        self.write_range_calls: list[tuple[int, bytes]] = []
        self.vram_writes: dict[int, int] = {}
        self.cgram_writes: dict[int, int] = {}
        self.oam_writes: dict[int, int] = {}
        # set_state needs a CpuState input shape — record raw fields.
        self._fake_cpu = type("Cpu", (), dict(
            a=0, x=0, y=0, s=0, d=0, b=0, p=0, pc=0, e=False, stp=False, wai=False))()

    def get_state(self):
        return self._fake_cpu

    def set_state(self, s):
        self.set_state_calls.append(s)

    def write_range(self, addr: int, data) -> None:
        self.write_range_calls.append((addr, bytes(data)))

    def vram_write(self, addr: int, value: int) -> None:
        self.vram_writes[addr] = value

    def cgram_write(self, addr: int, value: int) -> None:
        self.cgram_writes[addr] = value

    def oam_write(self, addr: int, value: int) -> None:
        self.oam_writes[addr] = value


# ---- Tests ----------------------------------------------------------------
def test_import_pushes_cpu_registers(tmp_path: Path):
    from kintsuki.mesen import import_mesen_state

    blob = _make_mss({
        b"cpu.a":             struct.pack("<H", 0x1234),
        b"cpu.x":             struct.pack("<H", 0x5678),
        b"cpu.y":             struct.pack("<H", 0x9ABC),
        b"cpu.sp":            struct.pack("<H", 0x1FFF),
        b"cpu.d":             struct.pack("<H", 0xDEAD),
        b"cpu.dbr":           bytes([0x42]),
        b"cpu.k":             bytes([0x07]),
        b"cpu.pc":            struct.pack("<H", 0x8000),
        b"cpu.ps":            bytes([0x30]),
        b"cpu.emulationMode": bytes([0x00]),
        b"memoryManager.workRam": b"",   # empty stand-ins
        b"ppu.vram":              b"",
        b"ppu.cgram":             b"",
        b"ppu.oamRam":            b"",
    })
    p = tmp_path / "cpu.mss"
    p.write_bytes(blob)

    emu = _RecordingEmu()
    import_mesen_state(emu, p)
    assert emu.set_state_calls, "set_state was not called"
    s = emu.set_state_calls[-1]
    assert s.a == 0x1234
    assert s.x == 0x5678
    assert s.y == 0x9ABC
    assert s.s == 0x1FFF
    assert s.d == 0xDEAD
    assert s.b == 0x42
    assert s.p == 0x30
    assert s.pc == (0x07 << 16) | 0x8000   # k:pc combined to 24-bit
    assert s.e == 0


def test_import_pushes_wram(tmp_path: Path):
    from kintsuki.mesen import import_mesen_state

    wram = bytes([(i % 256) for i in range(128 * 1024)])
    blob = _make_mss({
        b"memoryManager.workRam": wram,
        b"ppu.vram": b"", b"ppu.cgram": b"", b"ppu.oamRam": b"",
    })
    p = tmp_path / "wram.mss"
    p.write_bytes(blob)

    emu = _RecordingEmu()
    import_mesen_state(emu, p)
    assert emu.write_range_calls, "write_range was not called for WRAM"
    addr, data = emu.write_range_calls[-1]
    assert addr == 0x7E0000
    assert data == wram


def test_import_pushes_vram_cgram_oam(tmp_path: Path):
    from kintsuki.mesen import import_mesen_state

    vram = bytes([i & 0xFF for i in range(64 * 1024)])
    cgram = bytes(range(0, 512)) if False else bytes([(i * 7) & 0xFF for i in range(512)])
    oam = bytes([(i ^ 0x55) & 0xFF for i in range(544)])
    blob = _make_mss({
        b"memoryManager.workRam": b"",
        b"ppu.vram": vram,
        b"ppu.cgram": cgram,
        b"ppu.oamRam": oam,
    })
    p = tmp_path / "ppu.mss"
    p.write_bytes(blob)

    emu = _RecordingEmu()
    import_mesen_state(emu, p)
    # Sample a handful of addresses end-to-end.
    for addr in (0, 1, 0x1234, 0xFFFF):
        assert emu.vram_writes.get(addr) == vram[addr], f"vram[{addr:#06x}]"
    for addr in (0, 1, 255, 511):
        assert emu.cgram_writes.get(addr) == cgram[addr]
    for addr in (0, 1, 543):
        assert emu.oam_writes.get(addr) == oam[addr]


def test_import_skips_blocks_with_size_mismatch(tmp_path: Path, caplog):
    """If a block's recorded size doesn't match what we expect (e.g., a
    Mesen format change shipped a different layout), skip it with a
    warning rather than truncating / over-running buffers."""
    from kintsuki.mesen import import_mesen_state

    blob = _make_mss({
        b"memoryManager.workRam": b"\xff" * 100,  # truncated WRAM
        b"ppu.vram": b"", b"ppu.cgram": b"", b"ppu.oamRam": b"",
    })
    p = tmp_path / "trunc.mss"
    p.write_bytes(blob)

    emu = _RecordingEmu()
    # Should not raise; should not write the truncated WRAM.
    import_mesen_state(emu, p)
    addrs = {a for a, _ in emu.write_range_calls}
    assert 0x7E0000 not in addrs, "truncated WRAM should be skipped"


def test_import_pushes_save_ram(tmp_path: Path):
    """`cart.saveRam` is shovelled to $70:0000 (LoROM SRAM mapping)."""
    from kintsuki.mesen import import_mesen_state

    sram = bytes([(i * 11) & 0xFF for i in range(8 * 1024)])  # 8 KiB
    blob = _make_mss({
        b"cart.saveRam": sram,
        b"memoryManager.workRam": b"",
        b"ppu.vram": b"", b"ppu.cgram": b"", b"ppu.oamRam": b"",
    })
    p = tmp_path / "sram.mss"
    p.write_bytes(blob)

    emu = _RecordingEmu()
    import_mesen_state(emu, p)
    addrs = {a: d for a, d in emu.write_range_calls}
    assert addrs.get(0x700000) == sram, "SRAM should land at $70:0000 (LoROM)"


def test_import_skips_save_ram_when_cart_has_none(tmp_path: Path):
    """No `cart.saveRam` record (= cart has no SRAM) → no write."""
    from kintsuki.mesen import import_mesen_state

    blob = _make_mss({
        b"memoryManager.workRam": b"",
        b"ppu.vram": b"", b"ppu.cgram": b"", b"ppu.oamRam": b"",
    })
    p = tmp_path / "no-sram.mss"
    p.write_bytes(blob)

    emu = _RecordingEmu()
    import_mesen_state(emu, p)
    addrs = {a for a, _ in emu.write_range_calls}
    assert 0x700000 not in addrs


def test_import_real_ff4_mss(tmp_path: Path):
    """Smoke-only: parses a real ff4 .mss without raising and pushes
    *something*. Skipped when the fixture isn't present."""
    from kintsuki.mesen import import_mesen_state

    fixture = Path("/Users/manz/PyCharmProjects/ff4-modules/tests/savestates/"
                   "battle_end_before_treasure.mss")
    if not fixture.exists():
        pytest.skip(f"fixture not present: {fixture}")
    emu = _RecordingEmu()
    import_mesen_state(emu, fixture)
    assert emu.set_state_calls, "real ff4 mss should populate CPU regs"
    # Real WRAM is 128 KB.
    addrs = {a: len(d) for a, d in emu.write_range_calls}
    assert addrs.get(0x7E0000) == 128 * 1024
