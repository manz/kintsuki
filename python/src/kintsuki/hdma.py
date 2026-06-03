"""Pure-Python HDMA table simulator.

Walks a direct-mode HDMA table the same way the SNES PPU would, so tests
can assert what value the destination register would see on each
scanline of the visible frame, without rendering or even running the
emulator. Useful when the actual bug is "all bands wrote the same value
because the modulo math collapsed" - pixel oracles can't distinguish
that from "the right value happened to render the same."

Entry format (per fullsnes / SnesLab):

    line_counter:
        0x00      → end-of-table terminator
        0x01..0x80 → non-repeating: write 1 unit, hold for `count` lines
        0x81..0xFF → repeating: write 1 unit per line for (count-0x80)
                     scanlines, advancing through the data buffer

Transfer mode dictates bytes-per-unit:
    0: 1 byte  (1 reg)
    2: 2 bytes (1 reg, e.g. BG?VOFS double-write semantics)

Other modes (1, 3, 4, ...) raise NotImplementedError until needed - better to fail loudly than silently return wrong values.
"""

from __future__ import annotations

NTSC_VISIBLE_SCANLINES = 224

# Bytes per write-unit by transfer mode (fullsnes). Modes 3/4/5/7 are
# multi-register (BGxSC mode 4 = $2107-$210A; scroll mode 3 = 2 regs x 2-byte
# double-write), so a "unit" is several bytes - use simulate_units for those.
_BYTES_PER_UNIT = {0: 1, 1: 2, 2: 2, 3: 4, 4: 4, 5: 4, 6: 2, 7: 4}


def simulate_units(table: bytes, *, transfer_mode: int,
                   visible_scanlines: int = NTSC_VISIBLE_SCANLINES) -> list[bytes]:
    """Walk a direct-mode HDMA table; return the raw write-unit (``bytes`` of
    length bytes-per-unit) seen on each visible scanline.

    Supports every transfer mode, including the multi-register ones CT uses for
    its window band (BGxSC mode 4, scroll mode 3, TM/TS mode 4). The caller
    splits the unit bytes across the destination registers ($21xx, $21xx+1, ...).
    Direct mode only - for indirect tables (ctrl & 0x40) the entries are
    pointers and the data lives elsewhere; decode that separately.
    """
    if transfer_mode not in _BYTES_PER_UNIT:
        raise NotImplementedError(
            f"transfer_mode {transfer_mode} unknown "
            f"(supported: {sorted(_BYTES_PER_UNIT)})")
    bpu = _BYTES_PER_UNIT[transfer_mode]

    out: list[bytes] = []
    last = bytes(bpu)
    pos = 0
    while pos < len(table) and len(out) < visible_scanlines:
        line_counter = table[pos]
        pos += 1
        if line_counter == 0:
            break  # terminator
        if line_counter & 0x80:
            # Repeat: a fresh unit per scanline for (count) lines.
            count = line_counter & 0x7F
            for _ in range(count):
                if len(out) >= visible_scanlines or pos + bpu > len(table):
                    break
                last = bytes(table[pos:pos + bpu])
                pos += bpu
                out.append(last)
        else:
            # Non-repeat: read ONE unit (it follows the count byte), hold it.
            count = line_counter
            if pos + bpu > len(table):
                break
            last = bytes(table[pos:pos + bpu])
            pos += bpu
            for _ in range(count):
                if len(out) >= visible_scanlines:
                    break
                out.append(last)

    while len(out) < visible_scanlines:
        out.append(last)
    return out


def simulate_direct(table: bytes, *, transfer_mode: int = 2,
                    visible_scanlines: int = NTSC_VISIBLE_SCANLINES) -> list[int]:
    """Walk a direct-mode HDMA table; return one int value per visible scanline.

    Convenience over :func:`simulate_units` for the 1- and 2-byte modes (a
    single destination register). For multi-register modes (3/4/...) use
    :func:`simulate_units` and split the unit bytes yourself.
    """
    bpu = _BYTES_PER_UNIT.get(transfer_mode)
    if bpu not in (1, 2):
        raise NotImplementedError(
            f"transfer_mode {transfer_mode} is multi-register; "
            f"use simulate_units (supported here: modes with 1-2 byte units)")
    units = simulate_units(table, transfer_mode=transfer_mode,
                           visible_scanlines=visible_scanlines)
    return [int.from_bytes(u, "little") for u in units]
