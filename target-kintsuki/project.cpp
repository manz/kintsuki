// Kintsuki project file — slice 1 implementation. See project.hpp for the
// on-disk layout doc.

#include "project.hpp"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <map>
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

// Split `s` on TAB. Trailing empties are preserved so column count is
// stable. Returns a vector of field strings.
std::vector<std::string> splitTab(const std::string& s) {
  std::vector<std::string> out;
  size_t a = 0;
  for(size_t i = 0; i <= s.size(); i++) {
    if(i == s.size() || s[i] == '\t') {
      out.emplace_back(s.substr(a, i - a));
      a = i + 1;
    }
  }
  return out;
}

int8_t parseFlag(const std::string& s) {
  if(s.empty()) return -1;
  if(s == "0") return 0;
  if(s == "1") return 1;
  return -1;
}

std::string flagStr(int8_t v) {
  if(v == 0) return "0";
  if(v == 1) return "1";
  return "";
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
  bool         labels_dirty = false;

  std::vector<uint8_t> map;  // size == rom_size
  std::map<uint32_t, Project::Label> labels;  // sorted by addr
  std::vector<Project::DmaProv> dma_prov;     // append-only, deduped
  bool dma_prov_dirty = false;

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

  // dma_log.tsv — provenance log. Missing file fine.
  {
    std::ifstream f(im.dir / "dma_log.tsv");
    std::string line;
    while(std::getline(f, line)) {
      if(line.empty() || line[0] == '#') continue;
      auto fields = splitTab(line);
      if(fields.size() < 6) continue;
      Project::DmaProv p{};
      p.src_rom    = (uint32_t)std::strtoul(fields[0].c_str(), nullptr, 16);
      p.size       = (uint16_t)std::strtoul(fields[1].c_str(), nullptr, 0);
      p.dst_reg    = (uint8_t) std::strtoul(fields[2].c_str(), nullptr, 16);
      p.caller_pc  = (uint32_t)std::strtoul(fields[3].c_str(), nullptr, 16);
      p.hits       = (uint32_t)std::strtoul(fields[4].c_str(), nullptr, 0);
      p.last_frame = (uint64_t)std::strtoull(fields[5].c_str(), nullptr, 0);
      im.dma_prov.push_back(p);
    }
  }

  // labels.tsv — overlay table. Missing file is fine (empty overlay).
  {
    std::ifstream f(im.dir / "labels.tsv");
    std::string line;
    while(std::getline(f, line)) {
      if(line.empty() || line[0] == '#') continue;
      auto fields = splitTab(line);
      if(fields.empty()) continue;
      Project::Label L{};
      L.addr = (uint32_t)std::strtoul(fields[0].c_str(), nullptr, 16) & 0xFFFFFF;
      if(fields.size() > 1) L.name    = fields[1];
      if(fields.size() > 2) L.type    = fields[2];
      if(fields.size() > 3) L.m       = parseFlag(fields[3]);
      if(fields.size() > 4) L.x       = parseFlag(fields[4]);
      if(fields.size() > 5) L.e       = parseFlag(fields[5]);
      if(fields.size() > 6) L.comment = fields[6];
      im.labels[L.addr] = L;
    }
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

  // dma_log.tsv — provenance log; re-write when entries changed.
  if(im.dma_prov_dirty) {
    std::ostringstream o;
    o << "# src_rom\tsize\tdst_reg\tcaller_pc\thits\tlast_frame\n";
    for(auto& p : im.dma_prov) {
      char addrBuf[24], cpBuf[16], dstBuf[8];
      std::snprintf(addrBuf, sizeof(addrBuf), "%06X", p.src_rom & 0xFFFFFF);
      std::snprintf(cpBuf,   sizeof(cpBuf),   "%06X", p.caller_pc & 0xFFFFFF);
      std::snprintf(dstBuf,  sizeof(dstBuf),  "%02X", p.dst_reg);
      o << addrBuf << '\t'
        << p.size << '\t'
        << dstBuf << '\t'
        << cpBuf  << '\t'
        << p.hits << '\t'
        << p.last_frame << '\n';
    }
    auto s = o.str();
    if(!writeFile(im.dir / "dma_log.tsv", s.data(), s.size())) return false;
    im.dma_prov_dirty = false;
  }

  // labels.tsv — only re-write when the overlay actually changed. Sorted
  // by addr (the std::map iteration order already gives us this).
  if(im.labels_dirty) {
    std::ostringstream o;
    o << "# addr\tname\ttype\tm\tx\te\tcomment\n";
    for(auto& kv : im.labels) {
      const auto& L = kv.second;
      char addrBuf[16];
      std::snprintf(addrBuf, sizeof(addrBuf), "%06X", L.addr & 0xFFFFFF);
      o << addrBuf << '\t'
        << L.name << '\t'
        << L.type << '\t'
        << flagStr(L.m) << '\t'
        << flagStr(L.x) << '\t'
        << flagStr(L.e) << '\t'
        << L.comment << '\n';
    }
    auto s = o.str();
    if(!writeFile(im.dir / "labels.tsv", s.data(), s.size())) return false;
    im.labels_dirty = false;
  }

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

// ---- DMA provenance -----------------------------------------------------

void Project::note_dma_provenance(uint32_t src_addr_24, uint16_t size,
                                  uint8_t dst_reg, uint32_t caller_pc,
                                  uint64_t frame) {
  auto& im = *impl_;
  int64_t rom = im.busToRom(src_addr_24);
  if(rom < 0) return;  // non-ROM source (WRAM, SRAM, ...) — skip
  uint32_t src = (uint32_t)rom;
  caller_pc &= 0xFFFFFF;
  // Dedupe on (src, size, dst_reg, caller_pc). Linear scan — slice 3
  // expects O(few hundred) entries per project; if it bites, swap for
  // a hash-set keyed by the same tuple.
  for(auto& e : im.dma_prov) {
    if(e.src_rom == src && e.size == size && e.dst_reg == dst_reg
       && e.caller_pc == caller_pc) {
      e.hits += 1;
      e.last_frame = frame;
      im.dma_prov_dirty = true;
      im.dirty = true;
      return;
    }
  }
  DmaProv p{};
  p.src_rom   = src;
  p.size      = size;
  p.dst_reg   = dst_reg;
  p.caller_pc = caller_pc;
  p.hits      = 1;
  p.last_frame = frame;
  im.dma_prov.push_back(p);
  im.dma_prov_dirty = true;
  im.dirty = true;
}

uint32_t Project::dma_prov_count() const {
  return (uint32_t)impl_->dma_prov.size();
}

const Project::DmaProv* Project::dma_prov_at(uint32_t index) const {
  auto& v = impl_->dma_prov;
  if(index >= v.size()) return nullptr;
  return &v[index];
}

uint32_t Project::dma_prov_for_range(uint32_t rom_offset, uint32_t len,
                                     DmaProv* out, uint32_t cap) const {
  if(!out || cap == 0) return 0;
  uint32_t end = rom_offset + len;
  uint32_t n = 0;
  for(auto& e : impl_->dma_prov) {
    uint32_t a = e.src_rom;
    uint32_t b = a + e.size;
    if(b <= rom_offset || a >= end) continue;
    if(n >= cap) break;
    out[n++] = e;
  }
  return n;
}

// ---- Labels overlay -----------------------------------------------------

void Project::set_label(const Label& L) {
  auto& im = *impl_;
  auto& slot = im.labels[L.addr & 0xFFFFFF];
  slot = L;
  slot.addr = L.addr & 0xFFFFFF;
  im.labels_dirty = true;
  im.dirty = true;
}

void Project::clear_label(uint32_t addr) {
  auto& im = *impl_;
  if(im.labels.erase(addr & 0xFFFFFF) > 0) {
    im.labels_dirty = true;
    im.dirty = true;
  }
}

const Project::Label* Project::get_label(uint32_t addr) const {
  auto& im = *impl_;
  auto it = im.labels.find(addr & 0xFFFFFF);
  return it == im.labels.end() ? nullptr : &it->second;
}

uint32_t Project::label_count() const {
  return (uint32_t)impl_->labels.size();
}

uint32_t Project::label_snapshot(Label* out, uint32_t cap) const {
  if(!out || cap == 0) return 0;
  uint32_t i = 0;
  for(auto& kv : impl_->labels) {
    if(i >= cap) break;
    out[i++] = kv.second;
  }
  return i;
}

const Project::Label* Project::label_at(uint32_t index) const {
  auto& im = *impl_;
  if(index >= im.labels.size()) return nullptr;
  auto it = im.labels.begin();
  std::advance(it, index);
  return &it->second;
}

void Project::record_entry_flags(uint32_t addr, int8_t m, int8_t x, int8_t e,
                                 bool force) {
  auto& im = *impl_;
  addr &= 0xFFFFFF;
  auto& slot = im.labels[addr];
  if(slot.name.empty() && slot.type.empty()) {
    slot.addr = addr;
  }
  bool changed = false;
  auto setOne = [&](int8_t& dst, int8_t v) {
    if(v < 0) return;
    if(dst < 0 || force) {
      if(dst != v) { dst = v; changed = true; }
    }
  };
  setOne(slot.m, m);
  setOne(slot.x, x);
  setOne(slot.e, e);
  if(changed) {
    im.labels_dirty = true;
    im.dirty = true;
  } else if(slot.name.empty() && slot.type.empty()
            && slot.m < 0 && slot.x < 0 && slot.e < 0) {
    // We created an empty slot but had nothing to record — drop it so
    // labels.tsv doesn't accumulate empty rows.
    im.labels.erase(addr);
  }
}

}  // namespace kintsuki
