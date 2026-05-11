// Kintsuki project file — slice 1 implementation. See project.hpp for the
// on-disk layout doc.

#include "project.hpp"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace kintsuki {

namespace {

constexpr uint32_t kSchemaVersion = 1;

// Tiny key=value reader for project.toml. Doesn't try to be a full TOML
// parser — slice 1 only needs flat scalars under the root table. Lines
// of the form `key = value` (value optionally quoted). Section headers
// `[name]` are read but the section name is ignored (kept flat for
// simplicity). Unknown keys are tolerated for forward-compat.
struct TomlFlat {
  std::vector<std::pair<std::string, std::string>> kv;

  static std::string strip(const std::string& s) {
    size_t a = 0, b = s.size();
    while(a < b && (s[a] == ' ' || s[a] == '\t')) a++;
    while(b > a && (s[b-1] == ' ' || s[b-1] == '\t' || s[b-1] == '\r' || s[b-1] == '\n')) b--;
    return s.substr(a, b - a);
  }
  static std::string unquote(const std::string& s) {
    if(s.size() >= 2 && s.front() == '"' && s.back() == '"') return s.substr(1, s.size() - 2);
    return s;
  }

  bool load(const fs::path& path) {
    std::ifstream f(path);
    if(!f.good()) return false;
    std::string line;
    while(std::getline(f, line)) {
      auto t = strip(line);
      if(t.empty() || t[0] == '#' || t[0] == '[') continue;
      auto eq = t.find('=');
      if(eq == std::string::npos) continue;
      auto k = strip(t.substr(0, eq));
      auto v = unquote(strip(t.substr(eq + 1)));
      kv.emplace_back(k, v);
    }
    return true;
  }
  const std::string* get(const std::string& key) const {
    for(auto& p : kv) if(p.first == key) return &p.second;
    return nullptr;
  }
  uint64_t getU64(const std::string& key, uint64_t fallback = 0) const {
    if(auto* s = get(key)) return std::strtoull(s->c_str(), nullptr, 0);
    return fallback;
  }
};

std::string isoNow() {
  auto t = std::time(nullptr);
  std::tm tm{};
  gmtime_r(&t, &tm);
  char buf[32];
  std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
  return buf;
}

bool writeFile(const fs::path& path, const void* data, size_t n) {
  std::ofstream f(path, std::ios::binary | std::ios::trunc);
  if(!f.good()) return false;
  f.write((const char*)data, (std::streamsize)n);
  return f.good();
}

bool readFile(const fs::path& path, std::vector<uint8_t>& out) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if(!f.good()) return false;
  auto n = (std::streamoff)f.tellg();
  if(n < 0) return false;
  f.seekg(0);
  out.resize((size_t)n);
  if(n > 0) f.read((char*)out.data(), n);
  return f.good();
}

// Classify a ROM source range based on the DMA destination PPU register.
ByteClass classifyByDest(uint8_t dst_reg) {
  switch(dst_reg) {
    case 0x18: case 0x19: return ByteClass::Graphics;  // VMDATAL/H — VRAM
    case 0x22: return ByteClass::Palette;              // CGDATA
    case 0x04: return ByteClass::Tilemap;              // OAMDATA (heuristic — sprite tables)
    default:   return ByteClass::Data;
  }
}

}  // namespace

struct Project::Impl {
  fs::path     dir;
  std::string  rom_sha_pristine;
  std::string  manifest_bml;
  uint32_t     rom_size = 0;
  bool         is_hirom = false;
  bool         loaded_matches_pristine = true;
  bool         dirty = false;

  std::vector<uint8_t> map;  // size == rom_size

