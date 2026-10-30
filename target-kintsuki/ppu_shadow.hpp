#pragma once
// IO shadow of the SNES PPU's $21xx register state. Both ares impls
// (ppu-performance, ppu) mirror every write here via shadowApplyWriteIO
// so kintsuki debug surfaces (ss_read, get_ppu_state) can read a single
// impl-agnostic struct instead of reaching into each impl's divergent
// internal layouts.
//
// Deliberately standalone: the shadow owns its own bgofs/mode7 latches,
// so a single call per writeIO reproduces every observable $21xx effect
// without touching ares internals. Fields are trivially copyable; the
// struct serializes as a flat byte dump in the KSSF footer.

#include <cstdint>
#include <cstring>

namespace kintsuki::ppu {

struct Shadow {
  // $2100 INIDISP
  uint8_t displayBrightness = 0;
  uint8_t displayDisable    = 1;

  // $2101 OBSEL
  uint8_t  objBaseSize        = 0;
  uint8_t  objNameselect      = 0;
  uint16_t objTiledataAddress = 0;

  // $2102/$2103 OAMADD
  uint16_t oamBaseAddress = 0;
  uint8_t  oamPriority    = 0;

  // $2105 BGMODE
  uint8_t bgMode     = 0;
  uint8_t bgPriority = 0;

  // $2106 MOSAIC
  uint8_t bg1MosaicEnable = 0, bg2MosaicEnable = 0,
          bg3MosaicEnable = 0, bg4MosaicEnable = 0;
  uint8_t mosaicSize = 1;

  struct Bg {
    uint8_t  tileSize        = 0;
    uint16_t screenAddress   = 0;
    uint8_t  screenSize      = 0;
    uint16_t tiledataAddress = 0;
    uint16_t hoffset         = 0;
    uint16_t voffset         = 0;
    uint8_t  aboveEnable     = 0;
    uint8_t  belowEnable     = 0;
  } bg1, bg2, bg3, bg4;

  // $212c/$212d/$2133 obj enables + interlace
  uint8_t objAboveEnable = 0;
  uint8_t objBelowEnable = 0;
  uint8_t objInterlace   = 0;

  // $2115 VMAIN
  uint8_t  vramIncrementSize = 1;  // 1 / 32 / 128
  uint8_t  vramMapping       = 0;
  uint8_t  vramMode          = 0;  // bit 7 of VMAIN
  // $2116/$2117 VMADDR
  uint16_t vramAddress = 0;

  // $211a..$2120 mode7
  uint8_t  mode7Hflip  = 0;
  uint8_t  mode7Vflip  = 0;
  uint8_t  mode7Repeat = 0;
  uint16_t mode7A      = 0;
  uint16_t mode7B      = 0;
  uint16_t mode7C      = 0;
  uint16_t mode7D      = 0;
  uint16_t mode7X      = 0;
  uint16_t mode7Y      = 0;
  uint16_t mode7Hoffset = 0;
  uint16_t mode7Voffset = 0;

  // $2121/$2122 CGRAM
  uint8_t cgramAddress      = 0;
  uint8_t cgramAddressLatch = 0;
  uint8_t cgramLatch        = 0;

  // $2123..$2125 window layer configs (W12SEL, W34SEL, WOBJSEL)
  struct WLayer {
    uint8_t oneInvert   = 0;
    uint8_t oneEnable   = 0;
    uint8_t twoInvert   = 0;
    uint8_t twoEnable   = 0;
    uint8_t mask        = 0;  // $212a/$212b per-layer mask
    uint8_t aboveEnable = 0;  // $212e
    uint8_t belowEnable = 0;  // $212f
  } wBg1, wBg2, wBg3, wBg4, wObj, wCol;

  // $2126..$2129 window bounds
  uint8_t wOneLeft = 0, wOneRight = 0, wTwoLeft = 0, wTwoRight = 0;

  // $2130 CGWSEL
  uint8_t dacDirectColor  = 0;
  uint8_t dacBlendMode    = 0;
  uint8_t dacWinAboveMask = 0;
  uint8_t dacWinBelowMask = 0;

