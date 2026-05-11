// Kintsuki project file — IDA-style persistent reversing state for a ROM.
//
// On-disk layout (directory next to the ROM, suffix `.kintsuki`):
//
//   game.sfc
//   game.kintsuki/
//     project.toml      // header: rom sha256, name, adbg path, schema version
//     map.bin           // 1 byte / ROM byte; classification (see ByteClass)
//     labels.toml       // addr -> {name, type, comment} (overlay over .adbg)
//     bookmarks.toml    // user-saved view targets
//     breakpoints.toml  // persistent BPs by symbol or addr
//     dma_log.bin       // append-only DMA event ring (rotated by size)
//     notes/            // markdown free-form per-symbol
//     views.toml        // saved panel layouts (frontend domain)
//
// Slice 1 ships only: project.toml + map.bin. The rest are planned slots and
// must not break forward-compat when added — readers ignore unknown files.
//
// `map.bin` byte values are the `ByteClass` enum below. Range
// `[0x80, 0xFF]` is reserved for user-flag bits OR'd over the base class
// (sticky flag survives auto-reclassify).
//
// Threading: project state is owned by the kintsuki_t instance. All C ABI
// calls are main-thread (same contract as the rest of the API). map.bin
// updates from exec/DMA callbacks happen inline on the emulator thread.

#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace kintsuki {

enum class ByteClass : uint8_t {
  Unknown   = 0,
  Code      = 1,
  Data      = 2,
  Pointer   = 3,
  String    = 4,
  Graphics  = 5,
  Tilemap   = 6,
  Palette   = 7,
  Audio     = 8,   // BRR / SPC engine data
  // 9..0x3F reserved for future auto classes.
  // 0x40..0x7F reserved for project-defined classes.
  // 0x80 bit = USER_STICKY (set by user, auto-reclassify must not clobber).
};

inline constexpr uint8_t kUserStickyBit = 0x80;

class Project {
public:
  // Open or create. `dir` is the `.kintsuki/` directory path. `rom_size`
  // sizes `map.bin` on first creation. `manifest_bml` is the cart manifest
  // ares built for the currently-loaded ROM — persisted verbatim so the
  // project file carries the authoritative bus map (LoROM/HiROM/ExHiROM,
  // SA-1, GSU, ...). `is_hirom` is a fast-path hint mirroring detectRom
  // for slice-1 bus_to_rom; future revisions parse manifest_bml.
  static std::unique_ptr<Project> open(const std::string& dir,
                                       const std::string& rom_sha256,
                                       uint32_t rom_size,
                                       const std::string& manifest_bml,
                                       bool is_hirom);

  // True if the ROM that was loaded when this project was opened matches
  // the pristine sha recorded in `project.toml`. False = patched ROM
  // (still safe to use; the project just isn't locked to a single binary).
  bool loaded_matches_pristine() const;

  // Persist any dirty state. Cheap when clean.
  bool save();

  // Map.bin accessors. `addr` is a ROM offset (0..rom_size).
  ByteClass classify(uint32_t rom_offset) const;
  bool      is_user_sticky(uint32_t rom_offset) const;

  // Auto-classify (no-op if user-sticky already set at offset).
  void mark_auto(uint32_t rom_offset, uint32_t len, ByteClass cls);
  // User override. Sets sticky bit; clears with cls=Unknown.
  void mark_user(uint32_t rom_offset, uint32_t len, ByteClass cls);

  // DMA-driven bulk classification. Maps ($21xx dest reg) -> ByteClass and
  // marks the source range. Called from existing DMA event hook.
  void note_dma(uint32_t src_addr_24, uint16_t size, uint8_t dst_reg);

  // Exec-driven code marking. Called from cpu exec callback at PC.
  void note_exec(uint32_t pc_24, uint8_t insn_len);

  // Convert a CPU bus 24-bit address to a ROM offset, or -1 if not in ROM.
  // Honours the cartridge mapper currently loaded (LoROM/HiROM/ExHiROM).
  // The mapping table is supplied at construction by libkintsuki.
  int64_t bus_to_rom_offset(uint32_t bus_addr_24) const;

  // Stats — used by inspector header.
  struct Stats {
    uint32_t total;
    uint32_t classified;     // any non-Unknown
    uint32_t code;
    uint32_t data;
    uint32_t user_sticky;
  };
  Stats stats() const;

  ~Project();

private:
  Project();
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace kintsuki
