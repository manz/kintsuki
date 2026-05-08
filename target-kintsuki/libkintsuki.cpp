// kintsuki C ABI shim. extern "C" wrappers around Program for use by
// ctypes/Swift hosts. No Lua dependency.
//
// Single-instance: ares uses globals (cpu, ppu, bus); only one kintsuki_t
// may exist at a time.

#include "program.hpp"
#include "kintsuki.h"
#include "adbg.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <deque>

// kintsuki test-harness bail flag: defined in ares/sfc/system/system.cpp,
// read+cleared from cpu.cpp before each instruction. Declared here at
// file scope (outside extern "C") so the C++ name mangling matches.
namespace ares::SuperFamicom {
  extern volatile bool kintsukiBailRequested;
  extern volatile bool kintsukiHaltRequested;
  typedef void (*KintsukiDmaHook)(uint8_t, uint8_t, uint8_t,
                                  uint32_t, uint8_t, uint16_t);
  extern KintsukiDmaHook kintsukiDmaHook;
}

// ---- Shadow callstack + .adbg label table -------------------------------
// File-scope (C++ linkage) so they can be referenced from both the C ABI
// wrappers and the in-file anonymous-namespace tracer code below.
namespace {
constexpr size_t kCallstackCap = 256;
std::deque<kintsuki_call_frame_t> g_callstack;
kintsuki::AdbgLabels g_labels;
// Last label string emitted by the tracer as a `; --- name ---\n` header.
// Compared by pointer (AdbgLabels storage owns stable const char*). Reset
// to nullptr on tracer_start, load_adbg, clear_adbg, destroy.
const char* g_tracer_last_label = nullptr;

void cOnCall(uint32_t callsite_pc, uint32_t target_pc, uint8_t kind) {
  if(g_callstack.size() >= kCallstackCap) g_callstack.pop_front();
  kintsuki_call_frame_t f{};
  f.callsite_pc = callsite_pc & 0xFFFFFF;
  f.target_pc   = target_pc   & 0xFFFFFF;
  f.kind        = kind;
  g_callstack.push_back(f);
}

void cOnReturn(uint8_t kind) {
  (void)kind;
  if(!g_callstack.empty()) g_callstack.pop_back();
}
}  // namespace

