// See program.hpp.
//
// Architecture: ares uses a global Platform pointer (`ares::platform`) that
// receives video/input/pak callbacks. We subclass Platform, build small
// in-memory vfs::directory paks for the system (boards.bml + ipl.rom) and
// the cartridge (manifest + ROM bytes), and capture the RGBA framebuffer
// produced by the PPU each frame.

#include "program.hpp"
#include "heuristics.hpp"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>

using namespace nall;
using namespace ares;

namespace ares::SuperFamicom {
  extern volatile bool kintsukiHaltRequested;
}

Program* kintsukiProgram = nullptr;

namespace {

// Slurp a file into a vector. Returns empty on failure.
auto readFile(const char* path) -> std::vector<uint8_t> {
  std::ifstream f(path, std::ios::binary);
  if(!f) return {};
  return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}

// Per-process keep-alive so vfs::memory::open's non-owning span stays valid
// for the lifetime of the emulator.
std::vector<std::vector<uint8_t>>& keepalive() {
  static std::vector<std::vector<uint8_t>> store;
  return store;
}

auto attachFile(std::shared_ptr<vfs::directory>& dir,
                const char* name, std::vector<uint8_t> bytes) -> void {
  if(bytes.empty()) return;
  keepalive().push_back(std::move(bytes));
  auto& kept = keepalive().back();
  auto file = vfs::memory::open(std::span<const uint8_t>(kept.data(), kept.size()));
  file->setName(name);
  dir->append(file);
}

// Build the system pak from ares' bundled System/ tree.
auto makeSystemPak() -> std::shared_ptr<vfs::directory> {
  auto dir = std::make_shared<vfs::directory>();
  const char* base = std::getenv("KINTSUKI_SYSTEM_PAK");
  if(!base) base = KINTSUKI_SYSTEM_PAK_DEFAULT;

  for(const char* name : {"boards.bml", "ipl.rom"}) {
    string path{base, "/", name};
    attachFile(dir, name, readFile((const char*)path));
  }
  return dir;
}

}  // namespace

Program::Program() {
  ares::platform = this;
  fb.resize(512 * 480);
  systemPak = makeSystemPak();
}

Program::~Program() {
  // ares core globals get cleaned up by SuperFamicom::system.unload(); the
  // C ABI shim is responsible for calling that before destroying us.
}

auto Program::attach(Node::Object) -> void {}

auto Program::pak(Node::Object node) -> std::shared_ptr<vfs::directory> {
  if(!node) return {};
  string name = node->name();
  if(name == "Super Famicom") return systemPak;
  if(name.match("*Cartridge*")) return cartPak;
  return {};
}

auto Program::event(ares::Event) -> void {}

auto Program::log(Node::Debugger::Tracer::Tracer, string_view msg) -> void {
  std::fwrite(msg.data(), 1, msg.size(), stderr);
  std::fputc('\n', stderr);
}

auto Program::video(Node::Video::Screen, const u32* data, u32 pitch, u32 width, u32 height) -> void {
  fbWidth = width;
  fbHeight = height;
  size_t pixels = size_t(width) * height;
  if(fb.size() < pixels) fb.resize(pixels);
  u32 stride = pitch / sizeof(u32);
  for(u32 y = 0; y < height; y++) {
    const u32* src = data + y * stride;
    uint32_t* dst = fb.data() + y * width;
    std::memcpy(dst, src, width * sizeof(u32));
  }
  framesRendered++;
}

auto Program::audio(Node::Audio::Stream) -> void {}

