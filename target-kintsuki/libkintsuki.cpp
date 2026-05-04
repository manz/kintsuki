// kintsuki C ABI shim. extern "C" wrappers around Program for use by
// ctypes/Swift hosts. No Lua dependency.
//
// Single-instance: ares uses globals (cpu, ppu, bus); only one kintsuki_t
// may exist at a time.

#include "program.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

// kintsuki test-harness bail flag: defined in ares/sfc/system/system.cpp,
// read+cleared from cpu.cpp before each instruction. Declared here at
// file scope (outside extern "C") so the C++ name mangling matches.
namespace ares::SuperFamicom {
  extern volatile bool kintsukiBailRequested;
}

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
  delete h;
  g_handle = nullptr;
  kintsukiProgram = nullptr;
}

int kintsuki_load_rom(kintsuki_t* h, const char* path) {
  if(!h) return 0;
  if(!h->program->loadRom(path)) return 0;
  if(!h->program->bootRom()) return 0;
  return 1;
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

uint8_t kintsuki_vram_read(kintsuki_t* h, uint32_t addr)             { return h ? h->program->vramRead(addr)  : 0; }
void    kintsuki_vram_write(kintsuki_t* h, uint32_t addr, uint8_t v) { if(h) h->program->vramWrite(addr, v); }
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

struct kintsuki_cpu_state_t {
  uint16_t a, x, y, s, d;
  uint8_t  b, p;
  uint32_t pc;
  uint8_t  e;
  uint8_t  stp;
  uint8_t  wai;
};

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

// PPU/DMA state snapshot. Reads ares globals directly to expose registers
// that are write-only on the CPU bus. Performance PPU implementation is
// active (Program::Program calls setAccurate(false)).
struct kintsuki_dma_channel_t {
  uint8_t  ctrl;
  uint8_t  dest;
  uint16_t src_addr;
  uint8_t  src_bank;
  uint16_t ind_count;
  uint8_t  ind_bank;
  uint8_t  line_count;
  uint8_t  enabled;
};

struct kintsuki_ppu_state_t {
  uint8_t  inidisp;
  uint8_t  bgmode;
  uint8_t  mosaic;
  uint8_t  bg1sc, bg2sc, bg3sc, bg4sc;
  uint8_t  bg12nba, bg34nba;
  uint16_t bg1hofs, bg1vofs, bg2hofs, bg2vofs;
  uint16_t bg3hofs, bg3vofs, bg4hofs, bg4vofs;
  uint8_t  vmain;
  uint16_t vmaddr;
  uint8_t  m7sel;
  uint16_t m7a, m7b, m7c, m7d, m7x, m7y;
  uint8_t  cgadd;
  uint8_t  tm, ts, tmw, tsw;
  uint8_t  cgwsel, cgadsub;
  uint8_t  setini;
  uint16_t hcounter, vcounter;
  kintsuki_dma_channel_t dma[8];
  uint8_t  mdmaen, hdmaen;
};

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
  return h->program->loadStateBlob((const uint8_t*)buf, len) ? 1 : 0;
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
  }
}

void cOnExec(uint32_t pc) {
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

int kintsuki_add_callback(kintsuki_t* h, int kind, uint32_t lo, uint32_t hi,
                          kintsuki_cb_t fn, void* userdata) {
  (void)h;
  auto* list = pickList(kind);
  auto* pages = pickPages(kind);
  if(!list || !pages || !fn) return 0;
  list->push_back({lo, hi, fn, userdata, true});
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

// Best-effort single-instruction step: arms execHook for one fire and
// runs the emulator until it returns to host (currently advances by one
// CPU exec slice, refined later when we expose a scheduler yield).
namespace {
volatile bool g_stepHit = false;
ares::SuperFamicom::ExecHook g_prevExecHook = nullptr;

void stepHook(uint32_t pc) {
  (void)pc;
  g_stepHit = true;
}
}  // namespace

void kintsuki_step(kintsuki_t* h) {
  if(!h) return;
  g_prevExecHook = ares::SuperFamicom::execHook;
  ares::SuperFamicom::execHook = &stepHook;
  g_stepHit = false;
  ares::SuperFamicom::system.run();
  ares::SuperFamicom::execHook = g_prevExecHook;
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

}  // extern "C"