  // Resolve bus -> rom offset for LoROM / HiROM. Returns -1 on non-ROM
  // address. ExHiROM + coprocessors not yet supported (slice 1 limitation
  // tracked separately — the manifest is persisted so future builds can
  // implement these against the same project file unchanged).
  int64_t busToRom(uint32_t bus_addr) const {
    uint32_t bank = (bus_addr >> 16) & 0xFF;
    uint32_t addr = bus_addr & 0xFFFF;
    if(is_hirom) {
      // HiROM: $40-$7D / $C0-$FF map full $0000-$FFFF; $00-$3F / $80-$BF
      // shadow at $8000-$FFFF.
      if((bank >= 0x40 && bank <= 0x7D) || bank >= 0xC0) {
        uint32_t off = ((bank & 0x3F) << 16) | addr;
        if(off < rom_size) return off;
      } else if(addr >= 0x8000 && (bank <= 0x3F || (bank >= 0x80 && bank <= 0xBF))) {
        uint32_t off = ((bank & 0x3F) << 16) | addr;
        if(off < rom_size) return off;
      }
    } else {
      // LoROM: ROM at $8000-$FFFF in banks $00-$7D and $80-$FF.
      if(addr >= 0x8000 && (bank <= 0x7D || bank >= 0x80)) {
        uint32_t off = ((bank & 0x7F) << 15) | (addr & 0x7FFF);
        if(off < rom_size) return off;
      }
    }
    return -1;
  }
};

Project::Project() : impl_(std::make_unique<Impl>()) {}
Project::~Project() = default;

std::unique_ptr<Project> Project::open(const std::string& dir,
                                       const std::string& rom_sha256,
                                       uint32_t rom_size,
                                       const std::string& manifest_bml,
                                       bool is_hirom) {
  auto p = std::unique_ptr<Project>(new Project());
  auto& im = *p->impl_;
  im.dir = dir;
  im.rom_size = rom_size;
  im.rom_sha_pristine = rom_sha256;
  im.manifest_bml = manifest_bml;
  im.is_hirom = is_hirom;
  im.dirty = true;  // freshly opened — flush at first save

  std::error_code ec;
  fs::create_directories(im.dir, ec);
  if(ec) {
    std::fprintf(stderr, "kintsuki project: cannot create %s: %s\n",
                 dir.c_str(), ec.message().c_str());
    return nullptr;
  }

  // project.toml — read if present, otherwise initialize.
  auto tomlPath = im.dir / "project.toml";
  TomlFlat t;
  bool existing = t.load(tomlPath);
  if(existing) {
    if(auto* s = t.get("rom_sha256_pristine")) {
      if(!s->empty() && *s != rom_sha256) {
        im.loaded_matches_pristine = false;
        std::fprintf(stderr,
          "kintsuki project: loaded ROM sha mismatch (project=%s, loaded=%s) "
          "— continuing, project is not locked.\n",
          s->c_str(), rom_sha256.c_str());
        // Keep the stored sha as the canonical one — don't overwrite.
        im.rom_sha_pristine = *s;
      }
    }
    uint64_t storedSize = t.getU64("rom_size", 0);
    if(storedSize && storedSize != rom_size) {
      std::fprintf(stderr,
        "kintsuki project: rom_size mismatch (project=%llu, loaded=%u)\n",
        (unsigned long long)storedSize, rom_size);
      // Keep stored size for the map; the loaded ROM may have been padded.
      // Don't fail open — caller may still want to inspect.
    }
  }

  // map.bin — load or zero-init at rom_size.
  auto mapPath = im.dir / "map.bin";
  std::vector<uint8_t> mapBuf;
  if(readFile(mapPath, mapBuf) && !mapBuf.empty()) {
    if(mapBuf.size() != rom_size) {
      // Trust the stored size; truncate/extend on read.
      mapBuf.resize(rom_size, 0);
    }
    im.map = std::move(mapBuf);
  } else {
    im.map.assign(rom_size, 0);
  }

  return p;
}

