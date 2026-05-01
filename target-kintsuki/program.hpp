// Program: Lua-free Emulator::Platform wrapper around ares' SNES core.
// Owns ROM bytes, framebuffer capture, button state, and savestate I/O.

#pragma once

#include <ares/ares.hpp>
#include <sfc/sfc.hpp>

#include <cstdint>
#include <vector>

using namespace nall;

// Plain CPU register snapshot (no Lua coupling).
struct CpuState {
  uint16_t a, x, y, s, d;
  uint8_t  b, p;
  uint32_t pc;  // 24-bit
  bool     e;
  bool     stp;  // STP halted
  bool     wai;  // WAI waiting for IRQ
};

struct Program : ares::Platform {
  Program();
  ~Program();

  // ares::Platform overrides
  auto attach(ares::Node::Object) -> void override;
  auto pak(ares::Node::Object) -> std::shared_ptr<vfs::directory> override;
  auto event(ares::Event) -> void override;
  auto log(ares::Node::Debugger::Tracer::Tracer, string_view) -> void override;
  auto video(ares::Node::Video::Screen, const u32* data, u32 pitch, u32 width, u32 height) -> void override;
  auto audio(ares::Node::Audio::Stream) -> void override;
  auto input(ares::Node::Input::Input) -> void override;

  // ROM lifecycle
  auto loadRom(const char* path) -> bool;
  auto bootRom() -> bool;
  auto runFrames(u32 n) -> void;

  // Memory: CPU bus (24-bit address)
  auto memRead(u32 addr) -> u8;
  auto memWrite(u32 addr, u8 val) -> void;

  // PPU memory (off-bus). Address in bytes.
  auto vramRead(u32 addr) -> u8;
  auto vramWrite(u32 addr, u8 val) -> void;
  auto cgramRead(u32 addr) -> u8;
  auto cgramWrite(u32 addr, u8 val) -> void;
  auto oamRead(u32 addr) -> u8;
  auto oamWrite(u32 addr, u8 val) -> void;

  // CPU state
  auto getCpuState() const -> CpuState;
  auto setCpuState(const CpuState& s) -> void;

  // Savestate
  auto saveStateBlob() -> std::vector<uint8_t>;
  auto loadStateBlob(const uint8_t* data, u32 size) -> bool;
  auto saveStateFile(const char* path) -> bool;
  auto loadStateFile(const char* path) -> bool;

  // Screenshot
  auto writePNG(const char* path) -> bool;
  auto writePPM(const char* path) -> bool;
  auto writeScreenshot(const char* path) -> bool;

  // Input. Bits indexed by Gamepad enum
  // (Up=0, Down=1, Left=2, Right=3, B=4, A=5, Y=6, X=7, L=8, R=9, Select=10, Start=11).
  auto setButton(u32 port, u32 button, bool pressed) -> void;
  auto clearInput() -> void;

  // Captured framebuffer (RGBA8888 packed in u32).
  std::vector<uint32_t> fb;
  u32 fbWidth = 0;
  u32 fbHeight = 0;
  u64 framesRendered = 0;

  // Per-port input bitmask. 12 bits used.
  uint16_t inputState[2] = {0, 0};

private:
  // ROM image + cart pak built at load_rom().
  std::vector<uint8_t> romData;
  string cartManifest;
  std::shared_ptr<vfs::directory> cartPak;

  // System pak (boards.bml + ipl.rom) built at construction.
  std::shared_ptr<vfs::directory> systemPak;

  // Track which pak() call we're on. ares calls pak() once for the system
  // node and once for the cartridge peripheral; we identify by node name.
  bool loaded = false;
};

// Process-wide singleton handle: ares core uses globals (cpu, ppu, bus) so
// only one Program may exist at a time.
extern Program* kintsukiProgram;