auto Program::input(Node::Input::Input node) -> void {
  // node is shared_ptr<Core::Input::Input>; downcast to Button.
  auto button = std::dynamic_pointer_cast<Core::Input::Button>(node);
  if(!button) return;

  // Walk up the node tree to find the controller port.
  uint port = 0;
  bool found = false;
  for(auto p = node->parent().lock(); p; p = p->parent().lock()) {
    string pname = p->name();
    if(pname.match("*Port*1*"))      { port = 0; found = true; break; }
    if(pname.match("*Port*2*"))      { port = 1; found = true; break; }
  }
  if(!found) return;

  static const std::pair<const char*, int> map[] = {
    {"Up", 0}, {"Down", 1}, {"Left", 2}, {"Right", 3},
    {"B", 4},  {"A", 5},    {"Y", 6},    {"X", 7},
    {"L", 8},  {"R", 9},    {"Select", 10}, {"Start", 11},
  };
  string name = button->name();
  for(auto& [k, bit] : map) {
    if(name == k) {
      button->setValue(((inputState[port] >> bit) & 1) != 0);
      return;
    }
  }
}

auto Program::loadRom(const char* path) -> bool {
  romData = readFile(path);
  if(romData.empty()) return false;

  // Strip 512-byte copier header if present.
  if((romData.size() & 0x7fff) == 512) {
    romData.erase(romData.begin(), romData.begin() + 512);
  }

  // Pristine sha — locks the project file to the unpatched ROM identity
  // so loading w/ an IPS applied still matches the saved project.
  {
    Hash::SHA256 h(std::span<const uint8_t>(romData.data(), romData.size()));
    romPristineSha256 = std::string{h.digest().data()};
  }

  // Auto-apply an IPS patch sitting next to the ROM. ares' upstream loader
  // doesn't do this in headless — we duplicate mia's behaviour here.
  // Two locations: <rom>.ips (preferred) and <rom-without-ext>.ips.
  auto tryPatch = [&](const std::string& patchPath) {
    auto ips = readFile(patchPath.c_str());
    if(ips.empty()) return false;   // missing or zero-byte file, silent
    bool ok = kintsuki::applyIpsPatch(romData, std::span<const uint8_t>(ips.data(), ips.size()));
    if(ok) {
      std::fprintf(stderr, "kintsuki: applied IPS %s (%zu bytes)\n",
                   patchPath.c_str(), ips.size());
    } else {
      // Existing file but malformed / truncated / wrong magic. Warn so
      // users notice — a silent reject looks identical to "no patch
      // present" and causes hours of "why isn't my fix loading".
      std::fprintf(stderr, "kintsuki: rejected IPS %s (%zu bytes, invalid format)\n",
                   patchPath.c_str(), ips.size());
    }
    return ok;
  };
  std::string p = path;
  // <rom>.ips
  if(!tryPatch(p + ".ips")) {
    // <rom-without-extension>.ips
    auto dot = p.find_last_of('.');
    if(dot != std::string::npos) tryPatch(p.substr(0, dot) + ".ips");
  }

  kintsuki::RomInfo info;
  if(!kintsuki::detectRom(romData, info)) return false;
  romHiRom = info.hiRom;

  std::string m = kintsuki::buildManifest(info);
  cartManifestStr = m;
  cartManifest = string{m.c_str()};

  cartPak = std::make_shared<vfs::directory>();
  // ares' Cartridge::connect() reads title/region/board as pak ATTRIBUTES,
  // not from the manifest text. Without these set, loadBoard("") fails,
  // no memory map gets built, and the CPU executes 0xFF from a null bus.
  // ares' Cartridge::connect() reads title/region/board as pak ATTRIBUTES,
  // not from the manifest text. Without these, loadBoard("") fails, no
  // memory map gets built, and the CPU executes 0xFF from a null bus.
  cartPak->setAttribute("title",  string{info.title.c_str()});
  cartPak->setAttribute("region", string{info.region.c_str()});
  cartPak->setAttribute("board",  string{info.board.c_str()});
  attachFile(cartPak, "manifest.bml", std::vector<uint8_t>(m.begin(), m.end()));

  // Seed save.ram from a `.srm` sidecar if one exists next to the ROM,
  // otherwise zero-fill. ares' loadMap binds a reader function pointing
  // into cart.ram.data(); if ram was never allocated (no save.ram in
  // pak), the first SRAM access dereferences null and crashes - happens
  // fast for games that touch cart RAM during boot (e.g. FF4 reads
  // $38:07FE during its startup vector). The sidecar is read-only:
  // kintsuki has no save() callback wired to disk so the file is
  // never written back, mirroring the manual `kintsuki_inject_sram`
  // semantics (in-memory edit, original file untouched).
  if(info.hasSaveRam && info.saveRamSize > 0) {
    std::vector<uint8_t> ram(info.saveRamSize, 0);
    // Tests opt out via Program::loadSrmSidecar=false so a stray .srm
    // next to a fixture ROM doesn't seed deterministic SRAM with random
    // save data. Default true so end-user clients (Swift app, CLI) get
    // mia-equivalent behaviour.
    if(loadSrmSidecar) {
      auto trySrm = [&](const std::string& srmPath) {
        auto srm = readFile(srmPath.c_str());
        if(srm.empty()) return false;
        size_t n = srm.size() < ram.size() ? srm.size() : ram.size();
        for(size_t i = 0; i < n; i++) ram[i] = srm[i];
        std::fprintf(stderr, "kintsuki: seeded SRAM from %s (%zu bytes)\n",
                     srmPath.c_str(), n);
        return true;
      };
      if(!trySrm(p + ".srm")) {
        auto dot = p.find_last_of('.');
        if(dot != std::string::npos) trySrm(p.substr(0, dot) + ".srm");
      }
    }
    attachFile(cartPak, "save.ram", std::move(ram));
  }

  if(romData.size() < info.programSize) {
    romData.resize(info.programSize, 0);
  }
  // ROM data lives in this->romData for the program lifetime — no keepalive.
  auto romFile = vfs::memory::open(
    std::span<const uint8_t>(romData.data(), romData.size()));
  romFile->setName("program.rom");
  cartPak->append(romFile);

  return true;
}

