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
]


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
