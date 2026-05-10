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

    # Point libkintsuki at the bundled ares System/ tree (boards.bml +
    # ipl.rom). The dylib was built with KINTSUKI_SYSTEM_PAK_DEFAULT
    # baked in at CI time pointing at the runner's filesystem; that path
    # doesn't exist on the user's machine, so override here unless the
    # caller already set it explicitly.
    import os
    bundled_pak = here / "System" / "Super Famicom"
    if "KINTSUKI_SYSTEM_PAK" not in os.environ and bundled_pak.is_dir():
        os.environ["KINTSUKI_SYSTEM_PAK"] = str(bundled_pak)

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
        f"libkintsuki not found in {here}. Run `make build python-stage` "
        f"from the kintsuki repo, or install a wheel from PyPI."
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
        ("stp", c_uint8),
        ("wai", c_uint8),
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
_bind("kintsuki_rearm_cpu", None, [HANDLE])

# Memory
_bind("kintsuki_read_u8", c_uint8, [HANDLE, c_uint32])
_bind("kintsuki_write_u8", None, [HANDLE, c_uint32, c_uint8])
_bind("kintsuki_read_range", c_uint32, [HANDLE, c_uint32, c_uint32, POINTER(c_uint8)])
_bind("kintsuki_write_range", c_uint32, [HANDLE, c_uint32, c_uint32, POINTER(c_uint8)])

# PPU memory
_bind("kintsuki_vram_read", c_uint8, [HANDLE, c_uint32])
_bind("kintsuki_vram_write", None, [HANDLE, c_uint32, c_uint8])
_bind("kintsuki_vram_read_range", c_uint32, [HANDLE, c_uint32, c_uint32, POINTER(c_uint8)])
_bind("kintsuki_vram_write_range", c_uint32, [HANDLE, c_uint32, c_uint32, POINTER(c_uint8)])
_bind("kintsuki_cgram_read", c_uint8, [HANDLE, c_uint32])
_bind("kintsuki_cgram_write", None, [HANDLE, c_uint32, c_uint8])
_bind("kintsuki_cgram_read_range", c_uint32, [HANDLE, c_uint32, c_uint32, POINTER(c_uint8)])
_bind("kintsuki_cgram_write_range", c_uint32, [HANDLE, c_uint32, c_uint32, POINTER(c_uint8)])
_bind("kintsuki_oam_read", c_uint8, [HANDLE, c_uint32])
_bind("kintsuki_oam_write", None, [HANDLE, c_uint32, c_uint8])
_bind("kintsuki_oam_read_range", c_uint32, [HANDLE, c_uint32, c_uint32, POINTER(c_uint8)])
_bind("kintsuki_oam_write_range", c_uint32, [HANDLE, c_uint32, c_uint32, POINTER(c_uint8)])

# CPU state
_bind("kintsuki_get_state", None, [HANDLE, POINTER(CpuState)])
_bind("kintsuki_set_state", None, [HANDLE, POINTER(CpuState)])


# Shadow callstack — frames pushed/popped natively by the WDC65816 hooks.
class CallFrame(Structure):
    _fields_ = [
        ("callsite_pc", c_uint32),
        ("target_pc",   c_uint32),
        ("kind",        c_uint8),
    ]


_bind("kintsuki_callstack_snapshot", c_uint32,
      [HANDLE, POINTER(CallFrame), c_uint32])
_bind("kintsuki_callstack_clear", None, [HANDLE])


# DMA transfer log — populated by libkintsuki via the ares dmaHook.
class DmaEvent(Structure):
    _fields_ = [
        ("src_addr",  c_uint32),
        ("size",      c_uint16),
        ("channel",   c_uint8),
        ("direction", c_uint8),
        ("mode",      c_uint8),
        ("dst_reg",   c_uint8),
        ("vram_addr", c_uint16),
        ("hits",      c_uint32),
        ("last_frame", c_uint64),
    ]


_bind("kintsuki_dma_log_count",    c_uint32, [HANDLE])
_bind("kintsuki_dma_log_snapshot", c_uint32, [HANDLE, POINTER(DmaEvent), c_uint32])
_bind("kintsuki_dma_log_clear",    None,     [HANDLE])

# .adbg label table.
_bind("kintsuki_load_adbg",     c_int,    [HANDLE, c_char_p])
_bind("kintsuki_clear_adbg",    None,     [HANDLE])
_bind("kintsuki_lookup_label",  c_char_p, [HANDLE, c_uint32])
_bind("kintsuki_lookup_label_containing", c_char_p,
      [HANDLE, c_uint32, POINTER(c_uint32)])