auto Program::bootRom() -> bool {
  // Performance PPU works fine — the earlier "no pixels" symptom was the
  // missing port.allocate/connect call (see below), not a PPU choice.
  SuperFamicom::ppu.setAccurate(false);

  Node::System root;
  string profile = "[Nintendo] Super Famicom (NTSC)";
  if(!SuperFamicom::load(root, profile)) return false;

  // Walk the node tree to wire up:
  //   1. Cartridge Slot — allocate + connect → loadCartridge runs and
  //      builds the memory map. Without this, ROM is never mapped.
  //   2. Controller Port 1/2 — allocate "Gamepad" so the buttons exist
  //      as Input nodes; otherwise platform->input() is never called
  //      and our setButton bitmask never reaches the SNES.
  for(auto& node : *root) {
    auto port = std::dynamic_pointer_cast<Core::Port>(node);
    if(!port) continue;
    auto pname = port->name();
    if(pname.match("*Cartridge*")) {
      port->allocate(pname);
      port->connect();
    } else if(pname.match("*Controller Port*")) {
      port->allocate("Gamepad");
      port->connect();
    }
  }

  SuperFamicom::system.power(false);
  loaded = true;
  return true;
}

auto Program::softReset() -> void {
  if(!loaded) return;
  SuperFamicom::system.power(true);
}

auto Program::injectSram(const u8* data, u32 len) -> u32 {
  if(!loaded || !data) return 0;
  auto& ram = SuperFamicom::cartridge.ram;
  u32 cap = (u32)ram.size();
  if(cap == 0) return 0;
  u32 n = len < cap ? len : cap;
  for(u32 i = 0; i < n; i++) ram.data()[i] = data[i];
  return n;
}

