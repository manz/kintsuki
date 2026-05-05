// kintsuki .adbg LABEL reader. Parses just enough of the a816 debug-info
// format (magic header + STRINGS + SYMBOLS sections) to map 24-bit
// addresses back to symbol names. Format spec:
//   <a816 repo>/docs/docs/adbg-format.md

#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>

namespace kintsuki {

struct AdbgLabels {
  std::unordered_map<uint32_t, std::string> byAddr;

  // Parse the .adbg file at `path`. Returns true on success; false on
  // missing file, bad magic, unsupported version, or truncated payload.
  // The instance is left empty (no partial state) on failure.
  auto load(const char* path) -> bool;
  auto clear() -> void { byAddr.clear(); }

  // O(1) lookup. Returns nullptr when no label is bound at `addr`.
  auto lookup(uint32_t addr) const -> const char*;
};

}  // namespace kintsuki
