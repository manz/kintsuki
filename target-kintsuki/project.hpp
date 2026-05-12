// Kintsuki project file — IDA-style persistent reversing state for a ROM.
//
// On-disk layout (directory next to the ROM, suffix `.kintsuki`):
//
//   game.sfc
//   game.kintsuki/
//     project.toml      // header: rom sha256, name, adbg path, schema version
//     manifest.bml      // verbatim cart manifest at create time (bus map)
//     map.bin           // 1 byte / ROM byte; classification (see ByteClass)
//     labels.tsv        // addr -> name + type + flags + comment (overlay)
//     bookmarks.toml    // user-saved view targets
//     breakpoints.toml  // persistent BPs by symbol or addr
//     dma_log.bin       // append-only DMA event log (rotated by size)
//     notes/            // markdown free-form per-symbol
//     views.toml        // saved panel layouts (frontend domain)
//
// labels.tsv columns (one record per line, tab-separated, # = comment):
//   addr   name   type   m   x   e   comment
// Fields after `name` are optional. addr is 6-hex 24-bit. m/x/e are 0/1/
// empty (empty = unset). type is free-form lowercase string; conventional
// values: function, data, pointer, string, gfx, palette, tilemap, audio.
// `comment` may contain spaces but no tabs (tabs are field separators).
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
#include <vector>

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
  CodeOperand = 9, // bytes following an opcode (immediate, address, ...)
  // 10..0x3F reserved for future auto classes.
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

  // DMA provenance (slice 3). Records "who pushed this buffer" — keyed
  // by (src_rom_offset, dst_reg, caller_pc). Deduplicated; repeated
  // fires bump a hit counter. Persisted as `dma_log.tsv` on save.
  void note_dma_provenance(uint32_t src_addr_24, uint16_t size,
                           uint8_t dst_reg, uint32_t caller_pc,
                           uint64_t frame);

  struct DmaProv {
    uint32_t src_rom;     // ROM offset of transfer source (-1 if non-ROM
                          // -> we store 0xFFFFFFFF and skip persisting)
    uint16_t size;
    uint8_t  dst_reg;
    uint8_t  _pad;
    uint32_t caller_pc;   // 24-bit
    uint32_t hits;
    uint64_t last_frame;
  };
  uint32_t dma_prov_count() const;
  const DmaProv* dma_prov_at(uint32_t index) const;
  // Query helper: all provenance entries whose source range overlaps
  // [rom_offset, rom_offset+len). Linear scan — slice 3 expects O(few
  // hundred) entries; promote to an interval-tree index if it bites.
  uint32_t dma_prov_for_range(uint32_t rom_offset, uint32_t len,
                              DmaProv* out, uint32_t cap) const;

  // Exec-driven code marking. Called from cpu exec callback at PC.
  void note_exec(uint32_t pc_24, uint8_t insn_len);

  // Convert a CPU bus 24-bit address to a ROM offset, or -1 if not in ROM.
  // Honours the cartridge mapper currently loaded (LoROM/HiROM/ExHiROM).
  // The mapping table is supplied at construction by libkintsuki.
  int64_t bus_to_rom_offset(uint32_t bus_addr_24) const;

  // ---- Labels overlay (slice 2) ----------------------------------------
  // Per-address user metadata layered on top of any loaded `.adbg` symbol
  // table. Labels here win over .adbg labels at the same address — useful
  // when reversing a routine the assembly hasn't yet promoted to a name.
  // m/x/e are tri-state ints: 0, 1, or -1 (unset). Comments contain no
  // tabs and no newlines.
  struct Label {
    uint32_t    addr;    // 24-bit
    std::string name;
    std::string type;    // optional, lowercase ("function", "data", ...)
    std::string comment; // optional
    int8_t      m = -1;
    int8_t      x = -1;
    int8_t      e = -1;
  };
  void set_label(const Label& L);   // replaces any existing entry at L.addr
  void clear_label(uint32_t addr);
  const Label* get_label(uint32_t addr) const;   // nullptr if no overlay
  uint32_t label_count() const;
  uint32_t label_snapshot(Label* out, uint32_t cap) const;  // sorted by addr
  // O(n) random access into the sorted label map. Returns nullptr if
  // `index >= label_count()`. The pointer borrows project-owned storage
  // and is valid until the next mutation (set_label/clear_label/close).
  const Label* label_at(uint32_t index) const;

  // ---- Bookmarks (slice 4) ---------------------------------------------
  // Named view targets. `view` is a free-form short string: "rom",
  // "wram", "vram", "cgram", "oam", or anything the frontend defines.
  struct Bookmark {
    uint32_t    addr;    // 24-bit (or 16-bit if view is wram/vram/etc.)
    std::string name;
    std::string view;
    std::string comment;
  };
  void set_bookmark(const Bookmark& b);        // upsert by name
  void clear_bookmark(const std::string& name);
  const Bookmark* get_bookmark(const std::string& name) const;
  uint32_t bookmark_count() const;
  const Bookmark* bookmark_at(uint32_t index) const;  // index in insertion order

  // ---- Breakpoints (slice 4) -------------------------------------------
  // Persistent BPs. Auto-install is the frontend's job — the project
  // only stores records (frontends call kintsuki_add_callback_ex with
  // each entry on attach). Saving is dirty-tracked separately so the
  // file is only rewritten when records change.
  enum class BpKind : uint8_t { Exec = 0, Read = 1, Write = 2 };
  struct Breakpoint {
    BpKind      kind;
    bool        halt;
    bool        enabled;
    uint32_t    addr_lo;   // 24-bit, inclusive
    uint32_t    addr_hi;   // 24-bit, inclusive
    std::string comment;
  };
  void add_breakpoint(const Breakpoint& bp);
  void remove_breakpoint(uint32_t index);
  void clear_breakpoints();
  uint32_t breakpoint_count() const;
  const Breakpoint* breakpoint_at(uint32_t index) const;

  // ---- Function exits (slice 7) ----------------------------------------
  // Per-function aggregated exit info: every RTS/RTL that pops back
  // through an entry records its PC + kind in this entry's set. Lets
  // viewers answer "where does this routine return from?" without a
  // static cfg walk, and surface multi-exit / non-RTS-only functions.
  struct FuncInfo {
    uint32_t entry;        // 24-bit
    uint32_t call_count;
    uint64_t last_exit_frame;
    // Exit PCs observed so far. Vector instead of set so the order is
    // stable across save/load (first-seen wins) — UI shows them in the
    // order they're encountered which matches reading the disassembly.
    std::vector<uint32_t> exit_pcs;
    // Parallel to exit_pcs: 0 = RTS, 1 = RTL.
    std::vector<uint8_t>  exit_kinds;
  };
  void note_function_exit(uint32_t entry, uint32_t exit_pc,
                          uint8_t kind, uint64_t frame);
  uint32_t func_count() const;
  const FuncInfo* func_at(uint32_t index) const;
  const FuncInfo* func_for(uint32_t entry) const;

  // Record live processor flags at a code entry point. Called from the
  // shadow-callstack JSR/JSL hook so cold-cache disasm at any reached
  // function knows the caller's M/X/E. Skipped silently when no project
  // is open (libkintsuki calls unconditionally on the hot path).
  // Idempotent — first writer wins, subsequent calls are no-ops unless
  // `force` is set. Use `force=true` when the user manually sets flags.
  void record_entry_flags(uint32_t addr, int8_t m, int8_t x, int8_t e,
                          bool force = false);

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
