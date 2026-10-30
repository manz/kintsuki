#pragma once
// Core-agnostic read accessors over ares' SNES PPU state. Lets kintsuki's
// debug surfaces address a single kintsuki::ppu::* API regardless of which
// ares implementation (ppu-performance or ppu) is currently rendering. Each
// accessor branches once on `ares::SuperFamicom::ppu.accurate` and reads
// the active impl.
//
// Coverage is restricted to state both impls expose at matching semantics:
// VRAM addressing + storage, OAM/CGRAM write cursors, hires/vdisp, raw
// backing arrays. Deeper per-register readout (bg/obj/mode7/window/mosaic/
// dac latches) is still perf-only; `kintsuki_get_ppu_state` and
// `kintsuki_ppu_ss_read` document the gap.

#include <ares/ares.hpp>
#include <sfc/sfc.hpp>

#include <cstdint>

namespace kintsuki::ppu {

inline auto accurate() -> bool {
  return ares::SuperFamicom::ppu.accurate;
}

inline auto vramAddress() -> uint16_t {
  return accurate()
    ? (uint16_t)ares::SuperFamicom::ppuImpl.io.vramAddress
    : (uint16_t)ares::SuperFamicom::ppuPerformanceImpl.vram.address;
}

// Word index mask: VRAM is addressed in 16-bit words, so (mask + 1) is the
// VRAM word count. Both impls carry this at `vram.mask`.
inline auto vramMask() -> uint16_t {
  return accurate()
    ? (uint16_t)ares::SuperFamicom::ppuImpl.vram.mask
    : (uint16_t)ares::SuperFamicom::ppuPerformanceImpl.vram.mask;
}

inline auto vramWordCount() -> uint32_t {
  return (uint32_t)vramMask() + 1;
}

// Current VMAIN increment step in words (1/32/128). Perf keeps the decoded
// step at `vram.increment`; accurate exposes the same number at
// `io.vramIncrementSize`.
inline auto vramIncrementStep() -> uint8_t {
  return accurate()
    ? (uint8_t)ares::SuperFamicom::ppuImpl.io.vramIncrementSize
    : (uint8_t)ares::SuperFamicom::ppuPerformanceImpl.vram.increment;
}

// VMAIN address mapping (0..3) and translate-on-write mode (0/1).
inline auto vramMapping() -> uint8_t {
  return accurate()
    ? (uint8_t)ares::SuperFamicom::ppuImpl.io.vramMapping
    : (uint8_t)ares::SuperFamicom::ppuPerformanceImpl.vram.mapping;
}

inline auto vramMode() -> uint8_t {
  return accurate()
    ? (uint8_t)ares::SuperFamicom::ppuImpl.io.vramIncrementMode
    : (uint8_t)ares::SuperFamicom::ppuPerformanceImpl.vram.mode;
}

// $2115-style VMAIN byte: mode | mapping | encoded-increment.
inline auto vmainByte() -> uint32_t {
  uint8_t inc = vramIncrementStep();
  uint8_t encoded = inc == 1 ? 0 : inc == 32 ? 1 : 2;
  return (uint32_t)vramMode() << 7 | (uint32_t)vramMapping() << 2 | encoded;
}

inline auto cgramAddress() -> uint8_t {
  return accurate()
    ? (uint8_t)ares::SuperFamicom::ppuImpl.io.cgramAddress
    : (uint8_t)ares::SuperFamicom::ppuPerformanceImpl.io.cgramAddress;
}

inline auto oamAddress() -> uint16_t {
  return accurate()
    ? (uint16_t)ares::SuperFamicom::ppuImpl.io.oamAddress
    : (uint16_t)ares::SuperFamicom::ppuPerformanceImpl.io.oamAddress;
}

// Hires-mode predicate. Perf exposes a method; accurate derives it from the
// same two IO fields, so replicate the formula here.
inline auto hires() -> bool {
  if(accurate()) {
    auto& io = ares::SuperFamicom::ppuImpl.io;
    return io.pseudoHires || io.bgMode == 5 || io.bgMode == 6;
  }
  return ares::SuperFamicom::ppuPerformanceImpl.hires();
}

// Visible display height latched by the active impl.
inline auto vdisp() -> uint32_t {
  return (uint32_t)ares::SuperFamicom::ppu.vdisp();
}

// Raw backing arrays. Both impls store 16-bit VRAM words at `vram.data`.
inline auto vramData() -> const uint16_t* {
  return accurate()
    ? (const uint16_t*)ares::SuperFamicom::ppuImpl.vram.data
    : (const uint16_t*)ares::SuperFamicom::ppuPerformanceImpl.vram.data;
}

}  // namespace kintsuki::ppu
