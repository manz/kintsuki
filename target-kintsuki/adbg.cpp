// .adbg LABEL reader implementation. Walks header → section table → only
// consumes STRINGS (kind=5) and SYMBOLS (kind=3); ignores FILES, MODULES,
// LINES. Symbol kind 0 (LABEL) is the only one with an addressable PC; we
// drop constants and aliases.

#include "adbg.hpp"

#include <cstdio>
#include <cstring>
#include <vector>

namespace kintsuki {

namespace {

constexpr uint32_t SECTION_SYMBOLS = 3;
constexpr uint32_t SECTION_STRINGS = 5;
constexpr uint8_t  SYMBOL_KIND_LABEL = 0;

// Forward bytes cursor with bounds checks. Every read returns false on
// overflow; the load() walker stops and reports failure when it does.
struct Cursor {
  const uint8_t* data;
  size_t size;
  size_t off = 0;

  auto remaining() const -> size_t { return size - off; }

  template <typename T>
  auto read(T& out) -> bool {
    if(off + sizeof(T) > size) return false;
    std::memcpy(&out, data + off, sizeof(T));
    off += sizeof(T);
    return true;
  }

  auto skip(size_t n) -> bool {
    if(off + n > size) return false;
    off += n;
    return true;
  }

  auto slice(size_t n, const uint8_t*& out_ptr) -> bool {
    if(off + n > size) return false;
    out_ptr = data + off;
    off += n;
    return true;
  }
};

// Resolve a string-table offset into a NUL-terminated heap string. The
// strings blob is one big null-separated buffer (offset 0 = empty).
auto stringAt(const uint8_t* blob, size_t blob_size, uint32_t offset)
    -> std::string {
  if(offset >= blob_size) return {};
  size_t end = offset;
  while(end < blob_size && blob[end] != 0) end++;
  return std::string(reinterpret_cast<const char*>(blob + offset), end - offset);
}

}  // namespace

auto AdbgLabels::lookup(uint32_t addr) const -> const char* {
  auto it = byAddr.find(addr & 0xFFFFFF);
  return it == byAddr.end() ? nullptr : it->second.c_str();
}

auto AdbgLabels::load(const char* path) -> bool {
  byAddr.clear();
  if(!path) return false;

  std::FILE* fp = std::fopen(path, "rb");
  if(!fp) return false;
  std::fseek(fp, 0, SEEK_END);
  long total = std::ftell(fp);
  std::rewind(fp);
  if(total <= 12) { std::fclose(fp); return false; }
  std::vector<uint8_t> buf(static_cast<size_t>(total));
  if(std::fread(buf.data(), 1, buf.size(), fp) != buf.size()) {
    std::fclose(fp); return false;
  }
  std::fclose(fp);

  Cursor c{buf.data(), buf.size()};

  // Header: "ADBG" + version(u16) + flags(u16) + section_count(u32).
  const uint8_t* magic_ptr = nullptr;
  if(!c.slice(4, magic_ptr)) return false;
  if(std::memcmp(magic_ptr, "ADBG", 4) != 0) return false;
  uint16_t version = 0, flags = 0;
  uint32_t section_count = 0;
  if(!c.read(version) || !c.read(flags) || !c.read(section_count)) return false;
  if(version != 1) return false;
  (void)flags;

  // Pre-walk the sections so STRINGS is in hand before SYMBOLS resolves
  // name offsets — section order is producer-defined and not guaranteed.
  const uint8_t* strings_ptr = nullptr;
  size_t strings_size = 0;
  const uint8_t* symbols_ptr = nullptr;
  size_t symbols_size = 0;

  for(uint32_t i = 0; i < section_count; i++) {
    uint32_t kind = 0, length = 0;
    if(!c.read(kind) || !c.read(length)) return false;
    if(c.remaining() < length) return false;
    if(kind == SECTION_STRINGS) {
      // Payload: size(u32) + bytes[size].
      if(length < 4) { c.skip(length); continue; }
      uint32_t blob_size = 0;
      std::memcpy(&blob_size, c.data + c.off, 4);
      if(4u + blob_size > length) return false;
      strings_ptr = c.data + c.off + 4;
      strings_size = blob_size;
      c.skip(length);
    } else if(kind == SECTION_SYMBOLS) {
      symbols_ptr = c.data + c.off;
      symbols_size = length;
      c.skip(length);
    } else {
      c.skip(length);
    }
  }

  if(!symbols_ptr) return true;  // no labels; valid file but nothing to load

  // Walk SYMBOLS payload: count(u32) + entries.
  // Entry: name_idx(u32) addr(u32) scope(u8) module_idx(u32) kind(u8).
  Cursor sc{symbols_ptr, symbols_size};
  uint32_t count = 0;
  if(!sc.read(count)) return false;
  for(uint32_t i = 0; i < count; i++) {
    uint32_t name_idx = 0, address = 0, module_idx = 0;
    uint8_t scope = 0, sym_kind = 0;
    if(!sc.read(name_idx) || !sc.read(address) || !sc.read(scope)
       || !sc.read(module_idx) || !sc.read(sym_kind)) return false;
    (void)scope; (void)module_idx;
    if(sym_kind != SYMBOL_KIND_LABEL) continue;
    auto name = stringAt(strings_ptr, strings_size, name_idx);
    if(name.empty()) continue;
    // First writer wins on collisions — duplicate labels at the same
    // address get merged silently rather than the last entry stomping.
    byAddr.emplace(address & 0xFFFFFF, std::move(name));
  }
  return true;
}

}  // namespace kintsuki
