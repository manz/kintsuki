"""kintsuki — Pythonic wrapper around the bsnes-derived SNES emulator core.

>>> emu = kintsuki.Emu()
>>> emu.load_rom("ff4.sfc")
>>> emu.run_frames(60)
>>> emu.read(0x7E1700)
3
"""

from __future__ import annotations

import ctypes
import os
import re
from dataclasses import dataclass
from typing import Callable

from . import _native
from ._native import CB_EXEC, CB_READ, CB_WRITE, CpuState, PpuStateRaw, DmaChannelRaw

__version__ = "0.1.0"

__all__ = [
    "Emu",
    "Button",
    "CpuState",
    "PpuState",
    "DmaChannelState",
    "CallbackKind",
    "SymbolTable",
]


@dataclass(frozen=True)
class DmaChannelState:
    """One DMA / HDMA channel snapshot. Mirrors `kintsuki_dma_channel_t`."""

    ctrl: int        # $43xa low (mode | indirect | direction etc.)
    dest: int        # $43xb BBADx (PPU register $21XX low byte)
    src_addr: int    # $43xc-d
    src_bank: int    # $43xe
    ind_count: int   # $43xf-g (transferSize / indirectAddress)
    ind_bank: int    # $43xh
    line_count: int  # $43xa internal counter
    enabled: int     # 1 if the HDMAEN bit for this channel is set


@dataclass(frozen=True)
class PpuState:
    """PPU IO + per-channel HDMA snapshot. All fields are write-only on the
    SNES bus, so this is the only practical way to inspect them in Python."""

    inidisp: int
    bgmode: int
    mosaic: int
    bg1sc: int
    bg2sc: int
    bg3sc: int
    bg4sc: int
    bg12nba: int
    bg34nba: int
    bg1hofs: int
    bg1vofs: int
    bg2hofs: int
    bg2vofs: int
    bg3hofs: int
    bg3vofs: int
    bg4hofs: int
    bg4vofs: int
    vmain: int
    vmaddr: int
    m7sel: int
    m7a: int
    m7b: int
    m7c: int
    m7d: int
    m7x: int
    m7y: int
    cgadd: int
    tm: int
    ts: int
    tmw: int
    tsw: int
    cgwsel: int
    cgadsub: int
    setini: int
    hcounter: int
    vcounter: int
    dma: tuple  # 8x DmaChannelState
    mdmaen: int
    hdmaen: int

    @classmethod
    def _from_raw(cls, raw: PpuStateRaw) -> "PpuState":
        dma = tuple(
            DmaChannelState(
                ctrl=raw.dma[i].ctrl,
                dest=raw.dma[i].dest,
                src_addr=raw.dma[i].src_addr,
                src_bank=raw.dma[i].src_bank,
                ind_count=raw.dma[i].ind_count,
                ind_bank=raw.dma[i].ind_bank,
                line_count=raw.dma[i].line_count,
                enabled=raw.dma[i].enabled,
            )
            for i in range(8)
        )
        return cls(
            inidisp=raw.inidisp, bgmode=raw.bgmode, mosaic=raw.mosaic,
            bg1sc=raw.bg1sc, bg2sc=raw.bg2sc, bg3sc=raw.bg3sc, bg4sc=raw.bg4sc,
            bg12nba=raw.bg12nba, bg34nba=raw.bg34nba,
            bg1hofs=raw.bg1hofs, bg1vofs=raw.bg1vofs,
            bg2hofs=raw.bg2hofs, bg2vofs=raw.bg2vofs,
            bg3hofs=raw.bg3hofs, bg3vofs=raw.bg3vofs,
            bg4hofs=raw.bg4hofs, bg4vofs=raw.bg4vofs,
            vmain=raw.vmain, vmaddr=raw.vmaddr,
            m7sel=raw.m7sel,
            m7a=raw.m7a, m7b=raw.m7b, m7c=raw.m7c, m7d=raw.m7d,
            m7x=raw.m7x, m7y=raw.m7y,
            cgadd=raw.cgadd,
            tm=raw.tm, ts=raw.ts, tmw=raw.tmw, tsw=raw.tsw,
            cgwsel=raw.cgwsel, cgadsub=raw.cgadsub, setini=raw.setini,
            hcounter=raw.hcounter, vcounter=raw.vcounter,
            dma=dma, mdmaen=raw.mdmaen, hdmaen=raw.hdmaen,
        )

    # --- Convenience helpers ------------------------------------------------
    def bg_main_enabled(self, layer: int) -> bool:
        """layer ∈ {1,2,3,4} → check TM bit. Layer 5 = OBJ."""
        return bool(self.tm & (1 << (layer - 1)))

    def bg_sub_enabled(self, layer: int) -> bool:
        return bool(self.ts & (1 << (layer - 1)))

    def bg_vofs(self, layer: int) -> int:
        return getattr(self, f"bg{layer}vofs")

    def bg_hofs(self, layer: int) -> int:
        return getattr(self, f"bg{layer}hofs")

    def bg_tilemap_word_base(self, layer: int) -> int:
        """Tilemap base address as a VRAM word offset (i.e. ($21xxSC>>2)<<10)."""
        sc = getattr(self, f"bg{layer}sc")
        return (sc & 0xFC) << 8


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