  // $2131 CGADDSUB
  uint8_t colorMode     = 0;
  uint8_t colorHalve    = 0;
  uint8_t colorEnableBG1 = 0;
  uint8_t colorEnableBG2 = 0;
  uint8_t colorEnableBG3 = 0;
  uint8_t colorEnableBG4 = 0;
  uint8_t colorEnableOBJ = 0;
  uint8_t colorEnableCOL = 0;

  // $2132 COLDATA
  uint8_t colorRed = 0, colorGreen = 0, colorBlue = 0;

  // $2133 SETINI
  uint8_t interlace   = 0;
  uint8_t overscan    = 0;
  uint8_t pseudoHires = 0;
  uint8_t extbg       = 0;

  // Own copies of the latches the SNES uses to assemble 16-bit writes
  // from two 8-bit stores. Isolated from either impl's internal latches
  // so the shadow is self-sufficient.
  uint8_t latchBgofsPPU1 = 0;
  uint8_t latchBgofsPPU2 = 0;
  uint8_t latchMode7     = 0;

  auto reset() -> void { *this = Shadow(); }
};

extern Shadow shadow;

inline auto applyWriteIO(uint32_t address, uint8_t data) -> void {
  auto& s = shadow;
  auto bit = [&](int i) -> uint8_t { return (data >> i) & 1; };
  auto bits = [&](int lo, int hi) -> uint8_t {
    uint8_t m = (uint8_t)((1u << (hi - lo + 1)) - 1);
    return (data >> lo) & m;
  };
  switch(address & 0xffff) {
  case 0x2100:
    s.displayBrightness = bits(0, 3);
    s.displayDisable    = bit(7);
    return;
  case 0x2101:
    s.objTiledataAddress = (uint16_t)(bits(0, 2) << 13);
    s.objNameselect      = bits(3, 4);
    s.objBaseSize        = bits(5, 7);
    return;
  case 0x2102:
    s.oamBaseAddress = (uint16_t)((s.oamBaseAddress & ~0x1feu) | ((uint16_t)data << 1));
    return;
  case 0x2103:
    s.oamBaseAddress = (uint16_t)((s.oamBaseAddress & 0x1feu) | ((uint16_t)bit(0) << 9));
    s.oamPriority    = bit(7);
    return;
  case 0x2105:
    s.bgMode         = bits(0, 2);
    s.bgPriority     = bit(3);
    s.bg1.tileSize   = bit(4);
    s.bg2.tileSize   = bit(5);
    s.bg3.tileSize   = bit(6);
    s.bg4.tileSize   = bit(7);
    return;
  case 0x2106:
    s.bg1MosaicEnable = bit(0);
    s.bg2MosaicEnable = bit(1);
    s.bg3MosaicEnable = bit(2);
    s.bg4MosaicEnable = bit(3);
    s.mosaicSize      = (uint8_t)(bits(4, 7) + 1);
    return;
  case 0x2107:
    s.bg1.screenSize    = bits(0, 1);
    s.bg1.screenAddress = (uint16_t)(bits(2, 7) << 10);
    return;
  case 0x2108:
    s.bg2.screenSize    = bits(0, 1);
    s.bg2.screenAddress = (uint16_t)(bits(2, 7) << 10);
    return;
  case 0x2109:
    s.bg3.screenSize    = bits(0, 1);
    s.bg3.screenAddress = (uint16_t)(bits(2, 7) << 10);
    return;
  case 0x210a:
    s.bg4.screenSize    = bits(0, 1);
    s.bg4.screenAddress = (uint16_t)(bits(2, 7) << 10);
    return;
  case 0x210b:
    s.bg1.tiledataAddress = (uint16_t)(bits(0, 3) << 12);
    s.bg2.tiledataAddress = (uint16_t)(bits(4, 7) << 12);
    return;
  case 0x210c:
    s.bg3.tiledataAddress = (uint16_t)(bits(0, 3) << 12);
    s.bg4.tiledataAddress = (uint16_t)(bits(4, 7) << 12);
    return;
  case 0x210d:
    s.mode7Hoffset = (uint16_t)((data << 8) | s.latchMode7);
    s.latchMode7 = data;
    s.bg1.hoffset = (uint16_t)((data << 8)
                             | (s.latchBgofsPPU1 & ~7)
                             | (s.latchBgofsPPU2 & 7));
    s.latchBgofsPPU1 = data;
    s.latchBgofsPPU2 = data;
    return;
  case 0x210e:
    s.mode7Voffset = (uint16_t)((data << 8) | s.latchMode7);
    s.latchMode7 = data;
    s.bg1.voffset = (uint16_t)((data << 8) | s.latchBgofsPPU1);
    s.latchBgofsPPU1 = data;
    return;
  case 0x210f:
    s.bg2.hoffset = (uint16_t)((data << 8)
                             | (s.latchBgofsPPU1 & ~7)
                             | (s.latchBgofsPPU2 & 7));
    s.latchBgofsPPU1 = data;
    s.latchBgofsPPU2 = data;
    return;
  case 0x2110:
    s.bg2.voffset = (uint16_t)((data << 8) | s.latchBgofsPPU1);
    s.latchBgofsPPU1 = data;
    return;
  case 0x2111:
    s.bg3.hoffset = (uint16_t)((data << 8)
                             | (s.latchBgofsPPU1 & ~7)
                             | (s.latchBgofsPPU2 & 7));
    s.latchBgofsPPU1 = data;
    s.latchBgofsPPU2 = data;
    return;
  case 0x2112:
    s.bg3.voffset = (uint16_t)((data << 8) | s.latchBgofsPPU1);
    s.latchBgofsPPU1 = data;
    return;
  case 0x2113:
    s.bg4.hoffset = (uint16_t)((data << 8)
                             | (s.latchBgofsPPU1 & ~7)
                             | (s.latchBgofsPPU2 & 7));
    s.latchBgofsPPU1 = data;
    s.latchBgofsPPU2 = data;
    return;
  case 0x2114:
    s.bg4.voffset = (uint16_t)((data << 8) | s.latchBgofsPPU1);
    s.latchBgofsPPU1 = data;
    return;
  case 0x2115: {
    static constexpr uint8_t sizeTbl[4] = {1, 32, 128, 128};
    s.vramIncrementSize = sizeTbl[bits(0, 1)];
    s.vramMapping       = bits(2, 3);
    s.vramMode          = bit(7);
    return;
  }
  case 0x2116:
    s.vramAddress = (uint16_t)((s.vramAddress & 0xff00) | data);
    return;
  case 0x2117:
    s.vramAddress = (uint16_t)((s.vramAddress & 0x00ff) | ((uint16_t)data << 8));
    return;
  case 0x2118: case 0x2119:
    // VMDATA bumps address when configured; mirror the live impl via facade
    // separately. The shadow doesn't need to track the bump; ss_read's
    // 0x16/0x17 cases serve the current address after any writeIO ran.
    return;
  case 0x211a:
    s.mode7Hflip  = bit(0);
    s.mode7Vflip  = bit(1);
    s.mode7Repeat = bits(6, 7);
    return;
  case 0x211b: s.mode7A = (uint16_t)((data << 8) | s.latchMode7); s.latchMode7 = data; return;
  case 0x211c: s.mode7B = (uint16_t)((data << 8) | s.latchMode7); s.latchMode7 = data; return;
  case 0x211d: s.mode7C = (uint16_t)((data << 8) | s.latchMode7); s.latchMode7 = data; return;
  case 0x211e: s.mode7D = (uint16_t)((data << 8) | s.latchMode7); s.latchMode7 = data; return;
  case 0x211f: s.mode7X = (uint16_t)((data << 8) | s.latchMode7); s.latchMode7 = data; return;
  case 0x2120: s.mode7Y = (uint16_t)((data << 8) | s.latchMode7); s.latchMode7 = data; return;
  case 0x2121:
    s.cgramAddress      = data;
    s.cgramAddressLatch = 0;
    return;
  case 0x2122:
    if(s.cgramAddressLatch++ == 0) {
      s.cgramLatch = data;
    } else {
      s.cgramAddress = (uint8_t)(s.cgramAddress + 1);
    }
    return;
  case 0x2123:
    s.wBg1.oneInvert = bit(0); s.wBg1.oneEnable = bit(1);
    s.wBg1.twoInvert = bit(2); s.wBg1.twoEnable = bit(3);
    s.wBg2.oneInvert = bit(4); s.wBg2.oneEnable = bit(5);
    s.wBg2.twoInvert = bit(6); s.wBg2.twoEnable = bit(7);
    return;
  case 0x2124:
    s.wBg3.oneInvert = bit(0); s.wBg3.oneEnable = bit(1);
    s.wBg3.twoInvert = bit(2); s.wBg3.twoEnable = bit(3);
    s.wBg4.oneInvert = bit(4); s.wBg4.oneEnable = bit(5);
    s.wBg4.twoInvert = bit(6); s.wBg4.twoEnable = bit(7);
    return;
  case 0x2125:
    s.wObj.oneInvert = bit(0); s.wObj.oneEnable = bit(1);
    s.wObj.twoInvert = bit(2); s.wObj.twoEnable = bit(3);
    s.wCol.oneInvert = bit(4); s.wCol.oneEnable = bit(5);
    s.wCol.twoInvert = bit(6); s.wCol.twoEnable = bit(7);
    return;
  case 0x2126: s.wOneLeft  = data; return;
  case 0x2127: s.wOneRight = data; return;
  case 0x2128: s.wTwoLeft  = data; return;
  case 0x2129: s.wTwoRight = data; return;
  case 0x212a:
    s.wBg1.mask = bits(0, 1);
    s.wBg2.mask = bits(2, 3);
    s.wBg3.mask = bits(4, 5);
    s.wBg4.mask = bits(6, 7);
    return;
  case 0x212b:
    s.wObj.mask = bits(0, 1);
    s.wCol.mask = bits(2, 3);
    return;
  case 0x212c:
    s.bg1.aboveEnable = bit(0);
    s.bg2.aboveEnable = bit(1);
    s.bg3.aboveEnable = bit(2);
    s.bg4.aboveEnable = bit(3);
    s.objAboveEnable  = bit(4);
    return;
  case 0x212d:
    s.bg1.belowEnable = bit(0);
    s.bg2.belowEnable = bit(1);
    s.bg3.belowEnable = bit(2);
    s.bg4.belowEnable = bit(3);
    s.objBelowEnable  = bit(4);
    return;
  case 0x212e:
    s.wBg1.aboveEnable = bit(0);
    s.wBg2.aboveEnable = bit(1);
    s.wBg3.aboveEnable = bit(2);
    s.wBg4.aboveEnable = bit(3);
    s.wObj.aboveEnable = bit(4);
    return;
  case 0x212f:
    s.wBg1.belowEnable = bit(0);
    s.wBg2.belowEnable = bit(1);
    s.wBg3.belowEnable = bit(2);
    s.wBg4.belowEnable = bit(3);
    s.wObj.belowEnable = bit(4);
    return;
  case 0x2130:
    s.dacDirectColor  = bit(0);
    s.dacBlendMode    = bit(1);
    s.dacWinBelowMask = bits(4, 5);
    s.dacWinAboveMask = bits(6, 7);
    return;
  case 0x2131:
    s.colorEnableBG1 = bit(0);
    s.colorEnableBG2 = bit(1);
    s.colorEnableBG3 = bit(2);
    s.colorEnableBG4 = bit(3);
    s.colorEnableOBJ = bit(4);
    s.colorEnableCOL = bit(5);
    s.colorHalve     = bit(6);
    s.colorMode      = bit(7);
    return;
  case 0x2132:
    if(bit(5)) s.colorRed   = bits(0, 4);
    if(bit(6)) s.colorGreen = bits(0, 4);
    if(bit(7)) s.colorBlue  = bits(0, 4);
    return;
  case 0x2133:
    s.interlace    = bit(0);
    s.objInterlace = bit(1);
    s.overscan     = bit(2);
    s.pseudoHires  = bit(3);
    s.extbg        = bit(6);
    return;
  }
}

}  // namespace kintsuki::ppu
