"""Raw ctypes bindings for libkintsuki.

Loaded once at import time. Most users want the high-level Emu class from
kintsuki/__init__.py rather than these primitives.
"""

from __future__ import annotations

import ctypes
import sys
from ctypes import (
    CFUNCTYPE,
    POINTER,
    Structure,
    c_char_p,
    c_int,
    c_size_t,
    c_uint8,
    c_uint16,
    c_uint32,
    c_uint64,
    c_void_p,
)
from pathlib import Path


def _load_lib() -> ctypes.CDLL:
    here = Path(__file__).resolve().parent / "_lib"
    candidates: list[Path]
    if sys.platform == "darwin":
        candidates = [here / "libkintsuki.dylib"]
    elif sys.platform.startswith("linux"):
        candidates = [here / "libkintsuki.so"]
    elif sys.platform == "win32":
        candidates = [here / "kintsuki.dll", here / "libkintsuki.dll"]
    else:
        raise RuntimeError(f"unsupported platform: {sys.platform}")
    for path in candidates:
        if path.exists():
            return ctypes.CDLL(str(path))
    raise FileNotFoundError(
        f"libkintsuki not found in {here}. Build with "
        "`make -C bsnes/bsnes target=kintsuki binary=library` and copy "
        "out/libkintsuki.dylib into src/kintsuki/_lib/."
    )


_lib = _load_lib()


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------
class CpuState(Structure):
    """65816 register snapshot."""

    _fields_ = [
        ("a", c_uint16),
        ("x", c_uint16),
        ("y", c_uint16),
        ("s", c_uint16),
        ("d", c_uint16),
        ("b", c_uint8),
        ("p", c_uint8),
        ("pc", c_uint32),
        ("e", c_uint8),
    ]

    def __repr__(self) -> str:
        return (
            f"CpuState(a=${self.a:04X} x=${self.x:04X} y=${self.y:04X} "
            f"s=${self.s:04X} d=${self.d:04X} b=${self.b:02X} "
            f"p=${self.p:02X} pc=${self.pc:06X} e={self.e})"
        )


# Opaque handle: void* pointer.
HANDLE = c_void_p

# Callback signature: void (*)(uint32_t addr, uint8_t value, void* userdata)
CALLBACK = CFUNCTYPE(None, c_uint32, c_uint8, c_void_p)


# Callback kind constants (must match libkintsuki.cpp).
CB_EXEC = 0
CB_READ = 1
CB_WRITE = 2


# ---------------------------------------------------------------------------
# Function prototypes
# ---------------------------------------------------------------------------
def _bind(name: str, restype, argtypes: list) -> None:
    fn = getattr(_lib, name)
    fn.restype = restype
    fn.argtypes = argtypes


# Lifecycle
_bind("kintsuki_create", HANDLE, [])
_bind("kintsuki_destroy", None, [HANDLE])
_bind("kintsuki_load_rom", c_int, [HANDLE, c_char_p])

# Execution
_bind("kintsuki_run_frames", None, [HANDLE, c_uint32])
_bind("kintsuki_step", None, [HANDLE])
_bind("kintsuki_frame_count", c_uint64, [HANDLE])
_bind("kintsuki_run_until", c_int, [HANDLE, c_uint32, c_uint32])

# Memory
_bind("kintsuki_read_u8", c_uint8, [HANDLE, c_uint32])
_bind("kintsuki_write_u8", None, [HANDLE, c_uint32, c_uint8])
_bind("kintsuki_read_range", c_uint32, [HANDLE, c_uint32, c_uint32, POINTER(c_uint8)])

# PPU memory
_bind("kintsuki_vram_read", c_uint8, [HANDLE, c_uint32])
_bind("kintsuki_vram_write", None, [HANDLE, c_uint32, c_uint8])
_bind("kintsuki_cgram_read", c_uint8, [HANDLE, c_uint32])
_bind("kintsuki_cgram_write", None, [HANDLE, c_uint32, c_uint8])
_bind("kintsuki_oam_read", c_uint8, [HANDLE, c_uint32])
_bind("kintsuki_oam_write", None, [HANDLE, c_uint32, c_uint8])

# CPU state
_bind("kintsuki_get_state", None, [HANDLE, POINTER(CpuState)])
_bind("kintsuki_set_state", None, [HANDLE, POINTER(CpuState)])

# Savestate
_bind("kintsuki_save_state", c_uint32, [HANDLE, c_void_p, c_uint32])
_bind("kintsuki_load_state", c_int, [HANDLE, c_void_p, c_uint32])

# Framebuffer / screenshot
_bind("kintsuki_framebuffer", POINTER(c_uint32), [HANDLE, POINTER(c_uint32), POINTER(c_uint32)])
_bind("kintsuki_screenshot", c_int, [HANDLE, c_char_p])

# Input
_bind("kintsuki_set_input", None, [HANDLE, c_int, c_uint16])
_bind("kintsuki_press", None, [HANDLE, c_int, c_int, c_int])

# Callbacks
_bind("kintsuki_add_callback", c_int, [HANDLE, c_int, c_uint32, c_uint32, CALLBACK, c_void_p])
_bind("kintsuki_remove_callback", None, [HANDLE, c_int, c_int])


# Re-exports for convenience.
lib = _lib
