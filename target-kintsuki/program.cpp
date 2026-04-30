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

  kintsuki::RomInfo info;
  if(!kintsuki::detectRom(romData, info)) return false;

  std::string m = kintsuki::buildManifest(info);
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

  // Walk the node tree to find the Cartridge Slot port and allocate +
  // connect it. ares' desktop UI does this after the user picks a ROM;
  // headless we do it programmatically. Without this loadCartridge()
  // never runs, no memory map is built, the CPU executes 0xFF garbage,
  // and the PPU outputs an all-black framebuffer.
  for(auto& node : *root) {
    auto port = std::dynamic_pointer_cast<Core::Port>(node);
    if(!port) continue;
    if(port->name().match("*Cartridge*")) {
      port->allocate(port->name());
      port->connect();
      break;
    }
  }

  SuperFamicom::system.power(false);
  loaded = true;
  return true;
}

auto Program::runFrames(u32 n) -> void {
  if(!loaded) return;
  u64 target = framesRendered + n;
  u64 spin = 0;
  u64 spinCap = u64(n) * 10'000'000ull;
  while(framesRendered < target && spin++ < spinCap) {
    SuperFamicom::system.run();
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
}

auto Program::saveStateBlob() -> std::vector<uint8_t> {
  serializer s = SuperFamicom::system.serialize(true);
  std::vector<uint8_t> out(s.size());
  std::memcpy(out.data(), s.data(), s.size());
  return out;
}

auto Program::loadStateBlob(const uint8_t* data, u32 size) -> bool {
  serializer s(data, size);
  return SuperFamicom::system.unserialize(s);
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

auto Program::writePNG(const char* path) -> bool {
  if(!fbWidth || !fbHeight) return false;
  std::vector<uint8_t> rgb(size_t(fbWidth) * fbHeight * 3);
  for(u32 i = 0; i < fbWidth * fbHeight; i++) {
    u32 px = fb[i];
    rgb[i*3 + 0] = (uint8_t)((px >> 16) & 0xff);
    rgb[i*3 + 1] = (uint8_t)((px >>  8) & 0xff);
    rgb[i*3 + 2] = (uint8_t)((px >>  0) & 0xff);
  }
  return stbi_write_png(path, fbWidth, fbHeight, 3, rgb.data(), fbWidth * 3) != 0;
}

auto Program::writePPM(const char* path) -> bool {
  if(!fbWidth || !fbHeight) return false;
  std::ofstream f(path, std::ios::binary);
  if(!f) return false;
  f << "P6\n" << fbWidth << " " << fbHeight << "\n255\n";
  for(u32 i = 0; i < fbWidth * fbHeight; i++) {
    u32 px = fb[i];
    uint8_t rgb[3] = {
      (uint8_t)((px >> 16) & 0xff),
      (uint8_t)((px >>  8) & 0xff),
      (uint8_t)((px >>  0) & 0xff),
    };
    f.write((const char*)rgb, 3);
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
