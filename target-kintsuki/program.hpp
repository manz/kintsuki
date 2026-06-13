// Program: Lua-free Emulator::Platform wrapper around ares' SNES core.
// Owns ROM bytes, framebuffer capture, button state, and savestate I/O.

#pragma once

#include <ares/ares.hpp>
#include <sfc/sfc.hpp>

#include <atomic>
#include <cstdint>
#include <string>
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

  // ROM introspection — populated by `loadRom`. Empty / zero / false when
  // no ROM is loaded.
  auto romBytes() const -> const uint8_t* { return romData.empty() ? nullptr : romData.data(); }
  auto romSize()  const -> uint32_t       { return (uint32_t)romData.size(); }
  // sha256 of the ROM *post copier-header-strip but pre IPS patch*. Used
  // by the project file to lock a project to a pristine ROM identity even
  // when the user is running with a patch applied.
  auto romPristineSha() const -> const std::string& { return romPristineSha256; }
  // true => HiROM mapper, false => LoROM. ExHiROM not currently supported
  // by detectRom; falls through to HiROM here.
  auto romIsHiRom() const -> bool { return romHiRom; }
  // Full cart manifest in BML form — authoritative bus map, including
  // coprocessor mappings (SA-1, GSU, SDD-1, ...). Empty when no ROM is
  // loaded. The project file stores this verbatim so a project can be
  // reopened against a different binary revision without re-running
  // detection. Pointer borrows from Program-owned storage; valid until
  // the next `loadRom`.
  auto romManifest() const -> const std::string& { return cartManifestStr; }
  auto bootRom() -> bool;
  auto runFrames(u32 n) -> void;
  auto softReset() -> void;
  auto injectSram(const u8* data, u32 len) -> u32;

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

  // Savestate. saveStateBlob appends a KSSF footer (region map for
  // cross-ROM load_state_ex). loadStateBlob strips the footer if present
  // and is otherwise backwards-compatible with footer-less blobs.
  auto saveStateBlob() -> std::vector<uint8_t>;
  auto loadStateBlob(const uint8_t* data, u32 size) -> bool;
  auto saveStateFile(const char* path) -> bool;
  auto loadStateFile(const char* path) -> bool;

  // Extended loader. flags = bitmask of KINTSUKI_LOAD_FLAG_*.
  // expectedSramSize: 0 = use footer / no override.
  // Returns 1 on success, 0 on failure.
  auto loadStateBlobEx(const uint8_t* data, u32 size,
                       u32 flags, u32 expectedSramSize) -> int;

  // Screenshot
  auto writePNG(const char* path) -> bool;
  auto writePPM(const char* path) -> bool;
  auto writeScreenshot(const char* path) -> bool;
  // Width of the corrected (hires-aware) screenshot output: full native
  // width in hires / pseudo-hires mode, half of it (single column per
  // pixel) in normal mode where ares duplicates columns to keep the
  // renderer happy.
  auto frameOutputWidth() const -> u32;

  // ---- Audio output -----------------------------------------------------
  // ares pushes resampled stereo samples (at audioSampleRate) through the
  // `audio()` platform callback as the SPC/DSP runs. We funnel them into a
  // lock-free SPSC ring drained by the host's real-time audio thread
  // (CoreAudio render callback in the macOS app). Disabled by default so
  // headless / Python use accrues no overhead; the app flips it on.
  static constexpr double   audioSampleRate = 48000.0;
  // Power-of-two stereo-frame capacity (~170ms @ 48kHz), big enough to
  // absorb the jitter between the 60Hz emulation tick and the audio clock.
  static constexpr uint32_t audioRingFrames = 8192;

  auto setAudioEnabled(bool enable) -> void;
  auto audioEnabledState() const -> bool { return audioEnabled; }
  // Consumer side (host audio thread): copy up to `frames` interleaved
  // stereo frames into `out` (length >= frames*2). Returns frames written.
  auto audioRead(float* out, uint32_t frames) -> uint32_t;
  // Stereo frames currently queued.
  auto audioAvailable() const -> uint32_t;

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

  // When true (default), `loadRom` seeds cart SRAM from a `<rom>.srm`
  // sidecar if one exists. Tests flip this off so deterministic SRAM
  // doesn't get clobbered by an accidental save file.
  bool loadSrmSidecar = true;

private:
  // ROM image + cart pak built at load_rom().
  std::vector<uint8_t> romData;
  std::string romPristineSha256;  // hex digest, lowercase
  bool        romHiRom = false;
  std::string cartManifestStr;  // std::string mirror of cartManifest for C++ consumers
  string cartManifest;
  std::shared_ptr<vfs::directory> cartPak;

  // System pak (boards.bml + ipl.rom) built at construction.
  std::shared_ptr<vfs::directory> systemPak;

  // Audio ring (interleaved stereo f32). Single producer (emulation thread,
  // via the `audio()` callback) / single consumer (host audio thread).
  // Free-running u32 indices; capacity is a power of two so wrap is a mask.
  std::vector<float>    audioRing;
  std::atomic<uint32_t> audioWriteIdx{0};
  std::atomic<uint32_t> audioReadIdx{0};
  bool                  audioEnabled = false;

  auto audioPushFrame(float l, float r) -> void;

  // Track which pak() call we're on. ares calls pak() once for the system
  // node and once for the cartridge peripheral; we identify by node name.
  bool loaded = false;
};

// Process-wide singleton handle: ares core uses globals (cpu, ppu, bus) so
// only one Program may exist at a time.
extern Program* kintsukiProgram;