auto Program::runFrames(u32 n) -> void {
  if(!loaded) return;
  // Clear the sticky halt flag at the top so a previously-fired BP
  // doesn't immediately re-bail on the next call. The flag will be
  // re-raised mid-run when the BP exec hook fires again.
  SuperFamicom::kintsukiHaltRequested = false;
  u64 target = framesRendered + n;
  u64 spin = 0;
  u64 spinCap = u64(n) * 10'000'000ull;
  while(framesRendered < target && spin++ < spinCap) {
    SuperFamicom::system.run();
    // If the CPU has executed STP, instructionStop sits in a tight
    // libco wait loop with the SMP coroutine — PPU eventually gets
    // starved and `framesRendered` never advances. Bail as soon as
    // r.stp is observed so the host loop can react (paint the halt
    // overlay, prompt for reset) instead of spinning the scheduler.
    if(SuperFamicom::cpu.r.stp) break;
    // Halting breakpoint hit: scheduler.exit yielded the coroutine on
    // the bail flag, but without the sticky halt this loop would just
    // resume system.run() and keep executing past the BP. Bail here
    // so the host sees PC at the BP address.
    if(SuperFamicom::kintsukiHaltRequested) break;
  }
}

auto Program::memRead(u32 addr) -> u8 {
  return SuperFamicom::bus.read(addr & 0xffffff, 0);
}

auto Program::memWrite(u32 addr, u8 val) -> void {
  SuperFamicom::bus.write(addr & 0xffffff, val);
}

// VRAM lives in the performance PPU's vram member (n16[64K]).
auto Program::vramRead(u32 addr) -> u8 {
  uint16_t word = SuperFamicom::ppuPerformanceImpl.vram.data[(addr >> 1) & 0x7fff];
  return (addr & 1) ? (word >> 8) : (word & 0xff);
}

auto Program::vramWrite(u32 addr, u8 val) -> void {
  u32 idx = (addr >> 1) & 0x7fff;
  auto& word = SuperFamicom::ppuPerformanceImpl.vram.data[idx];
  uint16_t w = word;
  if(addr & 1) w = (w & 0x00ff) | (uint16_t(val) << 8);
  else         w = (w & 0xff00) | val;
  word = w;
}

// CGRAM is 256 entries of 15-bit color in DAC.
auto Program::cgramRead(u32 addr) -> u8 {
  uint16_t word = (uint16_t)(uint16_t)SuperFamicom::ppuPerformanceImpl.dac.cgram[(addr >> 1) & 0xff];
  return (addr & 1) ? (word >> 8) : (word & 0xff);
}

auto Program::cgramWrite(u32 addr, u8 val) -> void {
  u32 idx = (addr >> 1) & 0xff;
  uint16_t w = (uint16_t)(uint16_t)SuperFamicom::ppuPerformanceImpl.dac.cgram[idx];
  if(addr & 1) w = (w & 0x00ff) | (uint16_t(val) << 8);
  else         w = (w & 0xff00) | val;
  SuperFamicom::ppuPerformanceImpl.dac.cgram[idx] = w & 0x7fff;
}

auto Program::oamRead(u32 addr) -> u8 {
  return SuperFamicom::ppuPerformanceImpl.obj.oam.read(addr & 0x3ff);
}

auto Program::oamWrite(u32 addr, u8 val) -> void {
  SuperFamicom::ppuPerformanceImpl.obj.oam.write(addr & 0x3ff, val);
}

auto Program::getCpuState() const -> CpuState {
  auto& r = SuperFamicom::cpu.r;
  CpuState s;
  s.a  = (uint16_t)(uint16_t)r.a.w;
  s.x  = (uint16_t)(uint16_t)r.x.w;
  s.y  = (uint16_t)(uint16_t)r.y.w;
  s.s  = (uint16_t)(uint16_t)r.s.w;
  s.d  = (uint16_t)(uint16_t)r.d.w;
  s.b  = (uint8_t) r.b;
  s.p  = (uint8_t) (n8)r.p;
  s.pc = (uint32_t)(uint32_t)r.pc.d;
  s.e  = r.e;
  s.stp = r.stp;
  s.wai = r.wai;
  return s;
}

