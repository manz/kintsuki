"""kintsuki — Pythonic wrapper around the bsnes-derived SNES emulator core.

>>> emu = kintsuki.Emu()
>>> emu.load_rom("ff4.sfc")
>>> emu.run_frames(60)
>>> emu.read(0x7E1700)
3
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
from typing import Callable

from . import _native
from ._native import CB_EXEC, CB_READ, CB_WRITE, CpuState

__version__ = "0.1.0"

__all__ = [
    "Emu",
    "Button",
    "CpuState",
    "CallbackKind",
    "SymbolTable",
]


import re
from pathlib import Path


class SymbolTable:
    """Parse a ca65 / Mesen .sym file ('BB:OOOO name' lines).

    Looks up by symbol name → 24-bit address. Convenience for unit tests
    that drive the CPU at named entry points.

    >>> syms = SymbolTable("ff4.sym")
    >>> syms["GetKerningAdjustmentLinearSearch"]
    0x208297
    """

    _LINE = re.compile(r"\s*([0-9a-fA-F]+):([0-9a-fA-F]+)\s+(\S+)")

    def __init__(self, path: str | Path):
        self._addrs: dict[str, int] = {}
        text = Path(path).read_text()
        for line in text.splitlines():
            m = self._LINE.match(line)
            if not m:
                continue
            bank, off, name = m.groups()
            self._addrs[name] = (int(bank, 16) << 16) | int(off, 16)

    def __getitem__(self, name: str) -> int:
        return self._addrs[name]

    def get(self, name: str, default: int | None = None) -> int | None:
        return self._addrs.get(name, default)

    def __contains__(self, name: str) -> bool:
        return name in self._addrs

    def __len__(self) -> int:
        return len(self._addrs)

    def names(self) -> list[str]:
        return list(self._addrs.keys())


class Button:
    """65816 SNES gamepad button indices (match libkintsuki press() argument)."""

    UP = 0
    DOWN = 1
    LEFT = 2
    RIGHT = 3
    B = 4
    A = 5
    Y = 6
    X = 7
    L = 8
    R = 9
    SELECT = 10
    START = 11


class CallbackKind:
    EXEC = CB_EXEC
    READ = CB_READ
    WRITE = CB_WRITE


@dataclass
class _Registered:
    """Bookkeeping for a registered callback. We hold the CFUNCTYPE so the
    Python GC doesn't free the trampoline while the C side may still call it."""

    kind: int
    cb_id: int
    trampoline: ctypes._FuncPointer