_bind("kintsuki_lookup_source", c_int,
      [HANDLE, c_uint32, POINTER(c_char_p), POINTER(c_uint32), POINTER(c_uint16)])
_bind("kintsuki_lookup_symbol_addr", c_int,
      [HANDLE, c_char_p, POINTER(c_uint32)])


# Tracer range mask. Mirrors `kintsuki_trace_range_t`.
class TraceRange(Structure):
    _fields_ = [("start", c_uint32), ("size", c_uint32)]


_bind("kintsuki_tracer_set_ranges", None,
      [HANDLE, POINTER(TraceRange), c_uint32])


# PPU/DMA snapshot. Layout must match `kintsuki_ppu_state_t` in
# target-kintsuki/kintsuki.h. ctypes lays fields out in declaration order
# with platform-default alignment; matches the C struct so a single read
# back via byref(PpuStateRaw()) works.
class DmaChannelRaw(Structure):
    _fields_ = [
        ("ctrl", c_uint8),
        ("dest", c_uint8),
        ("src_addr", c_uint16),
        ("src_bank", c_uint8),
        ("ind_count", c_uint16),
        ("ind_bank", c_uint8),
        ("line_count", c_uint8),
        ("enabled", c_uint8),
    ]


class PpuStateRaw(Structure):
    _fields_ = [
        ("inidisp", c_uint8),
        ("bgmode", c_uint8),
        ("mosaic", c_uint8),
        ("bg1sc", c_uint8),
        ("bg2sc", c_uint8),
        ("bg3sc", c_uint8),
        ("bg4sc", c_uint8),
        ("bg12nba", c_uint8),
        ("bg34nba", c_uint8),
        ("bg1hofs", c_uint16),
        ("bg1vofs", c_uint16),
        ("bg2hofs", c_uint16),
        ("bg2vofs", c_uint16),
        ("bg3hofs", c_uint16),
        ("bg3vofs", c_uint16),
        ("bg4hofs", c_uint16),
        ("bg4vofs", c_uint16),
        ("vmain", c_uint8),
        ("vmaddr", c_uint16),
        ("m7sel", c_uint8),
        ("m7a", c_uint16),
        ("m7b", c_uint16),
        ("m7c", c_uint16),
        ("m7d", c_uint16),
        ("m7x", c_uint16),
        ("m7y", c_uint16),
        ("cgadd", c_uint8),
        ("tm", c_uint8),
        ("ts", c_uint8),
        ("tmw", c_uint8),
        ("tsw", c_uint8),
        ("cgwsel", c_uint8),
        ("cgadsub", c_uint8),
        ("setini", c_uint8),
        ("hcounter", c_uint16),
        ("vcounter", c_uint16),
        ("dma", DmaChannelRaw * 8),
        ("mdmaen", c_uint8),
        ("hdmaen", c_uint8),
    ]


_bind("kintsuki_get_ppu_state", None, [HANDLE, POINTER(PpuStateRaw)])

# Tracer
TRACE_RING = 0
TRACE_FILE = 1
_bind("kintsuki_tracer_start", None,
      [HANDLE, c_uint32, c_uint32, c_int, c_char_p, c_uint32])
_bind("kintsuki_tracer_stop", None, [HANDLE])
_bind("kintsuki_tracer_drain", c_uint32, [HANDLE, c_char_p, c_uint32])

# Reset + SRAM injection
_bind("kintsuki_reset", None, [HANDLE])
_bind("kintsuki_inject_sram", c_uint32, [HANDLE, POINTER(c_uint8), c_uint32])
_bind("kintsuki_set_srm_sidecar", None, [HANDLE, c_int])

# Savestate
_bind("kintsuki_save_state", c_uint32, [HANDLE, c_void_p, c_uint32])
_bind("kintsuki_load_state", c_int, [HANDLE, c_void_p, c_uint32])

# Framebuffer / screenshot
_bind("kintsuki_framebuffer", POINTER(c_uint32), [HANDLE, POINTER(c_uint32), POINTER(c_uint32)])
_bind("kintsuki_screenshot", c_int, [HANDLE, c_char_p])
_bind("kintsuki_ppu_hires", c_int, [HANDLE])

# Input
_bind("kintsuki_set_input", None, [HANDLE, c_int, c_uint16])
_bind("kintsuki_press", None, [HANDLE, c_int, c_int, c_int])

# Callbacks
_bind("kintsuki_add_callback", c_int, [HANDLE, c_int, c_uint32, c_uint32, CALLBACK, c_void_p])
_bind("kintsuki_remove_callback", None, [HANDLE, c_int, c_int])


# Re-exports for convenience.
lib = _lib