auto Program::setCpuState(const CpuState& s) -> void {
  auto& r = SuperFamicom::cpu.r;
  r.a.w  = s.a;
  r.x.w  = s.x;
  r.y.w  = s.y;
  r.s.w  = s.s;
  r.d.w  = s.d;
  r.b    = s.b;
  r.p    = s.p;
  r.pc.d = s.pc;
  r.e    = s.e;
  r.wai  = s.wai;
  r.stp  = s.stp;
  // Clear pending interrupts so the next scheduler entry doesn't divert
  // through the reset/NMI/IRQ vector and clobber the PC we just set.
  SuperFamicom::cpu.clearPendingInterrupts();
}

// =============================================================================
// KSSF footer (v1.0)
//
// ares' serializer is a flat positional byte stream with no per-block size
// markers: the cart's sram region length is determined by the *currently
// bound* cart, not by anything in the blob. A cross-ROM load_state where
// sram sizes differ silently misaligns every downstream field (cpu/ppu/...)
// because the cart.sram chunk shifts in size.
//
// To make cross-ROM restores tractable, every blob produced by
// saveStateBlob is suffixed with a footer mapping the cart.sram region
// (offset + length) inside the ares blob. ares' reader stops when
// System::unserialize returns, so the trailing bytes are inert to it.
//
// Layout:
//
//   [ares blob ............]
//   [version_major:u16 LE][version_minor:u16 LE]
//   [TLV stream ..........]
//   [footer_len:u32 LE]      ← size of (version + TLV stream); excl. trailer
//   [MAGIC:u32 "KSSF" LE]
//
// TLV entry:
//
//   name_len  : u8        (1..255; 0 reserved)
//   name      : utf8[name_len]
//   data_len  : u32 LE
//   data      : u8[data_len]
//
// Unknown names are skipped (forward-compat). Reader is tail-first: check
// magic, read footer_len, parse TLVs. Absent magic → legacy blob, fall
// back to current ares-only behavior.
// =============================================================================