extern "C" {

struct kintsuki_t {
  std::unique_ptr<Program> program;
};

// Defined further down (in the anonymous-namespace callback section).
static void resetAllCallbacks();

static kintsuki_t* g_handle = nullptr;

kintsuki_t* kintsuki_create(void) {
  if(g_handle) return g_handle;
  auto* h = new kintsuki_t();
  h->program = std::make_unique<Program>();
  kintsukiProgram = h->program.get();
  g_handle = h;
  // Wire the call/return hooks now and leave them on for the handle's
  // lifetime — non-debug builds that never inspect the callstack pay a
  // single null-check per JSR/RTS, identical to execHook's pattern.
  ares::callHook   = &cOnCall;
  ares::returnHook = &cOnReturn;
  g_callstack.clear();
  return h;
}

void kintsuki_destroy(kintsuki_t* h) {
  if(!h || h != g_handle) return;
  ares::SuperFamicom::system.unload();
  // Reset all callback state so the next kintsuki_create() doesn't
  // inherit stale callback closures from the previous handle.
  resetAllCallbacks();
  ares::SuperFamicom::execHook = nullptr;
  ares::SuperFamicom::memReadHook = nullptr;
  ares::SuperFamicom::memWriteHook = nullptr;
  ares::callHook = nullptr;
  ares::returnHook = nullptr;
  g_callstack.clear();
  g_labels.clear();
  g_tracer_last_label = nullptr;
  delete h;
  g_handle = nullptr;
  kintsukiProgram = nullptr;
}

int kintsuki_load_rom(kintsuki_t* h, const char* path) {
  if(!h) return 0;
  if(!h->program->loadRom(path)) return 0;
  if(!h->program->bootRom()) return 0;
  // Fresh cart = fresh call chain; previous run's frames are stale.
  g_callstack.clear();
  return 1;
}

void kintsuki_reset(kintsuki_t* h) {
  if(!h) return;
  h->program->softReset();
  // Reset wipes the live timeline; any retained frames describe a
  // call chain that no longer exists in the just-rebooted CPU.
  g_callstack.clear();
}

void kintsuki_set_srm_sidecar(kintsuki_t* h, int enable) {
  if(!h) return;
  h->program->loadSrmSidecar = (enable != 0);
}

uint32_t kintsuki_inject_sram(kintsuki_t* h, const uint8_t* data, uint32_t len) {
  if(!h) return 0;
  return h->program->injectSram(data, len);
}

void kintsuki_run_frames(kintsuki_t* h, uint32_t n) { if(h) h->program->runFrames(n); }
uint64_t kintsuki_frame_count(kintsuki_t* h) { return h ? h->program->framesRendered : 0; }

uint8_t kintsuki_read_u8(kintsuki_t* h, uint32_t addr) { return h ? h->program->memRead(addr) : 0; }
void kintsuki_write_u8(kintsuki_t* h, uint32_t addr, uint8_t val) { if(h) h->program->memWrite(addr, val); }

uint32_t kintsuki_read_range(kintsuki_t* h, uint32_t addr, uint32_t len, uint8_t* out) {
  if(!h || !out) return 0;
  for(uint32_t i = 0; i < len; i++) out[i] = h->program->memRead(addr + i);
  return len;
}

uint32_t kintsuki_write_range(kintsuki_t* h, uint32_t addr, uint32_t len, const uint8_t* in_) {
  if(!h || !in_) return 0;
  for(uint32_t i = 0; i < len; i++) h->program->memWrite(addr + i, in_[i]);
  return len;
}

uint8_t kintsuki_vram_read(kintsuki_t* h, uint32_t addr)             { return h ? h->program->vramRead(addr)  : 0; }
void    kintsuki_vram_write(kintsuki_t* h, uint32_t addr, uint8_t v) { if(h) h->program->vramWrite(addr, v); }

uint32_t kintsuki_vram_read_range(kintsuki_t* h, uint32_t addr, uint32_t len, uint8_t* out) {
  if(!h || !out) return 0;
  for(uint32_t i = 0; i < len; i++) out[i] = h->program->vramRead(addr + i);
  return len;
}

uint32_t kintsuki_vram_write_range(kintsuki_t* h, uint32_t addr, uint32_t len, const uint8_t* in_) {
  if(!h || !in_) return 0;
  for(uint32_t i = 0; i < len; i++) h->program->vramWrite(addr + i, in_[i]);
  return len;
}

uint32_t kintsuki_cgram_read_range(kintsuki_t* h, uint32_t addr, uint32_t len, uint8_t* out) {
  if(!h || !out) return 0;
  for(uint32_t i = 0; i < len; i++) out[i] = h->program->cgramRead(addr + i);
  return len;
}

uint32_t kintsuki_cgram_write_range(kintsuki_t* h, uint32_t addr, uint32_t len, const uint8_t* in_) {
  if(!h || !in_) return 0;
  for(uint32_t i = 0; i < len; i++) h->program->cgramWrite(addr + i, in_[i]);
  return len;
}

uint32_t kintsuki_oam_read_range(kintsuki_t* h, uint32_t addr, uint32_t len, uint8_t* out) {
  if(!h || !out) return 0;
  for(uint32_t i = 0; i < len; i++) out[i] = h->program->oamRead(addr + i);
  return len;
}

uint32_t kintsuki_oam_write_range(kintsuki_t* h, uint32_t addr, uint32_t len, const uint8_t* in_) {
  if(!h || !in_) return 0;
  for(uint32_t i = 0; i < len; i++) h->program->oamWrite(addr + i, in_[i]);
  return len;
}
uint8_t kintsuki_cgram_read(kintsuki_t* h, uint32_t addr)            { return h ? h->program->cgramRead(addr) : 0; }
void    kintsuki_cgram_write(kintsuki_t* h, uint32_t addr, uint8_t v){ if(h) h->program->cgramWrite(addr, v); }
uint8_t kintsuki_oam_read(kintsuki_t* h, uint32_t addr)              { return h ? h->program->oamRead(addr)   : 0; }
void    kintsuki_oam_write(kintsuki_t* h, uint32_t addr, uint8_t v)  { if(h) h->program->oamWrite(addr, v); }

uint32_t kintsuki_vram_dump(kintsuki_t* h, uint8_t* out, uint32_t len) {
  if(!h || !out) return 0;
  uint32_t n = len < 0x10000 ? len : 0x10000;
  for(uint32_t i = 0; i < n; i++) out[i] = h->program->vramRead(i);
  return n;
}
uint32_t kintsuki_cgram_dump(kintsuki_t* h, uint8_t* out, uint32_t len) {
  if(!h || !out) return 0;
  uint32_t n = len < 0x200 ? len : 0x200;
  for(uint32_t i = 0; i < n; i++) out[i] = h->program->cgramRead(i);
  return n;
}
uint32_t kintsuki_oam_dump(kintsuki_t* h, uint8_t* out, uint32_t len) {
  if(!h || !out) return 0;
  uint32_t n = len < 0x220 ? len : 0x220;
  for(uint32_t i = 0; i < n; i++) out[i] = h->program->oamRead(i);
  return n;
}

// Struct definitions live in kintsuki.h (typedef'd via the C ABI header).

void kintsuki_get_state(kintsuki_t* h, kintsuki_cpu_state_t* out) {
  if(!h || !out) return;
  CpuState s = h->program->getCpuState();
  out->a = s.a; out->x = s.x; out->y = s.y;
  out->s = s.s; out->d = s.d; out->b = s.b;
  out->p = s.p; out->pc = s.pc; out->e = s.e ? 1 : 0;
  out->stp = s.stp ? 1 : 0;
  out->wai = s.wai ? 1 : 0;
}

void kintsuki_set_state(kintsuki_t* h, const kintsuki_cpu_state_t* in) {
  if(!h || !in) return;
  CpuState s;
  s.a = in->a; s.x = in->x; s.y = in->y;
  s.s = in->s; s.d = in->d; s.b = in->b;
  s.p = in->p; s.pc = in->pc; s.e = in->e != 0;
  // Without these two, the caller cannot un-halt a CPU that previously
  // executed STP/WAI — a fresh-Emu test that calls set_state(stp=0)
  // would still see the inherited libco state's stp/wai flag and
  // run_until_stp / run_frames would early-exit doing nothing. macOS
  // happens to zero these on the heap; Linux ARM doesn't.
  s.stp = in->stp != 0;
  s.wai = in->wai != 0;
  h->program->setCpuState(s);
}

// PPU/DMA state snapshot — types declared in kintsuki.h.

void kintsuki_get_ppu_state(kintsuki_t* h, kintsuki_ppu_state_t* out) {
  if(!h || !out) return;
  std::memset(out, 0, sizeof(*out));

  auto& p = ares::SuperFamicom::ppuPerformanceImpl;
  auto& c = ares::SuperFamicom::cpu;

  // INIDISP ($2100): brightness in low nybble, force-blank in bit 7.
  out->inidisp = (uint8_t)((p.io.displayBrightness & 0x0F) | (p.io.displayDisable ? 0x80 : 0x00));
  // BGMODE ($2105): mode | priority | per-BG tile-size bits.
  out->bgmode  = (uint8_t)((p.io.bgMode & 0x07) | (p.io.bgPriority ? 0x08 : 0)
                          | (p.bg1.io.tileSize ? 0x10 : 0)
                          | (p.bg2.io.tileSize ? 0x20 : 0)
                          | (p.bg3.io.tileSize ? 0x40 : 0)
                          | (p.bg4.io.tileSize ? 0x80 : 0));
  // BGxSC ($2107..$210A): tilemap base in bits 7..2, screenSize in bits 1..0.
  // screenAddress is the tilemap word base (e.g. $7000 → byte $70).
  auto packBGSC = [](uint16_t scrAddr, uint8_t scrSize) -> uint8_t {
    return (uint8_t)((scrAddr >> 8) & 0xFC) | (uint8_t)(scrSize & 0x03);
  };
  out->bg1sc = packBGSC(p.bg1.io.screenAddress, p.bg1.io.screenSize);
  out->bg2sc = packBGSC(p.bg2.io.screenAddress, p.bg2.io.screenSize);
  out->bg3sc = packBGSC(p.bg3.io.screenAddress, p.bg3.io.screenSize);
  out->bg4sc = packBGSC(p.bg4.io.screenAddress, p.bg4.io.screenSize);
  // BG12NBA ($210B): char-data addr / 0x1000 for BG2|BG1.
  out->bg12nba = (uint8_t)(((p.bg1.io.tiledataAddress >> 12) & 0x0F)
                          | (((p.bg2.io.tiledataAddress >> 12) & 0x0F) << 4));
  out->bg34nba = (uint8_t)(((p.bg3.io.tiledataAddress >> 12) & 0x0F)
                          | (((p.bg4.io.tiledataAddress >> 12) & 0x0F) << 4));

  // BGxHOFS / BGxVOFS — full 16-bit shadow ares keeps after the double-write.
  out->bg1hofs = (uint16_t)p.bg1.io.hoffset;
  out->bg1vofs = (uint16_t)p.bg1.io.voffset;
  out->bg2hofs = (uint16_t)p.bg2.io.hoffset;
  out->bg2vofs = (uint16_t)p.bg2.io.voffset;
  out->bg3hofs = (uint16_t)p.bg3.io.hoffset;
  out->bg3vofs = (uint16_t)p.bg3.io.voffset;
  out->bg4hofs = (uint16_t)p.bg4.io.hoffset;
  out->bg4vofs = (uint16_t)p.bg4.io.voffset;

  // M7SEL + M7A..D + M7X/Y — mode-7 transform regs, all in mode7 substate.
  out->m7sel = (uint8_t)((p.mode7.hflip ? 0x01 : 0)
                       | (p.mode7.vflip ? 0x02 : 0)
                       | ((p.mode7.repeat & 0x03) << 6));
  out->m7a = (uint16_t)p.mode7.a;
  out->m7b = (uint16_t)p.mode7.b;
  out->m7c = (uint16_t)p.mode7.c;
  out->m7d = (uint16_t)p.mode7.d;
  out->m7x = (uint16_t)p.mode7.hcenter;
  out->m7y = (uint16_t)p.mode7.vcenter;

  // VMAIN/VMADDR — performance PPU stores increment as size (1/32/128/128),
  // map back to the bit-pattern.
  uint8_t vmainBits = 0;
  switch(p.vram.increment) {
    case 1:   vmainBits = 0; break;
    case 32:  vmainBits = 1; break;
    case 128: vmainBits = 2; break;  // 0b10 and 0b11 both give 128
  }
  out->vmain  = (uint8_t)((vmainBits & 0x03)
                       | ((p.vram.mapping & 0x03) << 2)
                       | (p.vram.mode ? 0x80 : 0));
  out->vmaddr = (uint16_t)p.vram.address;

  out->cgadd  = (uint8_t)p.io.cgramAddress;

  // TM/TS/TMW/TSW reconstructed from per-layer enable bits inside ares.
  auto mkTm = [](bool b1, bool b2, bool b3, bool b4, bool ob) -> uint8_t {
    return (uint8_t)((b1 ? 0x01 : 0) | (b2 ? 0x02 : 0)
                   | (b3 ? 0x04 : 0) | (b4 ? 0x08 : 0)
                   | (ob ? 0x10 : 0));
  };
  out->tm = mkTm(p.bg1.io.aboveEnable, p.bg2.io.aboveEnable,
                 p.bg3.io.aboveEnable, p.bg4.io.aboveEnable,
                 p.obj.io.aboveEnable);
  out->ts = mkTm(p.bg1.io.belowEnable, p.bg2.io.belowEnable,
                 p.bg3.io.belowEnable, p.bg4.io.belowEnable,
                 p.obj.io.belowEnable);
  out->tmw = mkTm(p.bg1.window.aboveEnable, p.bg2.window.aboveEnable,
                  p.bg3.window.aboveEnable, p.bg4.window.aboveEnable,
                  p.obj.window.aboveEnable);
  out->tsw = mkTm(p.bg1.window.belowEnable, p.bg2.window.belowEnable,
                  p.bg3.window.belowEnable, p.bg4.window.belowEnable,
                  p.obj.window.belowEnable);

  out->cgwsel  = (uint8_t)((p.dac.io.directColor ? 0x01 : 0)
                        | (p.dac.io.blendMode ? 0x02 : 0)
                        | ((p.dac.window.belowMask & 0x03) << 4)
                        | ((p.dac.window.aboveMask & 0x03) << 6));
  // CGADDSUB ($2131): performance PPU stores colorEnable as a 7-element
  // n1 array indexed by Source::{BG1,BG2,BG3,BG4,OBJ1,OBJ2,COL}.
  using PerfPPU = ares::SuperFamicom::PPUPerformance;
  out->cgadsub = (uint8_t)((p.dac.io.colorEnable[PerfPPU::Source::BG1]  ? 0x01 : 0)
                        | (p.dac.io.colorEnable[PerfPPU::Source::BG2]  ? 0x02 : 0)
                        | (p.dac.io.colorEnable[PerfPPU::Source::BG3]  ? 0x04 : 0)
                        | (p.dac.io.colorEnable[PerfPPU::Source::BG4]  ? 0x08 : 0)
                        | (p.dac.io.colorEnable[PerfPPU::Source::OBJ2] ? 0x10 : 0)
                        | (p.dac.io.colorEnable[PerfPPU::Source::COL]  ? 0x20 : 0)
                        | (p.dac.io.colorHalve ? 0x40 : 0)
                        | (p.dac.io.colorMode ? 0x80 : 0));
  out->setini = (uint8_t)((p.io.interlace ? 0x01 : 0)
                       | (p.io.overscan ? 0x10 : 0)
                       | (p.io.pseudoHires ? 0x40 : 0)
                       | (p.io.extbg ? 0x80 : 0));

  out->hcounter = (uint16_t)p.io.hcounter;
  out->vcounter = (uint16_t)p.io.vcounter;

  // DMA / HDMA channels
  uint8_t mdmaen = 0, hdmaen = 0;
  for(uint32_t ch = 0; ch < 8; ch++) {
    auto& src = c.dmaChannel(ch);
    auto& dst = out->dma[ch];
    dst.ctrl = (uint8_t)((src.transferMode & 0x07)
                       | (src.fixedTransfer ? 0x08 : 0)
                       | (src.reverseTransfer ? 0x10 : 0)
                       | (src.unused ? 0x20 : 0)
                       | (src.indirect ? 0x40 : 0)
                       | (src.direction ? 0x80 : 0));
    dst.dest      = (uint8_t)src.targetAddress;
    dst.src_addr  = (uint16_t)src.sourceAddress;
    dst.src_bank  = (uint8_t)src.sourceBank;
    dst.ind_count = (uint16_t)src.transferSize;  // union with indirectAddress
    dst.ind_bank  = (uint8_t)src.indirectBank;
    dst.line_count = (uint8_t)src.lineCounter;
    dst.enabled   = (uint8_t)(src.hdmaEnable ? 1 : 0);
    if(src.dmaEnable)  mdmaen |= (uint8_t)(1 << ch);
    if(src.hdmaEnable) hdmaen |= (uint8_t)(1 << ch);
  }
  out->mdmaen = mdmaen;
  out->hdmaen = hdmaen;
}

uint32_t kintsuki_save_state(kintsuki_t* h, void* buf, uint32_t cap) {
  if(!h) return 0;
  auto blob = h->program->saveStateBlob();
  if(buf && cap >= blob.size()) std::memcpy(buf, blob.data(), blob.size());
  return (uint32_t)blob.size();
}

int kintsuki_load_state(kintsuki_t* h, const void* buf, uint32_t len) {
  if(!h || !buf) return 0;
  if(!h->program->loadStateBlob((const uint8_t*)buf, len)) return 0;
  // Live call chain belongs to the pre-load run; the new state is a
  // different point in time, so any future RTS would otherwise pop the
  // stale frame and report bogus callsites.
  g_callstack.clear();
  return 1;
}

const uint32_t* kintsuki_framebuffer(kintsuki_t* h, uint32_t* out_w, uint32_t* out_h) {
  if(!h) return nullptr;
  if(out_w) *out_w = h->program->fbWidth;
  if(out_h) *out_h = h->program->fbHeight;
  return h->program->fb.data();
}

int kintsuki_screenshot(kintsuki_t* h, const char* path) {
  return (h && h->program->writeScreenshot(path)) ? 1 : 0;
}

// 1 when the PPU is in BGMODE 5/6 or pseudo-hires (each emitted column
// is a real pixel), 0 in normal mode (every other column is a dupe).
// Lets Python `framebuffer()` collapse the doubled output the same way
// `kintsuki_screenshot` does so canonical bytes match the canonical PNG.
int kintsuki_ppu_hires(kintsuki_t* h) {
  if(!h) return 0;
  return ares::SuperFamicom::ppuPerformanceImpl.hires() ? 1 : 0;
}

void kintsuki_set_input(kintsuki_t* h, int port, uint16_t mask) {
  if(!h || port < 0 || port > 1) return;
  h->program->inputState[port] = mask;
}

void kintsuki_press(kintsuki_t* h, int port, int button, int pressed) {
  if(!h) return;
  h->program->setButton((unsigned)port, (unsigned)button, pressed != 0);
}

// =============================================================================
// Callbacks (function-pointer style for ctypes/swift interop)
// =============================================================================
typedef void (*kintsuki_cb_t)(uint32_t addr, uint8_t value, void* userdata);

namespace {

struct CCallback {
  uint32_t lo, hi;
  kintsuki_cb_t fn;
  void* userdata;
  bool active;
  bool halt;       // when true, raise kintsukiBailRequested on hit so the
                   // scheduler returns to the host loop at the next safe
                   // boundary — host then pauses the run loop.
};

enum { CB_EXEC = 0, CB_READ = 1, CB_WRITE = 2 };

std::vector<CCallback> g_cExec, g_cRead, g_cWrite;
uint8_t g_cExecPages[65536]  = {};
uint8_t g_cReadPages[65536]  = {};
uint8_t g_cWritePages[65536] = {};

}  // anonymous namespace

static void resetAllCallbacks() {
  g_cExec.clear();
  g_cRead.clear();
  g_cWrite.clear();
  std::memset(g_cExecPages,  0, sizeof(g_cExecPages));
  std::memset(g_cReadPages,  0, sizeof(g_cReadPages));
  std::memset(g_cWritePages, 0, sizeof(g_cWritePages));
}

namespace {

auto markCPages(uint8_t* pages, uint32_t lo, uint32_t hi, int delta) -> void {
  uint32_t lpage = (lo & 0xffffff) >> 8;
  uint32_t hpage = (hi & 0xffffff) >> 8;
  if(hpage > 0xffff) hpage = 0xffff;
  for(uint32_t p = lpage; p <= hpage; p++) {
    int v = (int)pages[p] + delta;
    if(v < 0) v = 0;
    if(v > 255) v = 255;
    pages[p] = (uint8_t)v;
  }
}

auto cFire(std::vector<CCallback>& list, uint32_t addr, uint8_t value) -> void {
  for(auto& cb : list) {
    if(!cb.active) continue;
    if(addr < cb.lo || addr > cb.hi) continue;
    cb.fn(addr, value, cb.userdata);
    // Halting breakpoints raise both flags:
    //   - `kintsukiBailRequested` (one-shot): the CPU's exec hook
    //     yields the scheduler immediately so cpu.r.pc.d still points
    //     at the BP address.
    //   - `kintsukiHaltRequested` (sticky): `Program::runFrames`
    //     breaks out of its outer loop instead of resuming the CPU
    //     coroutine and running past the BP. Cleared explicitly by
    //     the host on resume — see `Emulator.togglePause`.
    if(cb.halt) {
      ares::SuperFamicom::kintsukiBailRequested = true;
      ares::SuperFamicom::kintsukiHaltRequested = true;
    }
  }
}

// Forward to the tracer hook (defined further down) if PC falls in its
// configured range. Inlined into cOnExec so a single execHook supports
// both user callbacks and the tracer.
void tracerOnExec(uint32_t pc);

void cOnExec(uint32_t pc) {
  tracerOnExec(pc);
  if(g_cExecPages[(pc & 0xffffff) >> 8] == 0) return;
  cFire(g_cExec, pc, 0);
}

void cOnRead(uint32_t addr, uint8_t value) {
  if(g_cReadPages[(addr & 0xffffff) >> 8] == 0) return;
  cFire(g_cRead, addr, value);
}

void cOnWrite(uint32_t addr, uint8_t value) {
  if(g_cWritePages[(addr & 0xffffff) >> 8] == 0) return;
  cFire(g_cWrite, addr, value);
}

auto pickList(int kind) -> std::vector<CCallback>* {
  if(kind == CB_EXEC)  return &g_cExec;
  if(kind == CB_READ)  return &g_cRead;
  if(kind == CB_WRITE) return &g_cWrite;
  return nullptr;
}

auto pickPages(int kind) -> uint8_t* {
  if(kind == CB_EXEC)  return g_cExecPages;
  if(kind == CB_READ)  return g_cReadPages;
  if(kind == CB_WRITE) return g_cWritePages;
  return nullptr;
}

}  // namespace

int kintsuki_add_callback_ex(kintsuki_t* h, int kind, uint32_t lo, uint32_t hi,
                             int halt,
                             kintsuki_cb_t fn, void* userdata);

int kintsuki_add_callback(kintsuki_t* h, int kind, uint32_t lo, uint32_t hi,
                          kintsuki_cb_t fn, void* userdata) {
  return kintsuki_add_callback_ex(h, kind, lo, hi, 0, fn, userdata);
}

int kintsuki_add_callback_ex(kintsuki_t* h, int kind, uint32_t lo, uint32_t hi,
                             int halt,
                             kintsuki_cb_t fn, void* userdata) {
  (void)h;
  auto* list = pickList(kind);
  auto* pages = pickPages(kind);
  if(!list || !pages || !fn) return 0;
  list->push_back({lo, hi, fn, userdata, true, halt != 0});
  markCPages(pages, lo, hi, +1);
  if(kind == CB_EXEC)  ares::SuperFamicom::execHook      = &cOnExec;
  if(kind == CB_READ)  ares::SuperFamicom::memReadHook   = &cOnRead;
  if(kind == CB_WRITE) ares::SuperFamicom::memWriteHook  = &cOnWrite;
  return (int)list->size();
}

void kintsuki_remove_callback(kintsuki_t* h, int kind, int id) {
  (void)h;
  auto* list = pickList(kind);
  auto* pages = pickPages(kind);
  if(!list || !pages) return;
  if(id < 1 || (size_t)id > list->size()) return;
  auto& cb = (*list)[id - 1];
  if(cb.active) {
    markCPages(pages, cb.lo, cb.hi, -1);
    cb.active = false;
  }
  bool any = false;
  for(auto& c : *list) if(c.active) { any = true; break; }
  if(!any) {
    if(kind == CB_EXEC)  ares::SuperFamicom::execHook = nullptr;
    if(kind == CB_READ)  ares::SuperFamicom::memReadHook = nullptr;
    if(kind == CB_WRITE) ares::SuperFamicom::memWriteHook = nullptr;
  }
}

// ---- Formatted execution tracer ------------------------------------------
// Single tracer per emulator instance. Hooked from cOnExec via tracerOnExec.
namespace {
struct TraceRange {
  uint32_t start;  // 24-bit
  uint32_t size;   // bytes; PC ∈ [start, start + size)
};
struct Tracer {
  bool      active = false;
  uint32_t  lo = 0, hi = 0;
  bool      file_mode = false;
  FILE*     fp = nullptr;
  // Optional fine-grained PC mask. When non-empty, takes precedence
  // over [lo,hi]: a PC must fall inside one of the ranges for the line
  // to fire. Caller-side resolution (typically symbol_name + size via
  // .adbg) is the easy way to scope a trace to one routine.
  std::vector<TraceRange> ranges;
  // Ring buffer (RING mode): bounded byte buffer, oldest evicted on append.
  std::vector<char> ring;
  uint32_t  ring_cap = 0;
  uint32_t  ring_head = 0;  // next write position
  uint32_t  ring_size = 0;  // bytes currently in the ring
};
Tracer g_tracer;


auto tracerAppendBytes(const char* s, uint32_t n) -> void {
  if(g_tracer.file_mode) {
    if(g_tracer.fp) std::fwrite(s, 1, n, g_tracer.fp);
    return;
  }
  if(g_tracer.ring_cap == 0) return;
  // If the new chunk alone exceeds capacity, only keep the trailing tail.
  if(n >= g_tracer.ring_cap) {
    s += (n - g_tracer.ring_cap);
    n  = g_tracer.ring_cap;
    g_tracer.ring_size = 0;
    g_tracer.ring_head = 0;
  }
  // Free space we'd lose by writing n more bytes.
  if(g_tracer.ring_size + n > g_tracer.ring_cap) {
    uint32_t overflow = (g_tracer.ring_size + n) - g_tracer.ring_cap;
    g_tracer.ring_size -= overflow;
    // Note: head/size sliding works because we never read from the
    // dropped region; drain copies via mod arithmetic.
  }
  for(uint32_t i = 0; i < n; i++) {
    g_tracer.ring[g_tracer.ring_head] = s[i];
    g_tracer.ring_head = (g_tracer.ring_head + 1) % g_tracer.ring_cap;
    if(g_tracer.ring_size < g_tracer.ring_cap) g_tracer.ring_size++;
  }
}
}  // namespace

// Resolve the static branch/call target for control-flow opcodes. Returns
// 0xFFFFFFFF for non-control-flow or operand-indirect ops we can't statically
// resolve (e.g. JMP (addr,X), JSR (X)).
auto resolveControlFlowTarget(uint32_t pc) -> uint32_t {
  auto& cpu = ares::SuperFamicom::cpu;
  auto rd = [&](uint32_t a) -> uint8_t { return cpu.readDisassembler(a & 0xFFFFFF); };
  uint8_t op = rd(pc);
  uint32_t bank = pc & 0xFF0000;
  switch(op) {
    case 0x20:   // JSR abs
    case 0x4C: { // JMP abs
      uint32_t lo = rd(pc + 1), hi = rd(pc + 2);
      return bank | ((hi << 8) | lo);
    }
    case 0x22:   // JSL abs long
    case 0x5C: { // JMP abs long ("jml")
      uint32_t lo = rd(pc + 1), hi = rd(pc + 2), bk = rd(pc + 3);
      return ((bk << 16) | (hi << 8) | lo) & 0xFFFFFF;
    }
    case 0x10: case 0x30: case 0x50: case 0x70:  // BPL/BMI/BVC/BVS
    case 0x80: case 0x90: case 0xB0:             // BRA/BCC/BCS
    case 0xD0: case 0xF0: {                      // BNE/BEQ
      int8_t off = (int8_t)rd(pc + 1);
      uint16_t after = (uint16_t)((pc + 2) & 0xFFFF);
      return bank | (uint16_t)(after + off);
    }
    case 0x82: { // BRL (long branch)
      uint32_t lo = rd(pc + 1), hi = rd(pc + 2);
      int16_t off = (int16_t)((hi << 8) | lo);
      uint16_t after = (uint16_t)((pc + 3) & 0xFFFF);
      return bank | (uint16_t)(after + off);
    }
    default:
      return 0xFFFFFFFFu;
  }
}

void tracerOnExec(uint32_t pc) {
  if(!g_tracer.active) return;
  // Range-list mask takes precedence over [lo,hi] when populated. Linear
  // scan is fine: typical workloads pass <10 ranges, and short-circuit
  // exits as soon as a hit is found.
  if(!g_tracer.ranges.empty()) {
    bool inside = false;
    for(const auto& r : g_tracer.ranges) {
      if(pc >= r.start && pc < r.start + r.size) { inside = true; break; }
    }
    if(!inside) return;
  } else if(pc < g_tracer.lo || pc > g_tracer.hi) {
    return;
  }

  // .adbg label header. Emitted only when the current PC sits at a known
  // label and that label differs from the last one we annotated, so a
  // tight loop at the same label doesn't drown the trace in headers.
  if(const char* name = g_labels.lookup(pc)) {
    if(name != g_tracer_last_label) {
      char hdr[256];
      int hn = std::snprintf(hdr, sizeof(hdr), "; --- %s ---\n", name);
      if(hn > 0) tracerAppendBytes(hdr, (uint32_t)hn);
      g_tracer_last_label = name;
    }
  } else {
    g_tracer_last_label = nullptr;
  }

  // ares::WDC65816 helpers: disassembleInstruction() returns the formatted
  // operand line for the current PC (already padded). disassembleContext()
  // returns the register dump (A:.. X:.. Y:.. ...). Combine on one line
  // separated by ';' so each entry is greppable.
  auto& cpu = ares::SuperFamicom::cpu;
  nall::string ins = cpu.disassembleInstruction();
  nall::string ctx = cpu.disassembleContext({});
  // Prefix the line with the executing PC so the bank stands out — when
  // PC goes wild we land in bank $05/etc and PB is the only signal we
  // left expected territory.
  char pcbuf[12];
  std::snprintf(pcbuf, sizeof(pcbuf), "%02X:%04X ",
                (pc >> 16) & 0xFF, pc & 0xFFFF);
  // Operand symbolication for JSR/JSL/JMP/Bxx: when the opcode at PC is a
  // control-flow op AND its static target resolves to a known label, append
  // ` → <name>` so the trace reads as an annotated control-flow log without
  // any post-processing. Indirect/indexed jumps are skipped — their target
  // depends on register values we'd need a full simulator to track.
  char arrow[96]; arrow[0] = 0;
  if(g_labels.byAddr.size() > 0) {
    uint32_t tgt = resolveControlFlowTarget(pc);
    if(tgt != 0xFFFFFFFFu) {
      if(const char* n = g_labels.lookup(tgt)) {
        std::snprintf(arrow, sizeof(arrow), " -> %s", n);
      }
    }
  }
  nall::string line = nall::string(pcbuf, ins, "  ; ", ctx, arrow, "\n");
  tracerAppendBytes((const char*)line.data(), (uint32_t)line.size());
}

void kintsuki_tracer_start(kintsuki_t* h, uint32_t lo, uint32_t hi,
                           kintsuki_trace_mode_t mode, const char* path,
                           uint32_t ring_capacity) {
  if(!h) return;
  // Stop any prior tracer first to keep a clean single-tracer model.
  kintsuki_tracer_stop(h);

  g_tracer.lo = lo;
  g_tracer.hi = hi;
  g_tracer.file_mode = (mode == KINTSUKI_TRACE_FILE);
  if(g_tracer.file_mode) {
    g_tracer.fp = path ? std::fopen(path, "wb") : nullptr;
    g_tracer.ring.clear();
    g_tracer.ring_cap = 0;
  } else {
    if(ring_capacity == 0) ring_capacity = 4096;
    g_tracer.ring.assign(ring_capacity, 0);
    g_tracer.ring_cap  = ring_capacity;
    g_tracer.ring_head = 0;
    g_tracer.ring_size = 0;
    g_tracer.fp = nullptr;
  }
  g_tracer.active = true;
  // Make sure the global execHook is wired (cOnExec dispatches to us).
  if(!ares::SuperFamicom::execHook) ares::SuperFamicom::execHook = &cOnExec;
}

void kintsuki_tracer_stop(kintsuki_t* h) {
  (void)h;
  if(g_tracer.fp) { std::fclose(g_tracer.fp); g_tracer.fp = nullptr; }
  g_tracer.active = false;
  g_tracer.ring.clear();
  g_tracer.ring_cap  = 0;
  g_tracer.ring_head = 0;
  g_tracer.ring_size = 0;
}

uint32_t kintsuki_tracer_drain(kintsuki_t* h, char* out, uint32_t cap) {
  (void)h;
  if(g_tracer.file_mode) return 0;
  if(!out || cap == 0)   return g_tracer.ring_size;
  uint32_t n = g_tracer.ring_size < cap ? g_tracer.ring_size : cap;
  // Oldest byte sits `ring_size` slots behind head (mod cap).
  uint32_t start = (g_tracer.ring_head + g_tracer.ring_cap - g_tracer.ring_size)
                   % g_tracer.ring_cap;
  for(uint32_t i = 0; i < n; i++) {
    out[i] = g_tracer.ring[(start + i) % g_tracer.ring_cap];
  }
  g_tracer.ring_head = 0;
  g_tracer.ring_size = 0;
  return n;
}

// Best-effort single-instruction step: arms execHook for one fire and
// runs the emulator until it returns to host (currently advances by one
// CPU exec slice, refined later when we expose a scheduler yield).
namespace {
volatile bool g_stepHit = false;
ares::SuperFamicom::ExecHook g_prevExecHook = nullptr;

// Step semantics: advance the CPU exactly one user-visible instruction.
// execHook fires immediately before each instruction dispatch.
//
// Two cases:
// 1. Stepping from a vanilla pause: the coroutine is between main()
//    iterations. First execHook fire is the instruction the user wants
//    to step over — let it run; bail on the second fire (next instr).
// 2. Stepping from a bail-yielded halt (BP, prior step): the coroutine
//    is suspended INSIDE main(), just past the bail check, with PC
//    pointing at the about-to-execute instruction. Resuming runs that
//    instruction as a side-effect of unwinding, before any new
//    execHook fires. Count THAT as the user's step and bail on the
//    very first fire so we don't accidentally step two instructions.
volatile bool g_stepFromHalt = false;

void stepHook(uint32_t pc) {
  (void)pc;
  if(g_stepFromHalt) {
    ares::SuperFamicom::kintsukiBailRequested = true;
    return;
  }
  if(g_stepHit) {
    ares::SuperFamicom::kintsukiBailRequested = true;
    return;
  }
  g_stepHit = true;
}
}  // namespace

void kintsuki_step(kintsuki_t* h) {
  if(!h) return;
  g_prevExecHook = ares::SuperFamicom::execHook;
  ares::SuperFamicom::execHook = &stepHook;
  g_stepHit = false;
  // Detect "resuming from halt" so stepHook can compensate for the
  // free instruction the coroutine unwinds before it returns to main().
  g_stepFromHalt = ares::SuperFamicom::kintsukiHaltRequested;
  ares::SuperFamicom::kintsukiHaltRequested = false;
  ares::SuperFamicom::kintsukiBailRequested = false;
  ares::SuperFamicom::system.run();
  ares::SuperFamicom::execHook = g_prevExecHook;
  ares::SuperFamicom::kintsukiBailRequested = false;
  g_stepFromHalt = false;
}


namespace {
volatile uint32_t g_runUntilTarget = 0;
volatile bool g_runUntilHit = false;
ares::SuperFamicom::ExecHook g_savedHook = nullptr;

void runUntilHook(uint32_t pc) {
  if(g_savedHook) g_savedHook(pc);
  if(pc == g_runUntilTarget) {
    g_runUntilHit = true;
    ares::SuperFamicom::kintsukiBailRequested = true;
  }
}
}  // namespace

void kintsuki_rearm_cpu(kintsuki_t* h) {
  if(!h) return;
  // Rebuild the CPU's libco coroutine without doing a full system reset
  // (which would re-randomize WRAM and re-run the boot vector). The
  // coroutine's host-side stack is replaced by a fresh one; the next
  // scheduler entry calls CPU::main from the top with a clean stack.
  ares::SuperFamicom::cpu.create(
    ares::SuperFamicom::system.cpuFrequency(),
    std::bind_front(&ares::SuperFamicom::CPU::main,
                    &ares::SuperFamicom::cpu));
  // Clear the halt flags + pending interrupts on the WDC65816 register
  // file so the next instruction dispatch runs at the PC the test sets.
  ares::SuperFamicom::cpu.r.stp = false;
  ares::SuperFamicom::cpu.r.wai = false;
  ares::SuperFamicom::cpu.clearPendingInterrupts();
  // Same reasoning as load_state: the rebuilt coroutine starts from
  // scratch; any frames left over describe a call chain that no longer
  // exists in the now-discarded host stack.
  g_callstack.clear();
}

int kintsuki_run_until(kintsuki_t* h, uint32_t target_pc, uint32_t max_frames) {
  if(!h) return 0;
  g_runUntilTarget = target_pc & 0xffffff;
  g_runUntilHit = false;
  g_savedHook = ares::SuperFamicom::execHook;
  ares::SuperFamicom::execHook = &runUntilHook;
  uint64_t startFrames = h->program->framesRendered;
  while(!g_runUntilHit
        && h->program->framesRendered < startFrames + max_frames) {
    ares::SuperFamicom::system.run();
  }
  ares::SuperFamicom::execHook = g_savedHook;
  g_savedHook = nullptr;
  ares::SuperFamicom::kintsukiBailRequested = false;
  return g_runUntilHit ? 1 : 0;
}

// ---- Shadow callstack + .adbg C ABI -------------------------------------

uint32_t kintsuki_callstack_snapshot(kintsuki_t* h,
                                     kintsuki_call_frame_t* out,
                                     uint32_t cap) {
  if(!h || !out || cap == 0) return 0;
  uint32_t depth = (uint32_t)g_callstack.size();
  uint32_t n = depth < cap ? depth : cap;
  // Caller wants deepest frame first → last pushed = top of `out`.
  // g_callstack is FIFO with newest at back, so emit from front.
  for(uint32_t i = 0; i < n; i++) out[i] = g_callstack[i];
  return n;
}

void kintsuki_callstack_clear(kintsuki_t* h) {
  if(!h) return;
  g_callstack.clear();
}

int kintsuki_load_adbg(kintsuki_t* h, const char* path) {
  if(!h || !path) return 0;
  // Reset the tracer's last-emitted-label memo since string pointers are
  // about to be invalidated by the AdbgLabels::clear() inside load().
  g_tracer_last_label = nullptr;
  return g_labels.load(path) ? 1 : 0;
}

void kintsuki_clear_adbg(kintsuki_t* h) {
  if(!h) return;
  g_labels.clear();
  g_tracer_last_label = nullptr;
}

const char* kintsuki_lookup_label(kintsuki_t* h, uint32_t addr) {
  if(!h) return nullptr;
  return g_labels.lookup(addr);
}

const char* kintsuki_lookup_label_containing(kintsuki_t* h, uint32_t addr,
                                             uint32_t* out_offset) {
  if(!h) return nullptr;
  uint32_t offset = 0;
  const char* name = g_labels.lookupContaining(addr, offset);
  if(name && out_offset) *out_offset = offset;
  return name;
}

int kintsuki_lookup_symbol_addr(kintsuki_t* h, const char* name,
                                uint32_t* out_addr) {
  if(!h || !name) return 0;
  uint32_t addr = 0;
  if(!g_labels.lookupAddress(name, addr)) return 0;
  if(out_addr) *out_addr = addr;
  return 1;
}

void kintsuki_tracer_set_ranges(kintsuki_t* h,
                                const kintsuki_trace_range_t* ranges,
                                uint32_t count) {
  if(!h) return;
  g_tracer.ranges.clear();
  if(!ranges || count == 0) return;
  g_tracer.ranges.reserve(count);
  for(uint32_t i = 0; i < count; i++) {
    if(ranges[i].size == 0) continue;
    g_tracer.ranges.push_back({ranges[i].start & 0xFFFFFFu, ranges[i].size});
  }
}

int kintsuki_lookup_source(kintsuki_t* h, uint32_t addr,
                           const char** out_file,
                           uint32_t* out_line,
                           uint16_t* out_column) {
  if(!h) return 0;
  const char* file = nullptr;
  uint32_t line = 0;
  uint16_t column = 0;
  if(!g_labels.lookupSource(addr, file, line, column)) return 0;
  if(out_file)   *out_file   = file;
  if(out_line)   *out_line   = line;
  if(out_column) *out_column = column;
  return 1;
}

// ---- DMA transfer log ---------------------------------------------------
// Captures each Channel::dmaRun call, deduplicating by (src, dst, size)
// so a game that re-pushes the same buffer every frame collapses to a
// single entry. Recent-first ordering: when an existing entry is hit
// again we move it to slot 0 and bump its hit count, otherwise we
// insert at slot 0 and evict the oldest. Bounded to 64 entries.
namespace {
struct DmaLogEntry {
  uint32_t src_addr;     // 24-bit
  uint16_t size;
  uint8_t  channel;
  uint8_t  direction;
  uint8_t  mode;
  uint8_t  dst_reg;
  uint16_t vram_addr;    // VMADDR at DMA fire (word address)
  uint32_t hits;
  uint64_t last_frame;
};
constexpr size_t kDmaLogCap = 64;
DmaLogEntry g_dmaLog[kDmaLogCap] = {};
size_t g_dmaLogSize = 0;

void dmaHookFn(uint8_t channel, uint8_t direction, uint8_t mode,
               uint32_t src, uint8_t dst, uint16_t size) {
  // Capture VMADDR (word) at the moment the DMA fires — gives the
  // user the actual VRAM destination, not just "we wrote something
  // through VMDATA". Read from the live performance PPU; the
  // CGRAM/OAM equivalents could be added later if needed.
  uint16_t vramAddr = (uint16_t)ares::SuperFamicom::ppuPerformanceImpl.vram.address;
  // Dedupe key now includes vram_addr so two transfers to different
  // VRAM regions through the same VMDATA register don't collapse.
  for(size_t i = 0; i < g_dmaLogSize; i++) {
    auto& e = g_dmaLog[i];
    if(e.src_addr == src && e.dst_reg == dst && e.size == size
       && e.vram_addr == vramAddr) {
      e.hits += 1;
      e.last_frame = (g_handle ? g_handle->program->framesRendered : 0);
      if(i > 0) {
        DmaLogEntry tmp = e;
        for(size_t j = i; j > 0; j--) g_dmaLog[j] = g_dmaLog[j - 1];
        g_dmaLog[0] = tmp;
      }
      return;
    }
  }
  size_t insertCount = (g_dmaLogSize < kDmaLogCap) ? g_dmaLogSize : kDmaLogCap - 1;
  for(size_t j = insertCount; j > 0; j--) g_dmaLog[j] = g_dmaLog[j - 1];
  g_dmaLog[0] = DmaLogEntry{
    .src_addr = src,
    .size = size,
    .channel = channel,
    .direction = direction,
    .mode = mode,
    .dst_reg = dst,
    .vram_addr = vramAddr,
    .hits = 1,
    .last_frame = (g_handle ? g_handle->program->framesRendered : 0),
  };
  if(g_dmaLogSize < kDmaLogCap) g_dmaLogSize++;
}

struct DmaHookInstaller {
  DmaHookInstaller() { ares::SuperFamicom::kintsukiDmaHook = &dmaHookFn; }
} g_dmaHookInstaller;
}

uint32_t kintsuki_dma_log_count(kintsuki_t* h) {
  if(!h) return 0;
  return (uint32_t)g_dmaLogSize;
}

uint32_t kintsuki_dma_log_snapshot(kintsuki_t* h,
                                   kintsuki_dma_event_t* out,
                                   uint32_t cap) {
  if(!h || !out || cap == 0) return 0;
  uint32_t n = (uint32_t)((g_dmaLogSize < cap) ? g_dmaLogSize : cap);
  for(uint32_t i = 0; i < n; i++) {
    auto& e = g_dmaLog[i];
    out[i].src_addr = e.src_addr;
    out[i].size = e.size;
    out[i].channel = e.channel;
    out[i].direction = e.direction;
    out[i].mode = e.mode;
    out[i].dst_reg = e.dst_reg;
    out[i].vram_addr = e.vram_addr;
    out[i].hits = e.hits;
    out[i].last_frame = e.last_frame;
  }
  return n;
}

void kintsuki_dma_log_clear(kintsuki_t* h) {
  if(!h) return;
  g_dmaLogSize = 0;
}

// ---- Label enumeration --------------------------------------------------

uint32_t kintsuki_label_count(kintsuki_t* h) {
  if(!h) return 0;
  return (uint32_t)g_labels.sortedLabels.size();
}

uint32_t kintsuki_label_snapshot(kintsuki_t* h,
                                 kintsuki_label_entry_t* out,
                                 uint32_t cap) {
  if(!h || !out || cap == 0) return 0;
  uint32_t total = (uint32_t)g_labels.sortedLabels.size();
  uint32_t n = total < cap ? total : cap;
  for(uint32_t i = 0; i < n; i++) {
    const auto& kv = g_labels.sortedLabels[i];
    out[i].addr = kv.first;
    out[i].name = kv.second.c_str();
  }
  return n;
}

// ---- Disassemble-at -----------------------------------------------------
// Length lookup for WDC65816 opcodes. Each entry encodes (base length |
// flags). Base length is the low 4 bits (1..4). Flag bit 4 = +1 if M=0
// (16-bit accumulator immediate). Flag bit 5 = +1 if X=0 (16-bit index
// immediate). M-extending opcodes: ORA/AND/EOR/ADC/BIT/LDA/CMP/SBC #imm
// (09,29,49,69,89,A9,C9,E9). X-extending: LDY/LDX/CPY/CPX #imm
// (A0,A2,C0,E0). Order matches the 65816 opcode matrix.
namespace {
constexpr uint8_t LEN_M = 0x10;
constexpr uint8_t LEN_X = 0x20;

const uint8_t kInstLen[256] = {
  /* 00 */ 2, 2, 2, 2, 2, 2, 2, 2, 1, 2|LEN_M, 1, 1, 3, 3, 3, 4,
  /* 10 */ 2, 2, 2, 2, 2, 2, 2, 2, 1, 3, 1, 1, 3, 3, 3, 4,
  /* 20 */ 3, 2, 4, 2, 2, 2, 2, 2, 1, 2|LEN_M, 1, 1, 3, 3, 3, 4,
  /* 30 */ 2, 2, 2, 2, 2, 2, 2, 2, 1, 3, 1, 1, 3, 3, 3, 4,
  /* 40 */ 1, 2, 2, 2, 3, 2, 2, 2, 1, 2|LEN_M, 1, 1, 3, 3, 3, 4,
  /* 50 */ 2, 2, 2, 2, 3, 2, 2, 2, 1, 3, 1, 1, 4, 3, 3, 4,
  /* 60 */ 1, 2, 3, 2, 2, 2, 2, 2, 1, 2|LEN_M, 1, 1, 3, 3, 3, 4,
  /* 70 */ 2, 2, 2, 2, 2, 2, 2, 2, 1, 3, 1, 1, 3, 3, 3, 4,
  /* 80 */ 2, 2, 3, 2, 2, 2, 2, 2, 1, 2|LEN_M, 1, 1, 3, 3, 3, 4,
  /* 90 */ 2, 2, 2, 2, 2, 2, 2, 2, 1, 3, 1, 1, 3, 3, 3, 4,
  /* A0 */ 2|LEN_X, 2, 2|LEN_X, 2, 2, 2, 2, 2, 1, 2|LEN_M, 1, 1, 3, 3, 3, 4,
  /* B0 */ 2, 2, 2, 2, 2, 2, 2, 2, 1, 3, 1, 1, 3, 3, 3, 4,
  /* C0 */ 2|LEN_X, 2, 2, 2, 2, 2, 2, 2, 1, 2|LEN_M, 1, 1, 3, 3, 3, 4,
  /* D0 */ 2, 2, 2, 2, 2, 2, 2, 2, 1, 3, 1, 1, 3, 3, 3, 4,
  /* E0 */ 2|LEN_X, 2, 2, 2, 2, 2, 2, 2, 1, 2|LEN_M, 1, 1, 3, 3, 3, 4,
  /* F0 */ 2, 2, 2, 2, 3, 2, 2, 2, 1, 3, 1, 1, 3, 3, 3, 4,
};

uint8_t inst_length_for(uint8_t opcode, bool m_flag, bool x_flag) {
  uint8_t e = kInstLen[opcode];
  uint8_t len = e & 0x0F;
  if((e & LEN_M) && !m_flag) len += 1;
  if((e & LEN_X) && !x_flag) len += 1;
  return len;
}
}  // namespace

uint32_t kintsuki_disassemble_at_ex(kintsuki_t* h, uint32_t pc, uint32_t count,
                                    int e_override, int m_override, int x_override,
                                    kintsuki_disasm_line_t* out);

uint32_t kintsuki_disassemble_at(kintsuki_t* h, uint32_t pc, uint32_t count,
                                 kintsuki_disasm_line_t* out) {
  return kintsuki_disassemble_at_ex(h, pc, count, -1, -1, -1, out);
}

uint32_t kintsuki_disassemble_at_ex(kintsuki_t* h, uint32_t pc, uint32_t count,
                                    int e_override, int m_override, int x_override,
                                    kintsuki_disasm_line_t* out) {
  if(!h || !out || count == 0) return 0;
  auto& cpu = ares::SuperFamicom::cpu;
  bool e = e_override < 0 ? cpu.r.e   : (e_override != 0);
  bool m = m_override < 0 ? cpu.r.p.m : (m_override != 0);
  bool x = x_override < 0 ? cpu.r.p.x : (x_override != 0);
  uint32_t addr = pc & 0xFFFFFF;
  uint32_t produced = 0;
  for(uint32_t i = 0; i < count; i++) {
    out[i].pc = addr;
    nall::string s = cpu.disassembleInstruction(addr, e, m, x);
    const char* sp = (const char*)s.data();
    size_t sl = s.size();
    if(sl >= sizeof(out[i].text)) sl = sizeof(out[i].text) - 1;
    std::memcpy(out[i].text, sp, sl);
    out[i].text[sl] = 0;
    // Trim trailing whitespace ares pads to column 31.
    while(sl > 0 && (out[i].text[sl-1] == ' ' || out[i].text[sl-1] == '\t')) {
      out[i].text[--sl] = 0;
    }
    uint8_t opcode = ares::SuperFamicom::cpu.readDisassembler(addr);
    uint8_t len = inst_length_for(opcode, m, x);
    out[i].length = len;
    // Resolve the static control-flow target (JSR/JSL/JMP/Bxx/BRL).
    // Indirect/indexed jumps return 0xFFFFFFFF — propagate that as the
    // sentinel so the UI can disable double-click-to-follow there.
    uint32_t tgt = resolveControlFlowTarget(addr);
    out[i].target = tgt;
    if(tgt != 0xFFFFFFFFu && g_labels.byAddr.size() > 0) {
      if(const char* name = g_labels.lookup(tgt)) {
        // Append " -> name" — same annotation the tracer emits, lets
        // the disassembly view read as a control-flow log.
        size_t avail = sizeof(out[i].text) - sl - 1;
        if(avail > 6) {
          int wrote = std::snprintf(out[i].text + sl, avail, " -> %s", name);
          if(wrote > 0) sl += (size_t)wrote;
        }
      }
    }
    produced++;
    // REP/SEP track M/X flag flips so subsequent disassembly stays accurate
    // across `rep #$30` boundaries — the live table assumes flags don't
    // change, but the user typically wants to see ~20 instructions ahead.
    if(opcode == 0xC2 || opcode == 0xE2) {
      uint8_t imm = ares::SuperFamicom::cpu.readDisassembler((addr + 1) & 0xFFFFFF);
      if(opcode == 0xC2) {
        if(imm & 0x20) m = false;
        if(imm & 0x10) x = false;
      } else {
        if(imm & 0x20) m = true;
        if(imm & 0x10) x = true;
      }
    }
    // Advance PC. SNES wraps in-bank for instructions; we follow that.
    addr = (addr & 0xFF0000) | ((addr + len) & 0xFFFF);
  }
  return produced;
}

}  // extern "C"
