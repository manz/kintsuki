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
    c_int8,
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
_bind("kintsuki_master_clock", c_uint64, [HANDLE])
_bind("kintsuki_cpu_cycles", c_uint64, [HANDLE])
_bind("kintsuki_run_until", c_int, [HANDLE, c_uint32, c_uint32])
_bind("kintsuki_run_until_ex", c_int,
      [HANDLE, c_uint32, c_uint32, POINTER(c_uint64)])
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


# Per-function profiler.
class FnStatRaw(Structure):
    _fields_ = [
        ("pc",          c_uint32),
        ("calls",       c_uint32),
        ("incl_cycles", c_uint64),
        ("excl_cycles", c_uint64),
        ("max_cycles",  c_uint64),
        ("min_cycles",  c_uint64),
    ]


_bind("kintsuki_profile_start",       None,     [HANDLE, c_uint32, c_uint32])
_bind("kintsuki_profile_stop",        None,     [HANDLE])
_bind("kintsuki_profile_reset",       None,     [HANDLE])
_bind("kintsuki_profile_stats_count", c_uint32, [HANDLE])
_bind("kintsuki_profile_stats",       c_uint32,
      [HANDLE, POINTER(FnStatRaw), c_uint32])


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
        ("caller_pc", c_uint32),
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


# Project file (slice 1: map.bin classification).
class ProjectStats(Structure):
    _fields_ = [
        ("total",       c_uint32),
        ("classified",  c_uint32),
        ("code",        c_uint32),
        ("data",        c_uint32),
        ("user_sticky", c_uint32),
    ]


# Byte class constants (must match KINTSUKI_BYTE_* in kintsuki.h).
BYTE_UNKNOWN  = 0
BYTE_CODE     = 1
BYTE_DATA     = 2
BYTE_POINTER  = 3
BYTE_STRING   = 4
BYTE_GRAPHICS = 5
BYTE_TILEMAP  = 6
BYTE_PALETTE  = 7
BYTE_AUDIO    = 8
BYTE_CODE_OPERAND = 9
BYTE_USER_STICKY = 0x80
BYTE_CLASS_MASK  = 0x7F


_bind("kintsuki_project_open",       c_int,     [HANDLE, c_char_p])
_bind("kintsuki_project_close",      None,      [HANDLE])
_bind("kintsuki_project_save",       c_int,     [HANDLE])
_bind("kintsuki_project_is_open",    c_int,     [HANDLE])
_bind("kintsuki_project_classify",   c_uint8,   [HANDLE, c_uint32])
_bind("kintsuki_project_bus_to_rom", c_int,     [HANDLE, c_uint32, POINTER(c_uint32)])
_bind("kintsuki_project_mark",       c_uint32,  [HANDLE, c_uint32, c_uint32, c_int, c_int])
_bind("kintsuki_project_map_dump",   c_uint32,  [HANDLE, POINTER(c_uint8), c_uint32])
_bind("kintsuki_project_stats",      c_int,     [HANDLE, POINTER(ProjectStats)])
_bind("kintsuki_project_set_autosave", None,    [HANDLE, c_uint32])
_bind("kintsuki_project_get_autosave", c_uint32, [HANDLE])


class ProjectLabel(Structure):
    _fields_ = [
        ("addr",    c_uint32),
        ("name",    c_char_p),
        ("type",    c_char_p),
        ("comment", c_char_p),
        ("m",       c_int8),
        ("x",       c_int8),
        ("e",       c_int8),
        ("_pad",    c_uint8),
    ]


_bind("kintsuki_project_label_set",      c_int,    [HANDLE, c_uint32,
                                                    c_char_p, c_char_p, c_char_p,
                                                    c_int, c_int, c_int])
_bind("kintsuki_project_label_get",      c_int,    [HANDLE, c_uint32, POINTER(ProjectLabel)])
_bind("kintsuki_project_label_clear",    None,     [HANDLE, c_uint32])
_bind("kintsuki_project_label_count",    c_uint32, [HANDLE])
_bind("kintsuki_project_label_snapshot", c_uint32, [HANDLE, POINTER(ProjectLabel), c_uint32])


class ProjectDmaProv(Structure):
    _fields_ = [
        ("src_rom",    c_uint32),
        ("size",       c_uint16),
        ("dst_reg",    c_uint8),
        ("_pad",       c_uint8),
        ("caller_pc",  c_uint32),
        ("hits",       c_uint32),
        ("last_frame", c_uint64),
    ]


_bind("kintsuki_project_dma_prov_count",     c_uint32, [HANDLE])
_bind("kintsuki_project_dma_prov_snapshot",  c_uint32, [HANDLE, POINTER(ProjectDmaProv), c_uint32])
_bind("kintsuki_project_dma_prov_for_range", c_uint32, [HANDLE, c_uint32, c_uint32,
                                                       POINTER(ProjectDmaProv), c_uint32])


class ProjectBookmark(Structure):
    _fields_ = [
        ("addr",    c_uint32),
        ("name",    c_char_p),
        ("view",    c_char_p),
        ("comment", c_char_p),
    ]


_bind("kintsuki_project_bookmark_set",      c_int,    [HANDLE, c_char_p, c_uint32, c_char_p, c_char_p])
_bind("kintsuki_project_bookmark_clear",    None,     [HANDLE, c_char_p])
_bind("kintsuki_project_bookmark_count",    c_uint32, [HANDLE])
_bind("kintsuki_project_bookmark_snapshot", c_uint32, [HANDLE, POINTER(ProjectBookmark), c_uint32])


class ProjectBp(Structure):
    _fields_ = [
        ("kind",    c_uint8),
        ("halt",    c_uint8),
        ("enabled", c_uint8),
        ("_pad",    c_uint8),
        ("addr_lo", c_uint32),
        ("addr_hi", c_uint32),
        ("comment", c_char_p),
    ]


BP_EXEC  = 0
BP_READ  = 1
BP_WRITE = 2

_bind("kintsuki_project_bp_add",      c_int,    [HANDLE, c_uint8, c_uint32, c_uint32, c_int, c_int, c_char_p])
_bind("kintsuki_project_bp_remove",   None,     [HANDLE, c_uint32])
_bind("kintsuki_project_bp_clear",    None,     [HANDLE])
_bind("kintsuki_project_bp_count",    c_uint32, [HANDLE])
_bind("kintsuki_project_bp_snapshot", c_uint32, [HANDLE, POINTER(ProjectBp), c_uint32])


# Re-exports for convenience.
lib = _lib