class Emu:
    """High-level wrapper. Single-instance for now (bsnes core uses globals)."""

    def __init__(self) -> None:
        h = _native.lib.kintsuki_create()
        if not h:
            raise RuntimeError("kintsuki_create failed")
        self._handle = h
        self._registered: list[_Registered] = []

    # ------------------------------------------------------------------ ROM
    def load_rom(self, path: str) -> None:
        ok = _native.lib.kintsuki_load_rom(self._handle, path.encode("utf-8"))
        if not ok:
            raise RuntimeError(f"failed to load ROM: {path}")

    # -------------------------------------------------------------- Run/step
    def run_frames(self, n: int) -> None:
        _native.lib.kintsuki_run_frames(self._handle, n)

    def step(self) -> None:
        _native.lib.kintsuki_step(self._handle)

    @property
    def frame_count(self) -> int:
        return int(_native.lib.kintsuki_frame_count(self._handle))

    # ------------------------------------------------------------------ Mem
    def read(self, addr: int) -> int:
        return int(_native.lib.kintsuki_read_u8(self._handle, addr))

    def write(self, addr: int, value: int) -> None:
        _native.lib.kintsuki_write_u8(self._handle, addr, value & 0xFF)

    def read16(self, addr: int) -> int:
        return self.read(addr) | (self.read(addr + 1) << 8)

    def read_range(self, addr: int, length: int) -> bytes:
        buf = (ctypes.c_uint8 * length)()
        n = _native.lib.kintsuki_read_range(self._handle, addr, length, buf)
        return bytes(buf[:n])

    def write_range(self, addr: int, data: bytes | bytearray) -> None:
        """Bulk write `data` starting at `addr` (CPU bus, 24-bit). Useful
        for dropping assembled stubs into WRAM as test harnesses."""
        for i, b in enumerate(data):
            _native.lib.kintsuki_write_u8(self._handle, addr + i, b & 0xFF)

    # PPU memory
    def vram_read(self, addr: int) -> int:
        return int(_native.lib.kintsuki_vram_read(self._handle, addr))

    def vram_write(self, addr: int, value: int) -> None:
        _native.lib.kintsuki_vram_write(self._handle, addr, value & 0xFF)

    def cgram_read(self, addr: int) -> int:
        return int(_native.lib.kintsuki_cgram_read(self._handle, addr))

    def cgram_write(self, addr: int, value: int) -> None:
        _native.lib.kintsuki_cgram_write(self._handle, addr, value & 0xFF)

    def oam_read(self, addr: int) -> int:
        return int(_native.lib.kintsuki_oam_read(self._handle, addr))

    def oam_write(self, addr: int, value: int) -> None:
        _native.lib.kintsuki_oam_write(self._handle, addr, value & 0xFF)

    # ------------------------------------------------------------ CPU state
    def get_state(self) -> CpuState:
        s = CpuState()
        _native.lib.kintsuki_get_state(self._handle, ctypes.byref(s))
        return s

    def set_state(self, s: CpuState) -> None:
        _native.lib.kintsuki_set_state(self._handle, ctypes.byref(s))

    # ------------------------------------------------------------ Savestate
    def save_state(self) -> bytes:
        size = _native.lib.kintsuki_save_state(self._handle, None, 0)
        if size == 0:
            raise RuntimeError("save_state failed")
        buf = (ctypes.c_uint8 * size)()
        _native.lib.kintsuki_save_state(self._handle, ctypes.cast(buf, ctypes.c_void_p), size)
        return bytes(buf)

    def load_state(self, blob: bytes) -> None:
        ok = _native.lib.kintsuki_load_state(self._handle, blob, len(blob))
        if not ok:
            raise RuntimeError("load_state failed")

    # ----------------------------------------------------------- Framebuffer
    def framebuffer(self) -> tuple[bytes, int, int]:
        """Returns (rgba_bytes, width, height). Caller copies; pointer is valid
        only until the next emulator->run() call."""
        w = ctypes.c_uint32(0)
        h = ctypes.c_uint32(0)
        ptr = _native.lib.kintsuki_framebuffer(
            self._handle, ctypes.byref(w), ctypes.byref(h)
        )
        if not ptr or not w.value or not h.value:
            return (b"", 0, 0)
        n = w.value * h.value
        # Each pixel is uint32 packed 0x00RRGGBB.
        raw = ctypes.string_at(ptr, n * 4)
        return (raw, int(w.value), int(h.value))

    def screenshot(self, path: str) -> bool:
        return bool(_native.lib.kintsuki_screenshot(self._handle, path.encode("utf-8")))

    # ----------------------------------------------------------------- Input
    def set_input(self, port: int, mask: int) -> None:
        _native.lib.kintsuki_set_input(self._handle, port, mask & 0xFFFF)

    def press(self, port: int, button: int, pressed: bool = True) -> None:
        _native.lib.kintsuki_press(self._handle, port, button, 1 if pressed else 0)

    def release(self, port: int, button: int) -> None:
        self.press(port, button, False)

    # ------------------------------------------------------------- Callbacks
    def _add_callback(
        self,
        kind: int,
        lo: int,
        hi: int,
        fn: Callable[[int, int], None],
    ) -> int:
        # The C ABI hands us (addr, value, userdata); we drop userdata in the
        # Python view and call user_fn(addr, value).
        def trampoline(addr, value, _ud):
            fn(int(addr), int(value))

        c_fn = _native.CALLBACK(trampoline)
        cb_id = _native.lib.kintsuki_add_callback(
            self._handle, kind, lo, hi, c_fn, None
        )
        if cb_id == 0:
            raise RuntimeError("add_callback failed")
        # Hold trampoline reference so it isn't GC'd while bsnes still calls it.
        self._registered.append(_Registered(kind=kind, cb_id=cb_id, trampoline=c_fn))
        return cb_id

    def add_exec_callback(self, lo: int, hi: int, fn: Callable[[int, int], None]) -> int:
        return self._add_callback(CB_EXEC, lo, hi, fn)

    def add_read_callback(self, lo: int, hi: int, fn: Callable[[int, int], None]) -> int:
        return self._add_callback(CB_READ, lo, hi, fn)

    def add_write_callback(self, lo: int, hi: int, fn: Callable[[int, int], None]) -> int:
        return self._add_callback(CB_WRITE, lo, hi, fn)

    def remove_callback(self, kind: int, cb_id: int) -> None:
        _native.lib.kintsuki_remove_callback(self._handle, kind, cb_id)
        self._registered = [
            r for r in self._registered if not (r.kind == kind and r.cb_id == cb_id)
        ]

    # ----- High-level test helpers ---------------------------------------

    def push_byte(self, value: int) -> None:
        """Push a byte onto the 65816 stack. Native mode stack is the full
        bank-0 16-bit S range; emulation mode is $00:0100-$01FF (the high
        byte of S is forced to $01 by the CPU)."""
        s = self.get_state()
        addr = (s.s & 0xFFFF)            # bank 0
        if s.e:                           # emulation: stack page is $0100
            addr = 0x0100 | (s.s & 0xFF)
        self.write(addr, value & 0xFF)
        s.s = (s.s - 1) & 0xFFFF
        self.set_state(s)

    def push_word(self, value: int) -> None:
        """Push a 16-bit word onto the stack (little-endian: high byte first
        so RTS pulls low then high). 65816 stack convention."""
        self.push_byte((value >> 8) & 0xFF)
        self.push_byte((value >> 0) & 0xFF)

    def run_until(
        self,
        target_pc: int,
        max_frames: int = 60,
    ) -> bool:
        """Run until PC == target_pc. Mid-frame bail. Returns True on hit."""
        rc = _native.lib.kintsuki_run_until(self._handle, target_pc, max_frames)
        return rc != 0

    def rearm_cpu(self) -> None:
        """Rebuild the CPU coroutine. Use between consecutive STP-terminated
        stubs so the next stub starts from a clean dispatch state without
        wiping WRAM or losing ROM mapping."""
        _native.lib.kintsuki_rearm_cpu(self._handle)

    def run_until_stp(self, max_frames: int = 60) -> bool:
        """Run until the CPU executes STP (opcode 0xDB). After STP the CPU
        halts (r.stp=1) so this is the cleanest way to mark "test done"
        from injected asm: end your stub with `stp` and call this. Returns
        True if STP was reached."""
        for _ in range(max_frames):
            self.run_frames(1)
            if self.get_state().stp:
                return True
        return False

    # Sentinel "exit" address. Test stubs jmp here to signal completion;
    # run_asm installs an exec callback at this PC and bails when it fires.
    # Lives in the very top of bank-0 mirror (unmapped → reads as 0xFF →
    # never executed by real code).
    EXIT_PC: int = 0x00FFFC

    def run_asm(
        self,
        code: bytes | bytearray,
        *,
        load_addr: int = 0x7E0000,
        a: int = 0,
        x: int = 0,
        y: int = 0,
        max_frames: int = 60,
    ) -> CpuState:
        """Drop `code` into WRAM at `load_addr`, set CPU regs, run until the
        stub jumps to EXIT_PC. Returns the CPU state captured the moment
        the sentinel was hit (snapshotted from inside the exec callback).
        """
        EXIT_OPCODE = bytes([0x5C, 0xFC, 0xFF, 0x00])
        payload = bytes(code)
        if not payload.endswith(EXIT_OPCODE):
            payload += EXIT_OPCODE
        self.write_range(load_addr, payload)

        s = self.get_state()
        s.pc = load_addr & 0xFFFFFF
        s.a = a & 0xFFFF
        s.x = x & 0xFFFF
        s.y = y & 0xFFFF
        s.s = 0x1FFF
        self.set_state(s)

        # Snapshot CPU state in the exec callback, before run_frames(1)
        # finishes its slice and the CPU runs past the sentinel.
        self.run_until(self.EXIT_PC, max_frames=max_frames)
        return self.get_state()

    def call(
        self,
        func_addr: int,
        a: int = 0,
        x: int = 0,
        y: int = 0,
        max_frames: int = 60,
    ) -> CpuState:
        """Direct-call a 65816 routine.

        Sets PC = func_addr, A/X/Y to the requested values, pushes a sentinel
        return address (long-form, so this works for both RTS and RTL),
        then runs until the sentinel is hit. Returns the CPU state at that
        point so you can read result registers.

        Caller is responsible for routine being a leaf-ish pure function:
        no NMI/IRQ-dependent logic, no SMP handshake, no DMA setup. Best
        for ROM-table lookups and arithmetic helpers.
        """
        # Two possible exit addresses depending on whether the routine uses
        # RTS (16-bit pop, stays in current PB) or RTL (24-bit pop, jumps
        # to bank we pushed). Cover both:
        #   - rts_exit: same bank as the function, low 16 bits = $FFFC
        #   - rtl_exit: bank $00, low 16 bits = $FFFC
        sentinel_lo = 0xFFFC
        rtl_exit = 0x000000 | sentinel_lo
        rts_exit = (func_addr & 0xFF0000) | sentinel_lo

        s = self.get_state()
        s.pc = func_addr & 0xFFFFFF
        s.a = a & 0xFFFF
        s.x = x & 0xFFFF
        s.y = y & 0xFFFF
        s.s = 0x1FFF
        s.e = False                       # native mode
        s.p = 0x00                        # 16-bit A + 16-bit X/Y, no flags
        self.set_state(s)
        # Push long-form return so RTL works. RTS only pops the lower two
        # bytes; the bank byte we push above is then unused but doesn't
        # hurt anything.
        self.push_byte((rtl_exit >> 16) & 0xFF)
        self.push_word(sentinel_lo)

        # Try RTL exit first (long-form return); if that doesn't fire,
        # fall through to RTS exit in the function's bank.
        if not self.run_until(rtl_exit, max_frames=max_frames):
            if rts_exit != rtl_exit:
                self.run_until(rts_exit, max_frames=max_frames)
        return self.get_state()

    # --------------------------------------------------------------- Cleanup
    def close(self) -> None:
        if self._handle:
            _native.lib.kintsuki_destroy(self._handle)
            self._handle = None
            self._registered.clear()

    def __enter__(self) -> "Emu":
        return self

    def __exit__(self, *_) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass
