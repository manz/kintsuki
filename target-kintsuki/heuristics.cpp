// Original SNES ROM heuristics. See heuristics.hpp.

#include "heuristics.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace kintsuki {

namespace {

// SMC header layout, relative to the start of the header (offset 0 = title):
//   $00..$14  cart title (ASCII, padded with $20)
//   $15       map mode (bit0: HiROM, bit4: FastROM, bit5: ExHiROM)
//   $16       cart type (00=ROM, 02=ROM+SRAM, ...)
//   $17       ROM size = 1 << ($17 - 7) KB
//   $18       SRAM size = 1 << $18 kbit (0 = none)
//   $19       region: 00,01,0D = NTSC, rest = PAL
//   $1B       version
//   $1C..$1D  checksum complement
//   $1E..$1F  checksum
constexpr uint32_t HEADER_LO  = 0x7fc0;
constexpr uint32_t HEADER_HI  = 0xffc0;
constexpr uint32_t HEADER_LEN = 0x20;

bool isPrintableAscii(uint8_t c) {
  return c >= 0x20 && c <= 0x7e;
}

}  // namespace

int scoreHeader(std::span<const uint8_t> rom, uint32_t off) {
  if(off + HEADER_LEN > rom.size()) return -1;
  int score = 0;

  // Title bytes printable ASCII or space-padded.
  for(uint32_t i = 0; i < 21; i++) {
    uint8_t c = rom[off + i];
    if(isPrintableAscii(c) || c == 0x00) score++;
  }

  // Checksum complement: rom[$1C..$1D] XOR rom[$1E..$1F] should equal $FFFF.
  uint16_t comp = rom[off + 0x1c] | (rom[off + 0x1d] << 8);
  uint16_t sum  = rom[off + 0x1e] | (rom[off + 0x1f] << 8);
  if((uint16_t)(comp ^ sum) == 0xffff) score += 16;

  // Map mode plausible: bit 5..4 = ExHiROM/FastROM marker $20 or $30.
  uint8_t map = rom[off + 0x15];
  if((map & 0xe0) == 0x20 || (map & 0xe0) == 0x30) score += 4;

  // ROM size byte plausible (8..14 KB log2 = 256KB..16MB).
  uint8_t romSize = rom[off + 0x17];
  if(romSize >= 8 && romSize <= 14) score += 2;

  // Region plausible (0..13).
  if(rom[off + 0x19] <= 13) score += 1;

  // LoROM/HiROM bit consistent with the location of this header.
  bool headerSaysHi = (map & 0x01) != 0;
  bool atHiOffset = (off & 0xffff) == HEADER_HI;
  if(headerSaysHi == atHiOffset) score += 8;

  return score;
}

bool detectRom(std::span<const uint8_t> rom, RomInfo& info) {
  if(rom.size() < 0x10000) return false;

  // Try every plausible header offset. ROMs may be larger than 64KB; the
  // header is mirrored within the first bank, so $7FC0 / $FFC0 of the
  // first bank are the only candidates.
  int loScore = scoreHeader(rom, HEADER_LO);
  int hiScore = scoreHeader(rom, HEADER_HI);
  if(loScore < 0 && hiScore < 0) return false;

  uint32_t off = (hiScore > loScore) ? HEADER_HI : HEADER_LO;
  info = {};
  info.hiRom = off == HEADER_HI;

  // Title: 21 ASCII bytes, trim trailing spaces and zeros.
  char title[22] = {};
  std::memcpy(title, rom.data() + off, 21);
  for(int i = 20; i >= 0 && (title[i] == ' ' || title[i] == 0); i--) title[i] = 0;
  // Replace any non-printable with '?' so the manifest stays valid.
  for(int i = 0; title[i]; i++) {
    if(!isPrintableAscii((uint8_t)title[i])) title[i] = '?';
  }
  info.title = title;

  uint8_t map = rom[off + 0x15];
  info.fastRom = (map & 0x10) != 0;

  // SRAM size byte: 1<<n in kbit. Cap to 256KB (bsnes convention).
  uint8_t sramShift = rom[off + 0x18];
  if(sramShift > 0 && sramShift <= 11) {
    info.saveRamSize = (uint32_t)1 << (sramShift + 7);  // bytes (kbit = 1024 bits = 128 bytes)
    info.hasSaveRam = info.saveRamSize > 0;
  }

  uint8_t regionByte = rom[off + 0x19];
  // 00..0C = NTSC (Japan, NA, KR, ...); 0D..= PAL (Europe, AU).
  // We don't distinguish further — ares only differentiates NTSC/PAL.
  info.region = (regionByte >= 0x02 && regionByte <= 0x0c) ? "PAL" : "NTSC";

  // Round ROM size up to a power of two for ares mapping math.
  uint32_t actual = (uint32_t)rom.size();
  uint32_t pow2 = 0x8000;
  while(pow2 < actual) pow2 <<= 1;
  info.programSize = pow2;

  // Pick the simplest matching SHVC board. boards.bml entries with multiple
  // revisions list them as "1A0N-(01,02,...)" — ares' loadBoard accepts the
  // bare name without revision, falling back to the first listed.
  if(info.hiRom && info.hasSaveRam) info.board = "SHVC-1J3M-01";
  else if(info.hiRom)               info.board = "SHVC-1J0N-01";
  else if(info.hasSaveRam)          info.board = "SHVC-1A3M-10";
  else                              info.board = "SHVC-1A0N-01";

  return true;
}

std::string buildManifest(const RomInfo& info) {
  std::string out;
  out.reserve(256);
  out += "game\n";
  out += "  sha256: 0000000000000000000000000000000000000000000000000000000000000000\n";
  out += "  label:  ";   out += info.title;  out += "\n";
  out += "  name:   ";   out += info.title;  out += "\n";
  out += "  title:  ";   out += info.title;  out += "\n";
  out += "  region: ";   out += info.region; out += "\n";
  out += "  revision: 1.0\n";
  out += "  board: ";    out += info.board;  out += "\n";

  // ROM block.
  char buf[64];
  std::snprintf(buf, sizeof(buf), "    memory type=ROM content=Program size=0x%x\n", info.programSize);
  out += buf;

  // SRAM block (if any).
  if(info.hasSaveRam) {
    std::snprintf(buf, sizeof(buf), "    memory type=RAM content=Save size=0x%x\n", info.saveRamSize);
    out += buf;
  }

  return out;
}

}  // namespace kintsuki
