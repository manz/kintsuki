// kintsuki .adbg reader. Parses the a816 debug-info format
// (magic header + STRINGS + SYMBOLS + FILES + LINES sections) to map
// 24-bit addresses back to symbol names and source file/line locations.
// Format spec: <a816 repo>/docs/docs/adbg-format.md

#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace kintsuki {

struct LineEntry {
  uint32_t address;     // 24-bit
  uint32_t file_idx;    // index into AdbgLabels::files
  uint32_t line;        // 1-based
  uint16_t column;      // 1-based
};

struct AdbgLabels {
  std::unordered_map<uint32_t, std::string> byAddr;
  // Reverse map populated alongside `byAddr` so callers can resolve a
  // symbol name to its 24-bit address without scanning the table —
  // used by the tracer-mask API to translate symbol-name ranges into
  // PC ranges.
  std::unordered_map<std::string, uint32_t> byName;
  std::vector<std::string> files;
  // Sorted by `address` ascending so lookup_source can lower_bound the
  // nearest entry whose address <= the query.
  std::vector<LineEntry> lines;

  // Parse the .adbg file at `path`. Returns true on success; false on
  // missing file, bad magic, unsupported version, or truncated payload.
  // The instance is left empty (no partial state) on failure.
  auto load(const char* path) -> bool;
  auto clear() -> void {
    byAddr.clear();
    byName.clear();
    files.clear();
    lines.clear();
  }

  // O(1) label lookup. Returns nullptr when no label is bound at `addr`.
  auto lookup(uint32_t addr) const -> const char*;

  // Reverse lookup: returns true and fills `out_addr` when a label
  // named `name` exists; false otherwise.
  auto lookupAddress(const char* name, uint32_t& out_addr) const -> bool;

  // Source-line lookup. Returns true and fills `out_*` when a LINES
  // entry covers `addr` (address ≤ entry.address being the last emitted
  // instruction up to that point). False when no LINES were loaded or
  // the query lies before the first entry.
  auto lookupSource(uint32_t addr, const char*& out_file,
                    uint32_t& out_line, uint16_t& out_column) const -> bool;
};

}  // namespace kintsuki
