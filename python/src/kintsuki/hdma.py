"""Pure-Python HDMA table simulator.

Walks a direct-mode HDMA table the same way the SNES PPU would, so tests
can assert what value the destination register would see on each
scanline of the visible frame, without rendering or even running the
emulator. Useful when the actual bug is "all bands wrote the same value
because the modulo math collapsed" — pixel oracles can't distinguish
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

Other modes (1, 3, 4, ...) raise NotImplementedError until needed —
better to fail loudly than silently return wrong values.
"""

from __future__ import annotations

import struct

NTSC_VISIBLE_SCANLINES = 224

_BYTES_PER_UNIT = {
    0: 1,  # 1 byte to 1 register
    2: 2,  # 2 bytes to 1 register (BG?VOFS, etc.)
}


def simulate_direct(table: bytes, *, transfer_mode: int = 2,
                    visible_scanlines: int = NTSC_VISIBLE_SCANLINES) -> list[int]:
    """Walk a direct-mode HDMA table; return one value per visible scanline.

    Each entry: 1-byte line counter + N-byte unit data (N = bytes-per-unit
    for the given transfer mode). Output is `visible_scanlines` long,
    padded with the last seen value once the table terminates.
    """
    if transfer_mode not in _BYTES_PER_UNIT:
        raise NotImplementedError(
            f"transfer_mode {transfer_mode} not supported yet "
            f"(supported: {sorted(_BYTES_PER_UNIT)})")
    bpu = _BYTES_PER_UNIT[transfer_mode]
    fmt = "<B" if bpu == 1 else "<H"

    def _read_unit(buf: bytes, off: int) -> tuple[int, int]:
        (val,) = struct.unpack_from(fmt, buf, off)
        return val, off + bpu

    out: list[int] = []
    last_value = 0
    pos = 0
    while pos < len(table) and len(out) < visible_scanlines:
        line_counter = table[pos]
        pos += 1
        if line_counter == 0:
            break  # terminator
        if line_counter & 0x80:
            # Repeat mode: write fresh unit each scanline.
            count = line_counter & 0x7F
            for _ in range(count):
                if len(out) >= visible_scanlines:
                    break
                if pos + bpu > len(table):
                    break
                last_value, pos = _read_unit(table, pos)
                out.append(last_value)
        else:
            # Non-repeat: write once, hold for `count` scanlines.
            count = line_counter
            if pos + bpu > len(table):
                break
            last_value, pos = _read_unit(table, pos)
            for _ in range(count):
                if len(out) >= visible_scanlines:
                    break
                out.append(last_value)

    # Pad remaining scanlines with the last latched value.
    while len(out) < visible_scanlines:
        out.append(last_value)
    return out
