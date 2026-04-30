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
#include <cstring>
#include <fstream>
#include <iterator>

Program* kintsukiProgram = nullptr;

namespace {

// Slurp a file into a vector. Returns empty on failure.
auto readFile(const char* path) -> std::vector<uint8_t> {
  std::ifstream f(path, std::ios::binary);
  if(!f) return {};
  return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}

// Build the system pak. ares loads boards.bml + ipl.rom from here. We bundle
// the files shipped with ares' source tree under ares/System/Super Famicom/.
auto makeSystemPak() -> std::shared_ptr<vfs::directory> {
  auto dir = std::make_shared<vfs::directory>();
  // KINTSUKI_SYSTEM_PAK env var lets the user point at an alternate location;
  // fall back to compile-time path baked at build via -DKINTSUKI_SYSTEM_PAK=...
  const char* base = std::getenv("KINTSUKI_SYSTEM_PAK");
  if(!base) base = KINTSUKI_SYSTEM_PAK_DEFAULT;

  auto loadInto = [&](const char* name) {
    string path{base, "/", name};
    auto data = readFile(path);
    if(data.empty()) return;
    // memory::open takes a non-owning span, so we keep the bytes alive on
    // the heap via a static cache. (Files are small and load-once.)
    static std::vector<std::vector<uint8_t>> keepalive;
    keepalive.push_back(std::move(data));
    auto& kept = keepalive.back();
    auto file = vfs::memory::open(std::span<const uint8_t>(kept.data(), kept.size()));
    file->setName(name);
    dir->append(file);
  };

  loadInto("boards.bml");
  loadInto("ipl.rom");
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

auto Program::attach(ares::Node::Object) -> void {
  // No tree mirroring needed for headless. ares still walks input nodes
  // each poll; we handle them in input() below.
}

auto Program::pak(ares::Node::Object node) -> std::shared_ptr<vfs::directory> {
  if(!node) return {};
  string name = node->name();
  if(name == "Super Famicom") return systemPak;
  if(name.match("*Cartridge*")) return cartPak;
  return {};
}

auto Program::event(ares::Event) -> void {}

auto Program::log(ares::Node::Debugger::Tracer::Tracer, string_view msg) -> void {
  std::fwrite(msg.data(), 1, msg.size(), stderr);
  std::fputc('\n', stderr);
}

auto Program::video(ares::Node::Video::Screen, const u32* data, u32 pitch, u32 width, u32 height) -> void {
  fbWidth = width;
  fbHeight = height;
  size_t pixels = size_t(width) * height;
  if(fb.size() < pixels) fb.resize(pixels);
  // pitch is bytes; data is u32 per pixel.
  u32 stride = pitch / sizeof(u32);
  for(u32 y = 0; y < height; y++) {
    const u32* src = data + y * stride;
    uint32_t* dst = fb.data() + y * width;
    std::memcpy(dst, src, width * sizeof(u32));
  }
  framesRendered++;
}

auto Program::audio(ares::Node::Audio::Stream) -> void {}

auto Program::input(ares::Node::Input::Input node) -> void {
  // ares calls us once per button per poll. Walk to the parent peripheral
  // (Gamepad) and its parent port to identify which port we're on.
  auto button = std::dynamic_pointer_cast<ares::Node::Input::Button>(node);
  if(!button) return;

  // Lookup port index by climbing the node tree. Each gamepad sits under
  // "Controller Port 1" or "Controller Port 2".
  auto self = std::static_pointer_cast<ares::Node::Object>(node);
  uint port = 0;
  for(auto p = self->parent().lock(); p; p = p->parent().lock()) {
    auto pname = p->name();
    if(pname.match("*Port*1*"))      { port = 0; break; }
    if(pname.match("*Port*2*"))      { port = 1; break; }
  }

  // Map button name to bit index (matches Gamepad enum order).
  static const std::pair<const char*, int> map[] = {
    {"Up", 0}, {"Down", 1}, {"Left", 2}, {"Right", 3},
    {"B", 4},  {"A", 5},    {"Y", 6},    {"X", 7},
    {"L", 8},  {"R", 9},    {"Select", 10}, {"Start", 11},
  };
  string name = button->name();
  for(auto& [k, bit] : map) {
    if(name == k) {
      button->setValue((inputState[port] >> bit) & 1);
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

  cartManifest = kintsuki::buildManifest(info).c_str();

  // Build cart pak: manifest.bml + program.rom (full ROM).
  cartPak = std::make_shared<vfs::directory>();

  // manifest.bml — keep alive on the heap (vfs::memory::open is non-owning).
  static std::vector<std::vector<uint8_t>> keepalive;
  std::vector<uint8_t> manifestBytes(cartManifest.begin(), cartManifest.end());
  keepalive.push_back(std::move(manifestBytes));
  auto manifestFile = vfs::memory::open(
    std::span<const uint8_t>(keepalive.back().data(), keepalive.back().size()));
  manifestFile->setName("manifest.bml");
  cartPak->append(manifestFile);

  // program.rom — pad to programSize so ares' map calculations don't fault.
  if(romData.size() < info.programSize) {
    romData.resize(info.programSize, 0);
  }
  auto romFile = vfs::memory::open(
    std::span<const uint8_t>(romData.data(), romData.size()));
  romFile->setName("program.rom");
  cartPak->append(romFile);

  return true;
}

auto Program::bootRom() -> bool {
  ares::Node::System root;
  string profile = "[Nintendo] Super Famicom (NTSC)";
  if(!ares::SuperFamicom::load(root, profile)) return false;
  ares::SuperFamicom::system.power(false);
  loaded = true;
  return true;
}

auto Program::runFrames(u32 n) -> void {
  if(!loaded) return;
  // ares::SuperFamicom::system.run() advances by one PPU frame because the
  // PPU calls platform->video() at vblank; the scheduler returns once it
  // sees the Frame event. We loop n times.
  u64 target = framesRendered + n;
  u64 spinCap = u64(n) * 10'000'000ull;
  u64 spin = 0;
  while(framesRendered < target && spin++ < spinCap) {
    ares::SuperFamicom::system.run();
  }
}

auto Program::memRead(u32 addr) -> u8 {
  return ares::SuperFamicom::bus.read(addr & 0xffffff, 0);
}

auto Program::memWrite(u32 addr, u8 val) -> void {
  ares::SuperFamicom::bus.write(addr & 0xffffff, val);
}

// PPU memory: ares' performance PPU isn't installed in this build (we only
// included sfc/ppu, the cycle-accurate one). vram is uint16[].
auto Program::vramRead(u32 addr) -> u8 {
  uint16_t word = ares::SuperFamicom::ppu.vram[(addr >> 1) & 0x7fff];
  return (addr & 1) ? (word >> 8) : (word & 0xff);
}

auto Program::vramWrite(u32 addr, u8 val) -> void {
  u32 idx = (addr >> 1) & 0x7fff;
  uint16_t& word = ares::SuperFamicom::ppu.vram[idx];
  if(addr & 1) word = (word & 0x00ff) | (uint16_t(val) << 8);
  else         word = (word & 0xff00) | val;
}

auto Program::cgramRead(u32 addr) -> u8 {
  // ares cgram is a member of the obj/bg modules — accessed through public
  // io.cgramAddress / io.cgramData rather than a flat array. For now route
  // via the bus at $2122 — read-only side effect free path TODO. Stub.
  (void)addr;
  return 0;
}

auto Program::cgramWrite(u32 addr, u8 val) -> void { (void)addr; (void)val; }
auto Program::oamRead(u32 addr) -> u8 { (void)addr; return 0; }
auto Program::oamWrite(u32 addr, u8 val) -> void { (void)addr; (void)val; }

auto Program::getCpuState() const -> CpuState {
  CpuState s{};
  // ares cpu register layout — TODO once we wire hooks. Leave zeroed.
  return s;
}

auto Program::setCpuState(const CpuState& s) -> void { (void)s; }

auto Program::saveStateBlob() -> std::vector<uint8_t> {
  serializer s = ares::SuperFamicom::system.serialize(true);
  std::vector<uint8_t> out(s.size());
  std::memcpy(out.data(), s.data(), s.size());
  return out;
}

auto Program::loadStateBlob(const uint8_t* data, u32 size) -> bool {
  serializer s(data, size);
  return ares::SuperFamicom::system.unserialize(s);
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