bool Project::save() {
  auto& im = *impl_;
  if(!im.dirty) return true;

  // Write manifest verbatim if known.
  if(!im.manifest_bml.empty()) {
    writeFile(im.dir / "manifest.bml", im.manifest_bml.data(), im.manifest_bml.size());
  }

  // project.toml
  {
    std::ostringstream o;
    o << "# kintsuki project file — autogenerated\n";
    o << "schema_version = " << kSchemaVersion << "\n";
    o << "rom_sha256_pristine = \"" << im.rom_sha_pristine << "\"\n";
    o << "rom_size = " << im.rom_size << "\n";
    o << "mapper = \"" << (im.is_hirom ? "HiROM" : "LoROM") << "\"\n";
    o << "saved_at = \"" << isoNow() << "\"\n";
    auto s = o.str();
    if(!writeFile(im.dir / "project.toml", s.data(), s.size())) return false;
  }

  // map.bin
  if(!writeFile(im.dir / "map.bin", im.map.data(), im.map.size())) return false;

  im.dirty = false;
  return true;
}

ByteClass Project::classify(uint32_t rom_offset) const {
  auto& im = *impl_;
  if(rom_offset >= im.map.size()) return ByteClass::Unknown;
  return (ByteClass)(im.map[rom_offset] & 0x7F);
}

bool Project::is_user_sticky(uint32_t rom_offset) const {
  auto& im = *impl_;
  if(rom_offset >= im.map.size()) return false;
  return (im.map[rom_offset] & kUserStickyBit) != 0;
}

void Project::mark_auto(uint32_t rom_offset, uint32_t len, ByteClass cls) {
  auto& im = *impl_;
  uint8_t base = (uint8_t)cls & 0x7F;
  uint32_t end = rom_offset + len;
  if(end > im.map.size()) end = (uint32_t)im.map.size();
  for(uint32_t i = rom_offset; i < end; i++) {
    if(im.map[i] & kUserStickyBit) continue;  // user wins
    if((im.map[i] & 0x7F) != base) {
      im.map[i] = base;
      im.dirty = true;
    }
  }
}

void Project::mark_user(uint32_t rom_offset, uint32_t len, ByteClass cls) {
  auto& im = *impl_;
  uint8_t base = (uint8_t)cls & 0x7F;
  uint32_t end = rom_offset + len;
  if(end > im.map.size()) end = (uint32_t)im.map.size();
  uint8_t val = (cls == ByteClass::Unknown) ? 0 : (uint8_t)(base | kUserStickyBit);
  for(uint32_t i = rom_offset; i < end; i++) {
    if(im.map[i] != val) {
      im.map[i] = val;
      im.dirty = true;
    }
  }
}

void Project::note_dma(uint32_t src_addr_24, uint16_t size, uint8_t dst_reg) {
  auto& im = *impl_;
  int64_t off = im.busToRom(src_addr_24);
  if(off < 0) return;
  mark_auto((uint32_t)off, size, classifyByDest(dst_reg));
}

void Project::note_exec(uint32_t pc_24, uint8_t insn_len) {
  auto& im = *impl_;
  int64_t off = im.busToRom(pc_24);
  if(off < 0) return;
  mark_auto((uint32_t)off, insn_len ? insn_len : 1, ByteClass::Code);
}

int64_t Project::bus_to_rom_offset(uint32_t bus_addr_24) const {
  return impl_->busToRom(bus_addr_24);
}

Project::Stats Project::stats() const {
  auto& im = *impl_;
  Stats s{};
  s.total = (uint32_t)im.map.size();
  for(uint8_t b : im.map) {
    if(b & kUserStickyBit) s.user_sticky++;
    uint8_t cls = b & 0x7F;
    if(cls != 0) s.classified++;
    if(cls == (uint8_t)ByteClass::Code) s.code++;
    if(cls == (uint8_t)ByteClass::Data) s.data++;
  }
  return s;
}

bool Project::loaded_matches_pristine() const {
  return impl_->loaded_matches_pristine;
}

}  // namespace kintsuki
