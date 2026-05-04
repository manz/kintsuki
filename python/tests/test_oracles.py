"""Phase 4f — structural oracles for layer / DMA / HDMA assertions.

Wraps common "is this register configured the way I expect?" checks
into one-liners that fail with actionable error messages. Catches
treasure-rolling-class bugs (layer disabled, ch5 dest stomped, HDMA
band collapsed to one scroll) before the visual oracle has to.
"""

from __future__ import annotations

import struct

import pytest

from kintsuki.oracles import (
    assert_hdma_band_at_scanline,
    assert_hdma_channel,
    assert_layer_visible,
)


# Minimal stand-ins for PpuState / DmaChannelState — the oracles only
# care about the documented attribute names, not the real types.
class _Ch:
    def __init__(self, ctrl: int = 0, dest: int = 0, src_addr: int = 0,
                 src_bank: int = 0, enabled: int = 0) -> None:
        self.ctrl = ctrl
        self.dest = dest
        self.src_addr = src_addr
        self.src_bank = src_bank
        self.enabled = enabled


class _Ppu:
    def __init__(self, *, tm: int = 0, ts: int = 0,
                 dma: list[_Ch] | None = None) -> None:
        self.tm = tm
        self.ts = ts
        self.dma = dma or [_Ch() for _ in range(8)]


def test_assert_layer_visible_main():
    p = _Ppu(tm=0b0000_0100)  # BG3 main
    assert_layer_visible(p, layer=3)


def test_assert_layer_visible_fails_when_off():
    p = _Ppu(tm=0)
    with pytest.raises(AssertionError, match="BG3.*main"):
        assert_layer_visible(p, layer=3)


def test_assert_layer_visible_sub():
    p = _Ppu(ts=0b0000_0010)  # BG2 sub
    assert_layer_visible(p, layer=2, screen="sub")


def test_assert_hdma_channel_matches():
    dma = [_Ch() for _ in range(8)]
    dma[5] = _Ch(ctrl=0x02, dest=0x12, src_addr=0x9800, src_bank=0x7E, enabled=1)
    p = _Ppu(dma=dma)
    assert_hdma_channel(p, ch=5,
                        ctrl=0x02, dest=0x12, src_addr=0x9800,
                        src_bank=0x7E, enabled=1)


def test_assert_hdma_channel_mismatch_lists_field():
    """Failure message names the offending field + expected vs actual."""
    dma = [_Ch() for _ in range(8)]
    dma[5] = _Ch(ctrl=0x02, dest=0x1E, src_addr=0x9800,
                 src_bank=0x7E, enabled=1)
    p = _Ppu(dma=dma)
    with pytest.raises(AssertionError, match="dest"):
        assert_hdma_channel(p, ch=5, dest=0x12)


def test_assert_hdma_channel_only_checks_provided_kwargs():
    """Only fields passed as kwargs are asserted; the rest are ignored
    (oracle should be composable without forcing the caller to specify
    every register)."""
    dma = [_Ch() for _ in range(8)]
    dma[5] = _Ch(ctrl=0x02, dest=0x12, src_addr=0xBEEF, src_bank=0x7F)
    p = _Ppu(dma=dma)
    # Only dest matters here; src_addr/src_bank are ignored.
    assert_hdma_channel(p, ch=5, dest=0x12)


def test_assert_hdma_band_at_scanline():
    """Walks an HDMA-table buffer + checks effective VOFS at a scanline.
    Builds on `kintsuki.hdma.simulate_direct`."""
    # Two bands: 8 sl @ 0xAAAA, 16 sl @ 0xBBBB
    table = struct.pack("<BHBH", 0x08, 0xAAAA, 0x10, 0xBBBB) + b"\x00"
    assert_hdma_band_at_scanline(table, scanline=4, expected=0xAAAA)
    assert_hdma_band_at_scanline(table, scanline=10, expected=0xBBBB)


def test_assert_hdma_band_at_scanline_fails_with_diff():
    table = struct.pack("<BH", 0x10, 0x1234) + b"\x00"
    with pytest.raises(AssertionError, match="0x1234"):
        assert_hdma_band_at_scanline(table, scanline=5, expected=0xFF88)
