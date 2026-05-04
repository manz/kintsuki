"""Structural oracles for layer / DMA / HDMA assertions.

One-liners for the most common "is this register configured the way I
expect?" checks. Catches treasure-rolling-class bugs (layer disabled,
ch5 dest stomped, HDMA band collapsed to one scroll) before pixel
oracles even need to run.

The oracles take duck-typed `PpuState`-like objects so they compose
with both real `Emu.get_ppu_state()` snapshots and test stubs.
"""

from __future__ import annotations

from typing import Any

from .hdma import simulate_direct


def assert_layer_visible(ppu: Any, layer: int, *,
                         screen: str = "main") -> None:
    """Assert a BG layer (1..4) is enabled on the main or sub screen.

    Reads bit `(layer - 1)` of `ppu.tm` (main) or `ppu.ts` (sub).
    """
    if not 1 <= layer <= 4:
        raise ValueError(f"layer must be in 1..4, got {layer}")
    if screen not in ("main", "sub"):
        raise ValueError(f"screen must be 'main' or 'sub', got {screen!r}")
    field = "tm" if screen == "main" else "ts"
    mask = getattr(ppu, field)
    bit = 1 << (layer - 1)
    if not (mask & bit):
        raise AssertionError(
            f"BG{layer} not on {screen} screen: ${field}=${mask:02X} "
            f"(want bit {layer - 1} set)")


def assert_hdma_channel(ppu: Any, ch: int, *,
                        ctrl: int | None = None,
                        dest: int | None = None,
                        src_addr: int | None = None,
                        src_bank: int | None = None,
                        enabled: int | None = None) -> None:
    """Assert DMA/HDMA channel `ch` (0..7) matches the supplied fields.

    Only fields passed as kwargs are checked — pass just the ones you
    care about. Errors include the offending field name + expected vs
    actual hex value.
    """
    if not 0 <= ch < 8:
        raise ValueError(f"ch must be in 0..7, got {ch}")
    channel = ppu.dma[ch]
    expected = {
        "ctrl": ctrl, "dest": dest,
        "src_addr": src_addr, "src_bank": src_bank,
        "enabled": enabled,
    }
    mismatches: list[str] = []
    for fld, want in expected.items():
        if want is None:
            continue
        got = getattr(channel, fld)
        if got != want:
            mismatches.append(f"  {fld}: want ${want:04X} got ${got:04X}")
    if mismatches:
        raise AssertionError(
            f"DMA channel {ch} mismatch:\n" + "\n".join(mismatches))


def assert_hdma_band_at_scanline(table: bytes, scanline: int, expected: int,
                                 *, transfer_mode: int = 2) -> None:
    """Assert the HDMA table's effective output value at a given visible
    scanline equals `expected`. Uses `kintsuki.hdma.simulate_direct`.

    Catches "all bands collapsed to the same scroll" structurally, before
    rendering.
    """
    out = simulate_direct(table, transfer_mode=transfer_mode)
    if not 0 <= scanline < len(out):
        raise ValueError(
            f"scanline {scanline} out of range (table covers 0..{len(out)-1})")
    got = out[scanline]
    if got != expected:
        raise AssertionError(
            f"HDMA value at scanline {scanline}: "
            f"want 0x{expected:04X}, got 0x{got:04X}")
