// Minimal SNES ROM heuristics. Reads SMC internal header at $7FC0 (LoROM)
// or $FFC0 (HiROM), picks the better-scoring location, and emits an
// ares-compatible cart manifest naming a generic SHVC board.
//
// Original implementation — does not copy bsnes/mia heuristics. Public
// information about the SMC header format only (Nintendo SHVC manual,
// nesdev wiki, anomie's docs).

#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace kintsuki {

struct RomInfo {
  std::string title;     // ASCII, trimmed, max 21 bytes
  std::string region;    // "NTSC" or "PAL"
  std::string board;     // SHVC-1xxX-XX matching boards.bml
  uint32_t programSize;  // size used by the cart (rounded to next pow2)
  bool hiRom;            // true: HiROM ($00:8000-FFFF and $40:0000-FFFF)
  bool fastRom;          // 3.58 MHz vs 2.68 MHz
  bool hasSaveRam;
  uint32_t saveRamSize;  // bytes
};

// Score a candidate header at the given absolute offset within the rom.
// Returns -1 when offset would be out of bounds.
int scoreHeader(std::span<const uint8_t> rom, uint32_t headerOffset);

// Run heuristics on a SNES ROM blob. Returns false if the blob looks
// invalid (too small, no plausible header).
bool detectRom(std::span<const uint8_t> rom, RomInfo& info);

// Build a minimal cart manifest.bml from a RomInfo. Result is plain text
// that ares' BML parser will accept.
std::string buildManifest(const RomInfo& info);

}  // namespace kintsuki