namespace {

constexpr uint32_t KSSF_MAGIC = 0x4653534b;  // "KSSF" little-endian
constexpr uint16_t KSSF_VER_MAJOR = 1;
constexpr uint16_t KSSF_VER_MINOR = 0;

// Mirror System::serialize's prefix (header + random) to learn the byte
// offset at which Cartridge::serialize starts. Coupled to ares layout: if
// ares grows new fields before cartridge, this probe needs the same fields
// added to stay correct.
auto probeCartSramOffset() -> uint32_t {
  serializer probe;
  u32  sig = ares::SerializerSignature;
  bool sync = true;
  char ver[16] = {};
  char desc[512] = {};
  bool ppuAcc = SuperFamicom::ppu.accurate;
  probe(sig);
  probe(sync);
  probe(ver);
  probe(desc);
  probe(ppuAcc);
  SuperFamicom::random.serialize(probe);
  return (uint32_t)probe.size();
}

auto writeU16LE(std::vector<uint8_t>& out, uint16_t v) -> void {
  out.push_back((uint8_t)(v & 0xff));
  out.push_back((uint8_t)((v >> 8) & 0xff));
}

auto writeU32LE(std::vector<uint8_t>& out, uint32_t v) -> void {
  out.push_back((uint8_t)(v & 0xff));
  out.push_back((uint8_t)((v >> 8) & 0xff));
  out.push_back((uint8_t)((v >> 16) & 0xff));
  out.push_back((uint8_t)((v >> 24) & 0xff));
}

auto writeTLV(std::vector<uint8_t>& out, const char* name,
              const uint8_t* data, uint32_t dataLen) -> void {
  size_t nameLen = std::strlen(name);
  if(nameLen == 0 || nameLen > 255) return;
  out.push_back((uint8_t)nameLen);
  for(size_t i = 0; i < nameLen; i++) out.push_back((uint8_t)name[i]);
  writeU32LE(out, dataLen);
  for(uint32_t i = 0; i < dataLen; i++) out.push_back(data[i]);
}

auto readU16LE(const uint8_t* p) -> uint16_t {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

auto readU32LE(const uint8_t* p) -> uint32_t {
  return  (uint32_t)p[0]
       | ((uint32_t)p[1] << 8)
       | ((uint32_t)p[2] << 16)
       | ((uint32_t)p[3] << 24);
}

struct KssfRegion {
  uint32_t offset = 0;
  uint32_t length = 0;
  bool     present = false;
};

struct KssfFooter {
  bool        present  = false;   // false if blob has no recognised footer
  bool        valid    = false;   // false if magic present but parse failed
  uint16_t    verMajor = 0;
  uint16_t    verMinor = 0;
  uint32_t    aresBlobLen = 0;    // bytes before footer (or total len if absent)
  KssfRegion  cartSram;
};

auto parseKssfFooter(const uint8_t* data, uint32_t size) -> KssfFooter {
  KssfFooter f;
  f.aresBlobLen = size;
  if(size < 8) return f;
  if(readU32LE(data + size - 4) != KSSF_MAGIC) return f;
  uint32_t footerLen = readU32LE(data + size - 8);
  if(footerLen < 4 || footerLen + 8 > size) {
    f.present = true;   // magic matched but layout broken
    return f;
  }
  const uint8_t* footer = data + size - 8 - footerLen;
  f.present     = true;
  f.verMajor    = readU16LE(footer + 0);
  f.verMinor    = readU16LE(footer + 2);
  f.aresBlobLen = size - 8 - footerLen;

  // v1: only major must match; unknown minors are forward-compat.
  if(f.verMajor != KSSF_VER_MAJOR) return f;

  uint32_t cursor = 4;
  while(cursor < footerLen) {
    if(cursor + 1 > footerLen) return f;
    uint8_t nameLen = footer[cursor++];
    if(nameLen == 0 || cursor + nameLen + 4 > footerLen) return f;
    std::string name((const char*)(footer + cursor), nameLen);
    cursor += nameLen;
    uint32_t dataLen = readU32LE(footer + cursor);
    cursor += 4;
    if(cursor + dataLen > footerLen) return f;
    const uint8_t* tlvData = footer + cursor;
    cursor += dataLen;

    if(name == "cart.sram" && dataLen == 8) {
      f.cartSram.offset  = readU32LE(tlvData + 0);
      f.cartSram.length  = readU32LE(tlvData + 4);
      f.cartSram.present = true;
    }
    // unknown TLVs: skip silently (forward-compat)
  }
  f.valid = true;
  return f;
}

}  // anonymous namespace

auto Program::saveStateBlob() -> std::vector<uint8_t> {
  serializer s = SuperFamicom::system.serialize(true);
  std::vector<uint8_t> out(s.size());
  std::memcpy(out.data(), s.data(), s.size());

  // Append KSSF footer with cart.sram region, when there is one.
  uint32_t sramSize = (uint32_t)SuperFamicom::cartridge.ram.size();
  if(sramSize == 0) return out;

  uint32_t sramOffset = probeCartSramOffset();
  // Sanity: offset+length must fit inside the ares blob; otherwise the
  // probe doesn't match this ares revision and we shouldn't lie about it.
  if(sramOffset + sramSize > out.size()) return out;

  std::vector<uint8_t> footer;
  writeU16LE(footer, KSSF_VER_MAJOR);
  writeU16LE(footer, KSSF_VER_MINOR);

  uint8_t region[8];
  region[0] = (uint8_t)(sramOffset & 0xff);
  region[1] = (uint8_t)((sramOffset >> 8) & 0xff);
  region[2] = (uint8_t)((sramOffset >> 16) & 0xff);
  region[3] = (uint8_t)((sramOffset >> 24) & 0xff);
  region[4] = (uint8_t)(sramSize & 0xff);
  region[5] = (uint8_t)((sramSize >> 8) & 0xff);
  region[6] = (uint8_t)((sramSize >> 16) & 0xff);
  region[7] = (uint8_t)((sramSize >> 24) & 0xff);
  writeTLV(footer, "cart.sram", region, 8);

  uint32_t footerLen = (uint32_t)footer.size();
  out.insert(out.end(), footer.begin(), footer.end());
  writeU32LE(out, footerLen);
  writeU32LE(out, KSSF_MAGIC);
  return out;
}

auto Program::loadStateBlob(const uint8_t* data, u32 size) -> bool {
  // Footer is opt-in for the legacy entry point: if present, just strip it
  // before handing the inner blob to ares. No size reconciliation happens
  // here — callers wanting cross-ROM behavior go through loadStateBlobEx.
  auto footer = parseKssfFooter(data, size);
  u32 aresLen = footer.present ? footer.aresBlobLen : size;
  serializer s(data, aresLen);
  return SuperFamicom::system.unserialize(s);
}

auto Program::loadStateBlobEx(const uint8_t* data, u32 size,
                              u32 flags, u32 expectedSramSize) -> int {
  if(!loaded || !data || size == 0) return 0;

  constexpr u32 FLAG_STRICT      = 1u << 0;
  constexpr u32 FLAG_REMAP       = 1u << 1;
  constexpr u32 FLAG_INJECT_ONLY = 1u << 2;

  auto footer = parseKssfFooter(data, size);

  // Resolve producer sram size:
  //   1. explicit expectedSramSize from caller
  //   2. footer's cart.sram region length
  //   3. assume equal to bound cart (legacy)
  u32 producerSram = 0;
  if(expectedSramSize != 0) {
    producerSram = expectedSramSize;
  } else if(footer.valid && footer.cartSram.present) {
    producerSram = footer.cartSram.length;
  }

  u32 cartSram = (u32)SuperFamicom::cartridge.ram.size();

  if(flags & FLAG_INJECT_ONLY) {
    // Need a footer to know where sram lives in the blob. (Or, in the
    // future, an explicit offset field in opts.)
    if(!footer.valid || !footer.cartSram.present) return 0;
    u32 srcOff = footer.cartSram.offset;
    u32 srcLen = footer.cartSram.length;
    if(srcOff + srcLen > footer.aresBlobLen) return 0;

    std::vector<uint8_t> slice(cartSram, 0);
    u32 n = srcLen < cartSram ? srcLen : cartSram;
    std::memcpy(slice.data(), data + srcOff, n);

    if(flags & FLAG_STRICT) {
      if(srcLen != cartSram && producerSram != cartSram) return 0;
    }

    SuperFamicom::system.power(false);
    if(cartSram > 0) {
      std::memcpy(SuperFamicom::cartridge.ram.data(), slice.data(), cartSram);
    }
    return 1;
  }

  // Non-inject path: drive ares unserialize. STRICT and REMAP need
  // producer/cart sram comparison.
  bool sizeMismatch = (producerSram != 0 && producerSram != cartSram);

  if(flags & FLAG_STRICT) {
    if(sizeMismatch) return 0;
    if(producerSram == 0) return 0;  // STRICT requires a known producer size
  }

  if(sizeMismatch && (flags & FLAG_REMAP)) {
    // Rewrite the ares blob: pad-or-trim the cart.sram region to the
    // bound cart's size, then hand it to ares. Needs the footer to know
    // where the sram bytes live.
    if(!footer.valid || !footer.cartSram.present) return 0;
    u32 srcOff = footer.cartSram.offset;
    u32 srcLen = footer.cartSram.length;
    if(srcOff + srcLen > footer.aresBlobLen) return 0;

    std::vector<uint8_t> patched;
    patched.reserve(footer.aresBlobLen - srcLen + cartSram);
    patched.insert(patched.end(), data, data + srcOff);
    u32 copyLen = srcLen < cartSram ? srcLen : cartSram;
    patched.insert(patched.end(), data + srcOff, data + srcOff + copyLen);
    if(cartSram > copyLen) patched.insert(patched.end(), cartSram - copyLen, 0);
    patched.insert(patched.end(),
                   data + srcOff + srcLen,
                   data + footer.aresBlobLen);

    serializer s(patched.data(), (u32)patched.size());
    return SuperFamicom::system.unserialize(s) ? 1 : 0;
  }

  if(sizeMismatch) return 0;  // no flag covers this case → reject

  // Default path: equivalent to loadStateBlob.
  u32 aresLen = footer.present ? footer.aresBlobLen : size;
  serializer s(data, aresLen);
  return SuperFamicom::system.unserialize(s) ? 1 : 0;
}

auto Program::saveStateFile(const char* path) -> bool {
  auto blob = saveStateBlob();
  std::ofstream f(path, std::ios::binary);
  if(!f) return false;
  f.write((const char*)blob.data(), blob.size());
  return f.good();
}

auto Program::loadStateFile(const char* path) -> bool {
  auto blob = readFile(path);
  if(blob.empty()) return false;
  return loadStateBlob(blob.data(), blob.size());
}

// ares' performance PPU always emits a 564-pixel-wide framebuffer so the
// host renderer (e.g. Swift's MetalRenderer) can letterbox without caring
// about hires. For canonical PNG/PPM output we don't want that doubling
// when the PPU is in normal-mode — every other column is just a duplicate
// of the one before it. In hires (BGMODE 5/6) or pseudo-hires the columns
// carry distinct data, so the doubled width is real and we keep it.
auto Program::frameOutputWidth() const -> u32 {
  return ares::SuperFamicom::ppuPerformanceImpl.hires() ? fbWidth : fbWidth / 2;
}

auto Program::writePNG(const char* path) -> bool {
  if(!fbWidth || !fbHeight) return false;
  bool hires = ares::SuperFamicom::ppuPerformanceImpl.hires();
  u32 outW = hires ? fbWidth : fbWidth / 2;
  std::vector<uint8_t> rgb(size_t(outW) * fbHeight * 3);
  for(u32 y = 0; y < fbHeight; y++) {
    for(u32 x = 0; x < outW; x++) {
      u32 srcX = hires ? x : x * 2;
      u32 px = fb[y * fbWidth + srcX];
      uint8_t* dst = rgb.data() + (y * outW + x) * 3;
      dst[0] = (uint8_t)((px >> 16) & 0xff);
      dst[1] = (uint8_t)((px >>  8) & 0xff);
      dst[2] = (uint8_t)((px >>  0) & 0xff);
    }
  }
  return stbi_write_png(path, outW, fbHeight, 3, rgb.data(), outW * 3) != 0;
}

auto Program::writePPM(const char* path) -> bool {
  if(!fbWidth || !fbHeight) return false;
  bool hires = ares::SuperFamicom::ppuPerformanceImpl.hires();
  u32 outW = hires ? fbWidth : fbWidth / 2;
  std::ofstream f(path, std::ios::binary);
  if(!f) return false;
  f << "P6\n" << outW << " " << fbHeight << "\n255\n";
  for(u32 y = 0; y < fbHeight; y++) {
    for(u32 x = 0; x < outW; x++) {
      u32 srcX = hires ? x : x * 2;
      u32 px = fb[y * fbWidth + srcX];
      uint8_t rgb[3] = {
        (uint8_t)((px >> 16) & 0xff),
        (uint8_t)((px >>  8) & 0xff),
        (uint8_t)((px >>  0) & 0xff),
      };
      f.write((const char*)rgb, 3);
    }
  }
  return f.good();
}

auto Program::writeScreenshot(const char* path) -> bool {
  size_t n = std::strlen(path);
  if(n >= 4 && std::strcmp(path + n - 4, ".ppm") == 0) return writePPM(path);
  return writePNG(path);
}

auto Program::setButton(u32 port, u32 button, bool pressed) -> void {
  if(port >= 2 || button >= 16) return;
  if(pressed) inputState[port] |= (uint16_t(1) << button);
  else        inputState[port] &= ~(uint16_t(1) << button);
}

auto Program::clearInput() -> void {
  inputState[0] = inputState[1] = 0;
}