VRAM_BYTES = 0x10000   # 64 KB, byte-addressed
CGRAM_BYTES = 0x200    # 256 colors × 2 bytes
OAM_BYTES = 0x220      # 512 B sprite table + 32 B high table


class Emu:
    """High-level wrapper. Single-instance for now (bsnes core uses globals)."""

    # Process-wide default for the .srm-sidecar auto-seed at load_rom
    # time. Emu(load_srm_sidecar=...) overrides per instance; tests flip
    # this class attribute in conftest so a stray fixture .srm doesn't
    # leak into the deterministic SRAM the harness expects.
    default_load_srm_sidecar: bool = True

    def __init__(self, *, load_srm_sidecar: bool | None = None) -> None:
        h = _native.lib.kintsuki_create()
        if not h:
            raise RuntimeError("kintsuki_create failed")
        self._handle = h
        self._registered: list[_Registered] = []
        on = Emu.default_load_srm_sidecar if load_srm_sidecar is None else load_srm_sidecar
        _native.lib.kintsuki_set_srm_sidecar(self._handle, 1 if on else 0)

    # ------------------------------------------------------------------ ROM
    def load_rom(self, path: str, *, adbg: str | os.PathLike[str] | None = None) -> None:
        """Load `path` (sfc/smc). Pass `adbg=...` to also load LABEL symbols
        from an a816 ``.adbg`` debug-info file — the native tracer then
        injects ``; --- name ---`` headers above matching PC lines and
        callers can resolve addresses via :meth:`lookup_label`."""
        ok = _native.lib.kintsuki_load_rom(self._handle, path.encode("utf-8"))
        if not ok:
            raise RuntimeError(f"failed to load ROM: {path}")
        if adbg is not None:
            self.load_adbg(adbg)

    def load_adbg(self, path: str | os.PathLike[str]) -> None:
        """Load an ``.adbg`` debug-info file (LABEL symbols only). Replaces
        any previously-loaded table. Raises ``RuntimeError`` on bad magic /
        unsupported version / I/O failure."""
        encoded = os.fsencode(path)
        if not _native.lib.kintsuki_load_adbg(self._handle, encoded):
            raise RuntimeError(f"failed to load .adbg: {os.fspath(path)}")

    def clear_adbg(self) -> None:
        _native.lib.kintsuki_clear_adbg(self._handle)

    def lookup_label(self, addr: int) -> str | None:
        """Return the label bound to *exactly* ``addr`` (24-bit), or
        ``None``. Use :meth:`lookup_label_containing` for "which routine
        is this PC inside" — exact match is rarely what you want for a
        runtime PC."""
        raw = _native.lib.kintsuki_lookup_label(self._handle, addr & 0xFFFFFF)
        return raw.decode("utf-8") if raw else None

    def lookup_label_containing(self, addr: int) -> tuple[str, int] | None:
        """Return ``(name, offset)`` for the label whose address is the
        largest ≤ ``addr`` (i.e. the routine ``addr`` lives inside).
        ``offset`` is bytes past the label start. ``None`` when no
        label precedes ``addr``."""
        offset = ctypes.c_uint32(0)
        raw = _native.lib.kintsuki_lookup_label_containing(
            self._handle, addr & 0xFFFFFF, ctypes.byref(offset))
        return (raw.decode("utf-8"), int(offset.value)) if raw else None

    def lookup_symbol_addr(self, name: str) -> int | None:
        """Reverse symbol lookup: return the 24-bit address bound to
        ``name`` in the loaded ``.adbg`` table, or ``None`` if no label
        by that name exists."""
        out = ctypes.c_uint32(0)
        ok = _native.lib.kintsuki_lookup_symbol_addr(
            self._handle, name.encode("utf-8"), ctypes.byref(out))
        return int(out.value) if ok else None

    def tracer_set_ranges(self, ranges: list[tuple[int, int]] | None) -> None:
        """Mask tracer emission to PC ranges. Each ``(start, size)``
        describes a half-open ``[start, start+size)`` range; a line
        fires only when PC falls in any range. Pass ``None`` or an
        empty list to clear the mask and fall back to the
        ``tracer_start(lo, hi)`` window. Sticky across stop/start."""
        if not ranges:
            _native.lib.kintsuki_tracer_set_ranges(self._handle, None, 0)
            return
        buf = (_native.TraceRange * len(ranges))()
        for i, (start, size) in enumerate(ranges):
            buf[i].start = start & 0xFFFFFF
            buf[i].size = size
        _native.lib.kintsuki_tracer_set_ranges(self._handle, buf, len(ranges))

    def tracer_mask_symbols(self, symbols: list[tuple[str, int]]) -> list[str]:
        """Convenience: resolve each ``(symbol_name, size)`` against the
        loaded ``.adbg``, then apply :meth:`tracer_set_ranges`. Returns
        the list of names that *failed* to resolve (caller can warn /
        bail). Symbols with no match are silently skipped — the trace
        is still scoped to the symbols that did resolve."""
        ranges: list[tuple[int, int]] = []
        unresolved: list[str] = []
        for name, size in symbols:
            addr = self.lookup_symbol_addr(name)
            if addr is None:
                unresolved.append(name)
                continue
            ranges.append((addr, size))
        self.tracer_set_ranges(ranges)
        return unresolved

    def lookup_source(self, addr: int) -> tuple[str, int, int] | None:
        """Resolve ``addr`` to ``(file, line, column)`` via the loaded
        ``.adbg`` LINES section. Returns ``None`` when no covering
        record exists (no ``.adbg`` loaded, address below the first
        emitted line, or LINES section absent)."""
        cfile = ctypes.c_char_p()
        cline = ctypes.c_uint32(0)
        ccol = ctypes.c_uint16(0)
        ok = _native.lib.kintsuki_lookup_source(
            self._handle, addr & 0xFFFFFF,
            ctypes.byref(cfile), ctypes.byref(cline), ctypes.byref(ccol))
        if not ok or cfile.value is None:
            return None
        return cfile.value.decode("utf-8"), int(cline.value), int(ccol.value)

    def callstack(self, max_frames: int = 256) -> list[tuple[int, int, int]]:
        """Snapshot the shadow callstack (deepest frame first). Each entry
        is ``(callsite_pc, target_pc, kind)`` where kind is 0=JSR / 1=JSL.
        Empty when nothing has been called yet (or after ``load_state``)."""
        if max_frames <= 0:
            return []
        buf = (_native.CallFrame * max_frames)()
        n = _native.lib.kintsuki_callstack_snapshot(self._handle, buf, max_frames)
        return [(buf[i].callsite_pc, buf[i].target_pc, buf[i].kind)
                for i in range(n)]

    def callstack_clear(self) -> None:
        _native.lib.kintsuki_callstack_clear(self._handle)

    # ----------------------------------------------------------------- DMA log
    def dma_transfers(self, max_entries: int = 64) -> list[dict]:
        """Snapshot the DMA transfer ring (most-recent first). Each
        entry is dict-shaped: ``src_addr`` (24-bit), ``size``,
        ``channel``, ``direction`` (0=CPU→PPU, 1=PPU→CPU), ``mode``
        (0..7), ``dst_reg`` (PPU $21XX low byte), ``hits``,
        ``last_frame``. Deduplication on (src+dst+size) happens on
        the C side, so a per-frame buffer push collapses to one
        entry whose ``hits`` count grows."""
        cap = max_entries
        buf = (_native.DmaEvent * cap)()
        n = _native.lib.kintsuki_dma_log_snapshot(self._handle, buf, cap)
        out: list[dict] = []
        for i in range(n):
            e = buf[i]
            out.append({
                "src_addr":   int(e.src_addr),
                "size":       int(e.size),
                "channel":    int(e.channel),
                "direction":  int(e.direction),
                "mode":       int(e.mode),
                "dst_reg":    int(e.dst_reg),
                "vram_addr":  int(e.vram_addr),
                "hits":       int(e.hits),
                "last_frame": int(e.last_frame),
            })
        return out

    def dma_log_clear(self) -> None:
        _native.lib.kintsuki_dma_log_clear(self._handle)

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

    def read_range(self, addr: int, length: int) -> memoryview:
        """Bulk CPU-bus read. Returns a ``memoryview`` over a freshly-
        allocated ctypes buffer — zero-copy on the Python side, callers
        can ``bytes(mv)`` if they need an owned buffer. The underlying
        storage stays alive for the memoryview's lifetime."""
        buf = (ctypes.c_uint8 * length)()
        n = _native.lib.kintsuki_read_range(self._handle, addr, length, buf)
        return memoryview(buf)[:n]

    def write_range(self, addr: int, data: bytes | bytearray) -> None:
        """Bulk write `data` starting at `addr` (CPU bus, 24-bit). Useful
        for dropping assembled stubs into WRAM as test harnesses."""
        buf = (ctypes.c_uint8 * len(data))(*data)
        _native.lib.kintsuki_write_range(self._handle, addr, len(data), buf)

    # PPU memory
    def vram_read(self, addr: int) -> int:
        return int(_native.lib.kintsuki_vram_read(self._handle, addr))

    def vram_write(self, addr: int, value: int) -> None:
        _native.lib.kintsuki_vram_write(self._handle, addr, value & 0xFF)

    def vram_read_range(self, addr: int = 0, length: int | None = None) -> memoryview:
        """Default: full 64 KB VRAM dump from `addr`. Returns a memoryview
        over the underlying ctypes buffer (zero-copy)."""
        if length is None:
            length = VRAM_BYTES - addr
        buf = (ctypes.c_uint8 * length)()
        n = _native.lib.kintsuki_vram_read_range(self._handle, addr, length, buf)
        return memoryview(buf)[:n]

    def vram_write_range(self, addr: int, data: bytes | bytearray) -> None:
        buf = (ctypes.c_uint8 * len(data))(*data)
        _native.lib.kintsuki_vram_write_range(self._handle, addr, len(data), buf)

    def cgram_read(self, addr: int) -> int:
        return int(_native.lib.kintsuki_cgram_read(self._handle, addr))

    def cgram_write(self, addr: int, value: int) -> None:
        _native.lib.kintsuki_cgram_write(self._handle, addr, value & 0xFF)

    def cgram_read_range(self, addr: int = 0, length: int | None = None) -> memoryview:
        """Default: full 512 B CGRAM dump from `addr`. Returns a memoryview
        over the underlying ctypes buffer (zero-copy)."""
        if length is None:
            length = CGRAM_BYTES - addr
        buf = (ctypes.c_uint8 * length)()
        n = _native.lib.kintsuki_cgram_read_range(self._handle, addr, length, buf)
        return memoryview(buf)[:n]

    def cgram_write_range(self, addr: int, data: bytes | bytearray) -> None:
        buf = (ctypes.c_uint8 * len(data))(*data)
        _native.lib.kintsuki_cgram_write_range(self._handle, addr, len(data), buf)

    def oam_read(self, addr: int) -> int:
        return int(_native.lib.kintsuki_oam_read(self._handle, addr))

    def oam_write(self, addr: int, value: int) -> None:
        _native.lib.kintsuki_oam_write(self._handle, addr, value & 0xFF)

    def oam_read_range(self, addr: int = 0, length: int | None = None) -> memoryview:
        """Default: full 544 B OAM dump (512 sprite + 32 high) from `addr`.
        Returns a memoryview over the underlying ctypes buffer (zero-copy)."""
        if length is None:
            length = OAM_BYTES - addr
        buf = (ctypes.c_uint8 * length)()
        n = _native.lib.kintsuki_oam_read_range(self._handle, addr, length, buf)
        return memoryview(buf)[:n]

    def oam_write_range(self, addr: int, data: bytes | bytearray) -> None:
        buf = (ctypes.c_uint8 * len(data))(*data)
        _native.lib.kintsuki_oam_write_range(self._handle, addr, len(data), buf)

    # ------------------------------------------------------------ CPU state
    def get_state(self) -> CpuState:
        s = CpuState()
        _native.lib.kintsuki_get_state(self._handle, ctypes.byref(s))
        return s

    def get_ppu_state(self) -> PpuState:
        """Snapshot of write-only PPU IO registers + per-channel DMA state.
        Returned as an immutable dataclass — read-only view of ares globals."""
        raw = PpuStateRaw()
        _native.lib.kintsuki_get_ppu_state(self._handle, ctypes.byref(raw))
        return PpuState._from_raw(raw)

    # ----------------------------------------------------------------- Tracer
    def tracer_start(self, lo: int, hi: int, *, ring_capacity: int = 4096,
                     path: str | None = None) -> None:
        """Start the formatted execution tracer over [lo, hi]. RING mode by
        default (lines kept in a `ring_capacity`-byte buffer, oldest evicted
        on overflow). Pass `path=...` to write lines to disk instead."""
        mode = _native.TRACE_FILE if path else _native.TRACE_RING
        cpath = path.encode("utf-8") if path else None
        _native.lib.kintsuki_tracer_start(
            self._handle, lo, hi, mode, cpath, ring_capacity)

    def tracer_stop(self) -> None:
        _native.lib.kintsuki_tracer_stop(self._handle)

    def tracer_drain(self) -> str:
        """Pull and clear the ring buffer's accumulated lines. FILE mode
        always returns ``''``. Lines are already annotated with
        ``; --- name ---`` headers natively when an ``.adbg`` is loaded
        (see :meth:`load_adbg`)."""
        # First call: query required size with cap=0.
        size = _native.lib.kintsuki_tracer_drain(self._handle, None, 0)
        if size == 0:
            return ""
        buf = ctypes.create_string_buffer(size)
        n = _native.lib.kintsuki_tracer_drain(self._handle, buf, size)
        return bytes(buf.raw[:n]).decode("utf-8", errors="replace")

    def tracer(self, lo: int, hi: int, *, ring_capacity: int = 4096,
               path: str | None = None) -> "_TracerSession":
        """Context-manager wrapper. `with emu.tracer(lo, hi) as tr: tr.drain()`."""
        return _TracerSession(self, lo, hi,
                              ring_capacity=ring_capacity, path=path)

    # ------------------------------------------------------------- Reset / SRAM
    def reset(self) -> None:
        """Soft reset (power-cycle) the emulator without re-reading the ROM
        from disk. Preserves cart SRAM."""
        _native.lib.kintsuki_reset(self._handle)

    def inject_sram(self, data: bytes) -> int:
        """Copy `data` into the cart's in-memory SRAM. The original `.srm`
        file (if any) is never touched. Returns bytes copied (clamped to
        cart SRAM size)."""
        if not data:
            return 0
        buf = (ctypes.c_uint8 * len(data))(*data)
        return _native.lib.kintsuki_inject_sram(self._handle, buf, len(data))

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
        """Returns ``(raw_bytes, width, height)``. Each pixel is a
        little-endian ``uint32`` packed ``0x00RRGGBB``, so on disk the
        bytes read as ``B G R 0`` per pixel — not canonical RGBA. Use
        :meth:`screenshot` to write a properly-encoded RGB PNG, or
        :func:`kintsuki.visual.golden` for record-or-compare assertions
        (both share the same hires-aware C path).

        Hires-aware: ares' performance PPU always emits a 564-pixel-wide
        framebuffer to keep the renderer letterbox math simple. In normal
        mode every other column is just a duplicate of the previous one,
        so we collapse to single columns (yielding ~282 width). In
        hires (BGMODE 5/6) or pseudo-hires mode the doubled columns
        carry distinct data and we keep them.

        Returned bytes are an owned copy; the underlying buffer is valid
        only until the next ``run_*`` call."""
        w = ctypes.c_uint32(0)
        h = ctypes.c_uint32(0)
        ptr = _native.lib.kintsuki_framebuffer(
            self._handle, ctypes.byref(w), ctypes.byref(h)
        )
        if not ptr or not w.value or not h.value:
            return (b"", 0, 0)
        raw = ctypes.string_at(ptr, w.value * h.value * 4)
        if _native.lib.kintsuki_ppu_hires(self._handle):
            return (raw, int(w.value), int(h.value))
        # Normal-mode collapse: keep every even column. ares' width is
        # always even (564), and ``array`` gives us a fast pure-stdlib
        # strided-take per row without falling into a per-pixel Python
        # loop.
        import array
        src = array.array("I")
        src.frombytes(raw)
        out_w = w.value // 2
        kept = array.array("I")
        for y in range(h.value):
            kept.extend(src[y * w.value : (y + 1) * w.value : 2])
        return (kept.tobytes(), int(out_w), int(h.value))

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


class _TracerSession:
    """Context-manager wrapper over the tracer C ABI. Starts on enter,
    stops on exit. `tr.drain()` is the same as `Emu.tracer_drain()`."""

    def __init__(self, emu: Emu, lo: int, hi: int, *,
                 ring_capacity: int, path: str | None) -> None:
        self._emu = emu
        self._lo = lo
        self._hi = hi
        self._ring_capacity = ring_capacity
        self._path = path

    def __enter__(self) -> "_TracerSession":
        self._emu.tracer_start(self._lo, self._hi,
                               ring_capacity=self._ring_capacity,
                               path=self._path)
        return self

    def __exit__(self, *_) -> None:
        self._emu.tracer_stop()

    def drain(self) -> str:
        return self._emu.tracer_drain()
