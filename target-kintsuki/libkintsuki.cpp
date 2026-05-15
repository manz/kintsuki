// kintsuki C ABI shim. extern "C" wrappers around Program for use by
// ctypes/Swift hosts. No Lua dependency.
//
// Single-instance: ares uses globals (cpu, ppu, bus); only one kintsuki_t
// may exist at a time.

#include "program.hpp"
#include "kintsuki.h"
#include "adbg.hpp"
#include "project.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <deque>
#include <unordered_map>

// kintsuki test-harness bail flag: defined in ares/sfc/system/system.cpp,
// read+cleared from cpu.cpp before each instruction. Declared here at
// file scope (outside extern "C") so the C++ name mangling matches.
namespace ares::SuperFamicom {
  extern volatile bool kintsukiBailRequested;
  extern volatile bool kintsukiHaltRequested;
  typedef void (*KintsukiDmaHook)(uint8_t, uint8_t, uint8_t,
                                  uint32_t, uint8_t, uint16_t);
  extern KintsukiDmaHook kintsukiDmaHook;
  typedef void (*KintsukiHdmaHook)(uint8_t, uint16_t, uint8_t);
  extern KintsukiHdmaHook kintsukiHdmaHook;
}

// ---- Shadow callstack + .adbg label table -------------------------------
// File-scope (C++ linkage) so they can be referenced from both the C ABI
// wrappers and the in-file anonymous-namespace tracer code below.
namespace {
constexpr size_t kCallstackCap = 256;
std::deque<kintsuki_call_frame_t> g_callstack;
kintsuki::AdbgLabels g_labels;
// Project file (slice 1): persistent reversing state. Declared up here so
// kintsuki_destroy (file-order above the body where g_project is used)
// can reset it. Hooks fire only when non-null — single null-check on the
// hot path.
std::unique_ptr<kintsuki::Project> g_project;
// Last PC seen by the exec hook. Used by cOnReturn to recover the RTS/
// RTL opcode address — ares' returnHook fires after PC has been moved
// to the return target, so the exit PC is unrecoverable from cpu.r.pc
// alone. Sampled in cOnExec; falls back to 0 when no exec hook fired
// recently.
uint32_t g_lastExecPc = 0;

// Forward decl — defined further down in this TU's anon-namespace.
// Both blocks share linkage so this resolves to the same symbol.
uint8_t inst_length_for(uint8_t opcode, bool m_flag, bool x_flag);
// Autosave (slice 5): when non-zero, kintsuki_run_frames flushes the
// project to disk every Nth call-frame if anything is dirty. We count
// frames *requested* (the `n` arg to run_frames), not framesRendered —
// test ROMs that STP immediately never advance vblank, so a "frames
// rendered" clock would silently disable autosave for them. 0 disables.
// Default 60 = ~1s NTSC.
uint32_t g_projectAutosaveFrames = 60;
uint64_t g_projectFrameClock     = 0;  // accumulated frames-requested
uint64_t g_projectLastSaveFrame  = 0;
// Last label string emitted by the tracer as a `; --- name ---\n` header.
// Compared by pointer (AdbgLabels storage owns stable const char*). Reset
// to nullptr on tracer_start, load_adbg, clear_adbg, destroy.
const char* g_tracer_last_label = nullptr;

// Per-function profiler. Hooks into the existing call/return path: on
// every JSR/JSL we push (target_pc, clock_at_push) on a parallel stack;
// on every RTS/RTL we pop, compute incl = pop_clock - push_clock and
// aggregate. excl = incl − sum(children's incl), tracked via the parent
// frame's child_acc field.
//
// `cpu.clock()` is non-monotonic in absolute terms — the ares scheduler
// periodically subtracts the per-thread minimum to prevent overflow —
// BUT it subtracts the same amount from every thread, so any
// (pop_clock − push_clock) delta is invariant under that reduction.
// Profiler math stays honest.
//
// Range filter (lo, hi): when set, only target_pcs inside [lo, hi] are
// aggregated. Frames outside the range still push/pop on the profiler
// stack so excl math for in-range parents remains correct.
struct ProfFrame {
  uint32_t target_pc;
  uint64_t push_clock;
  uint64_t child_acc;  // sum of children's incl cycles
  bool     aggregated; // true if target_pc passed the range filter
};

struct ProfStat {
  uint32_t calls = 0;
  uint64_t incl  = 0;
  uint64_t excl  = 0;
  uint64_t max   = 0;
  uint64_t min   = UINT64_MAX;
};

bool                          g_profileActive = false;
uint32_t                      g_profileLo     = 0;  // 0,0 = unfiltered
uint32_t                      g_profileHi     = 0;
std::vector<ProfFrame>        g_profileStack;
std::unordered_map<uint32_t, ProfStat> g_profileStats;

// Monotonic master-cycle clock. Built on ares CPU's internal step counter
// (`masterCycleCounter()`), which increments by 2 per master tick and is
// NOT touched by the scheduler's reduce pass — unlike `Thread::_clock`,
// where reduce subtracts `minimum()` from every thread and corrupts any
// delta straddling a reduce event. The counter is u32 and wraps roughly
// every 2^32 ticks (~200s of emulated wall time at 21.477MHz). We widen
// to u64 by detecting any backward step as a wrap and adding 2^32 to a
// running base; profile_start resets both.
uint32_t                      g_lastMasterCounter = 0;
uint64_t                      g_masterCounterBase = 0;

uint64_t profileMasterCycles() {
  uint32_t raw = ares::SuperFamicom::cpu.masterCycleCounter();
  if(raw < g_lastMasterCounter) {
    g_masterCounterBase += ((uint64_t)1 << 32);
  }
  g_lastMasterCounter = raw;
  return g_masterCounterBase + (uint64_t)raw;
}

void profileOnCall(uint32_t target_pc) {
  if(!g_profileActive) return;
  ProfFrame f{};
  f.target_pc = target_pc & 0xFFFFFF;
  f.push_clock = profileMasterCycles();
  f.child_acc = 0;
  f.aggregated = (g_profileLo == 0 && g_profileHi == 0)
                 || (f.target_pc >= g_profileLo && f.target_pc <= g_profileHi);
  g_profileStack.push_back(f);
}

void profileOnReturn() {
  if(!g_profileActive) return;
  if(g_profileStack.empty()) return;
  ProfFrame top = g_profileStack.back();
  g_profileStack.pop_back();
  uint64_t now  = profileMasterCycles();
  uint64_t incl = now - top.push_clock;
  uint64_t excl = incl > top.child_acc ? (incl - top.child_acc) : 0;
  if(top.aggregated) {
    auto& s = g_profileStats[top.target_pc];
    s.calls += 1;
    s.incl  += incl;
    s.excl  += excl;
    if(incl > s.max) s.max = incl;
    if(incl < s.min) s.min = incl;
  }
  if(!g_profileStack.empty()) {
    g_profileStack.back().child_acc += incl;
  }
}

void cOnCall(uint32_t callsite_pc, uint32_t target_pc, uint8_t kind) {
  if(g_callstack.size() >= kCallstackCap) g_callstack.pop_front();
  kintsuki_call_frame_t f{};
  f.callsite_pc = callsite_pc & 0xFFFFFF;
  f.target_pc   = target_pc   & 0xFFFFFF;
  f.kind        = kind;
  g_callstack.push_back(f);
  profileOnCall(target_pc);
  // Auto-seed entry flags at every JSR/JSL target so cold-cache disasm at
  // any reached function knows the caller's M/X/E. First writer wins —
  // manual edits are not clobbered.
  if(g_project) {
    auto& r = ares::SuperFamicom::cpu.r;
    g_project->record_entry_flags(target_pc,
                                  (int8_t)r.p.m, (int8_t)r.p.x, (int8_t)r.e,
                                  /*force=*/false);
  }
}

void cOnReturn(uint8_t kind) {
  if(g_callstack.empty()) return;
  // Snapshot entry of the frame we're about to pop. The shadow stack's
  // top frame is the routine that's exiting.
  uint32_t entry = g_callstack.back().target_pc & 0xFFFFFF;
  g_callstack.pop_back();
  profileOnReturn();
  if(g_project) {
    // exit_pc = the RTS/RTL opcode address. cOnExec stashes the last
    // PC it saw; ares' returnHook fires after PC has moved to the
    // return target, so we can't read it from cpu.r.pc here.
    uint64_t frame = kintsukiProgram ? kintsukiProgram->framesRendered : 0;
    g_project->note_function_exit(entry, g_lastExecPc, kind, frame);
  }
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
  g_project.reset();
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

void kintsuki_run_frames(kintsuki_t* h, uint32_t n) {
  if(!h) return;
  h->program->runFrames(n);
  // Autosave: debounced flush. Project::save() is a no-op when nothing
  // is dirty, so the cost when idle is one comparison + one method call
  // per autosave window. Disable by setting interval to 0.
  if(g_project && g_projectAutosaveFrames > 0) {
    g_projectFrameClock += n;
    if(g_projectFrameClock >= g_projectLastSaveFrame + g_projectAutosaveFrames) {
      g_project->save();
      g_projectLastSaveFrame = g_projectFrameClock;
    }
  }
}
uint64_t kintsuki_frame_count(kintsuki_t* h) { return h ? h->program->framesRendered : 0; }

uint64_t kintsuki_master_clock(kintsuki_t* h) {
  if(!h) return 0;
  return ares::SuperFamicom::cpu.clock();
}

uint64_t kintsuki_cpu_cycles(kintsuki_t* h) {
  if(!h) return 0;
  // SNES CPU runs at master/6. Thread clock is in ares-scaled units; the
  // scalar collapses the ratio to nominal cycles for the lowest-frequency
  // thread we care about. Dividing the master count by 6 keeps the unit
  // intuitive for asm developers reading per-instruction timings.
  return (uint64_t)ares::SuperFamicom::cpu.clock() / 6;
}

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
  g_lastExecPc = pc & 0xFFFFFF;
  if(g_project) {
    // Resolve instruction length from the live opcode + M/X flags so
    // operand bytes get marked as CodeOperand (the user can spot
    // `lda #$1234` immediates vs raw code without re-disassembling).
    auto& r = ares::SuperFamicom::cpu.r;
    uint8_t opcode = ares::SuperFamicom::cpu.readDisassembler(pc & 0xFFFFFF);
    uint8_t len = inst_length_for(opcode, r.p.m, r.p.x);
    g_project->note_exec(pc, len ? len : 1);
  }
  tracerOnExec(pc);
  if(g_cExecPages[(pc & 0xffffff) >> 8] == 0) return;
  cFire(g_cExec, pc, 0);
}


// Inline project-data classifier; merged into cOnRead so a single
// memReadHook covers both user CBs and the slice-7 project data marker.
inline void projectMarkRead(uint32_t addr) {
  if(!g_project) return;
  int64_t rom = g_project->bus_to_rom_offset(addr);
  if(rom < 0) return;
  uint32_t o = (uint32_t)rom;
  if((uint8_t)g_project->classify(o) != 0) return;   // already classified
  g_project->mark_auto(o, 1, kintsuki::ByteClass::Data);
}

void cOnRead(uint32_t addr, uint8_t value) {
  projectMarkRead(addr);
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
    // Keep hooks armed when a project is open — the project relies on
    // exec + read marks even with zero user-registered CBs.
    if(kind == CB_EXEC  && !g_project) ares::SuperFamicom::execHook = nullptr;
    if(kind == CB_READ  && !g_project) ares::SuperFamicom::memReadHook = nullptr;
    if(kind == CB_WRITE)               ares::SuperFamicom::memWriteHook = nullptr;
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

int kintsuki_run_until_ex(kintsuki_t* h, uint32_t target_pc,
                          uint32_t max_frames, uint64_t* out_cycles) {
  if(!h) return 0;
  // Snapshot the monotonic master-cycle counter (widened via the same
  // wrap-tracker the profiler uses). Bracket the wrapped run_until call
  // so the delta survives any scheduler reduce and any u32 wrap of the
  // ares internal counter.
  uint64_t before = profileMasterCycles();
  int hit = kintsuki_run_until(h, target_pc, max_frames);
  uint64_t after = profileMasterCycles();
  if(out_cycles) *out_cycles = after - before;
  return hit;
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

void kintsuki_profile_start(kintsuki_t* h, uint32_t lo, uint32_t hi) {
  if(!h) return;
  g_profileStats.clear();
  g_profileStack.clear();
  g_profileLo = lo & 0xFFFFFF;
  g_profileHi = hi & 0xFFFFFF;
  // Re-baseline the master-cycle widener. We don't reset the ares core
  // counter (private, lives in the cpu Counter struct); instead we
  // snapshot its current value as the new origin.
  g_lastMasterCounter = ares::SuperFamicom::cpu.masterCycleCounter();
  g_masterCounterBase = 0;
  g_profileActive = true;
}

void kintsuki_profile_stop(kintsuki_t* h) {
  if(!h) return;
  g_profileActive = false;
  // Drop any unclosed frames — partial functions in-flight at stop have
  // no honest incl number. Leaving them in g_profileStack would corrupt
  // a subsequent profile_start's first push/pop accounting.
  g_profileStack.clear();
}

void kintsuki_profile_reset(kintsuki_t* h) {
  if(!h) return;
  g_profileStats.clear();
  g_profileStack.clear();
}

uint32_t kintsuki_profile_stats_count(kintsuki_t* h) {
  if(!h) return 0;
  return (uint32_t)g_profileStats.size();
}

uint32_t kintsuki_profile_stats(kintsuki_t* h,
                                kintsuki_fn_stat_t* out,
                                uint32_t cap) {
  if(!h || !out || cap == 0) return 0;
  uint32_t i = 0;
  for(auto const& kv : g_profileStats) {
    if(i >= cap) break;
    out[i].pc          = kv.first;
    out[i].calls       = kv.second.calls;
    out[i].incl_cycles = kv.second.incl;
    out[i].excl_cycles = kv.second.excl;
    out[i].max_cycles  = kv.second.max;
    out[i].min_cycles  = kv.second.min == UINT64_MAX ? 0 : kv.second.min;
    i++;
  }
  return i;
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
  uint32_t caller_pc;    // 24-bit; top of shadow callstack at fire time
};
constexpr size_t kDmaLogCap = 64;
DmaLogEntry g_dmaLog[kDmaLogCap] = {};
size_t g_dmaLogSize = 0;

void dmaHookFn(uint8_t channel, uint8_t direction, uint8_t mode,
               uint32_t src, uint8_t dst, uint16_t size) {
  // Caller PC: top of the shadow callstack (the most recently entered
  // routine), falling back to live cpu.r.pc.d if no JSR/JSL is on the
  // stack yet (cold boot, IRQ context). 24-bit.
  uint32_t callerPc = g_callstack.empty()
    ? ((uint32_t)ares::SuperFamicom::cpu.r.pc.d & 0xFFFFFF)
    : (g_callstack.back().target_pc & 0xFFFFFF);
  // Project-file auto-classification: tag the ROM source range by the
  // destination PPU register class (graphics/palette/...) — no-op when
  // no project is open.
  if(g_project) {
    uint64_t frame = g_handle ? g_handle->program->framesRendered : 0;
    g_project->note_dma(src, size, dst);
    g_project->note_dma_provenance(src, size, dst, callerPc, frame);
  }
  // Capture VMADDR (word) at the moment the DMA fires — gives the
  // user the actual VRAM destination, not just "we wrote something
  // through VMDATA". Read from the live performance PPU; the
  // CGRAM/OAM equivalents could be added later if needed.
  uint16_t vramAddr = (uint16_t)ares::SuperFamicom::ppuPerformanceImpl.vram.address;
  // Dedupe key now includes vram_addr + caller_pc so two transfers from
  // different callers (or to different VRAM regions) don't collapse.
  for(size_t i = 0; i < g_dmaLogSize; i++) {
    auto& e = g_dmaLog[i];
    if(e.src_addr == src && e.dst_reg == dst && e.size == size
       && e.vram_addr == vramAddr && e.caller_pc == callerPc) {
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
    .caller_pc = callerPc,
  };
  if(g_dmaLogSize < kDmaLogCap) g_dmaLogSize++;
}

struct DmaHookInstaller {
  DmaHookInstaller() { ares::SuperFamicom::kintsukiDmaHook = &dmaHookFn; }
} g_dmaHookInstaller;

// HDMA per-line trace. Each scanline gets a bitmask of channels that
// fired on it. Double-buffered: writes go into `current`, snapshot
// reads from `latched` (last fully-captured frame). Switch-over fires
// when the host's frame counter advances — a new frame's first hdma
// fire triggers the swap.
constexpr size_t kHdmaScanlines = 320;   // generous: NTSC 262, PAL 312
uint8_t g_hdmaCurrent[kHdmaScanlines] = {};
uint8_t g_hdmaLatched[kHdmaScanlines] = {};
uint64_t g_hdmaCurrentFrame = 0;

void hdmaHookFn(uint8_t channel, uint16_t scanline, uint8_t /*dst*/) {
  uint64_t frame = g_handle ? g_handle->program->framesRendered : 0;
  if(frame != g_hdmaCurrentFrame) {
    // Frame just rolled over — latch what we accumulated and clear.
    std::memcpy(g_hdmaLatched, g_hdmaCurrent, sizeof(g_hdmaCurrent));
    std::memset(g_hdmaCurrent, 0, sizeof(g_hdmaCurrent));
    g_hdmaCurrentFrame = frame;
  }
  if(scanline < kHdmaScanlines && channel < 8) {
    g_hdmaCurrent[scanline] |= (uint8_t)(1u << channel);
  }
}

struct HdmaHookInstaller {
  HdmaHookInstaller() { ares::SuperFamicom::kintsukiHdmaHook = &hdmaHookFn; }
} g_hdmaHookInstaller;
}

uint32_t kintsuki_hdma_scanline_mask(kintsuki_t* h, uint8_t* out, uint32_t cap) {
  if(!h || !out || cap == 0) return 0;
  uint32_t n = (uint32_t)((cap < kHdmaScanlines) ? cap : kHdmaScanlines);
  std::memcpy(out, g_hdmaLatched, n);
  return n;
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
    out[i].caller_pc = e.caller_pc;
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
}  // extern "C"
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
extern "C" {

uint32_t kintsuki_disassemble_at_ex(kintsuki_t* h, uint32_t pc, uint32_t count,
                                    int e_override, int m_override, int x_override,
                                    kintsuki_disasm_line_t* out);

// Classify the bytes of a disassembled instruction string into the
// token-kind enum. State machine — single linear scan, populates
// `kinds[0..len]` and zeroes the rest. Heuristic but matches every
// shape ares' wdc65816 disassembler emits (verified against the
// in-tree disassembler).
namespace {
inline bool isHexChar(char c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f');
}
void classifyTokens(const char* text, size_t len, uint8_t* kinds) {
  std::memset(kinds, 0, 128);
  if(len == 0) return;
  size_t i = 0;
  // Mnemonic: leading letters (+ optional `.l`/`.w` width suffix).
  while(i < len && ((text[i] >= 'A' && text[i] <= 'Z')
                 || (text[i] >= 'a' && text[i] <= 'z')
                 || text[i] == '.')) {
    kinds[i++] = KINTSUKI_TOK_MNEMONIC;
  }
  // Operand stream.
  while(i < len) {
    char c = text[i];
    if(c == '#') {
      kinds[i++] = KINTSUKI_TOK_PUNCT;
      if(i < len && text[i] == '$') {
        size_t start = i;
        kinds[i++] = KINTSUKI_TOK_IMM_HEX;
        while(i < len && isHexChar(text[i])) kinds[i++] = KINTSUKI_TOK_IMM_HEX;
        (void)start;
      }
    } else if(c == '$') {
      size_t start = i;
      i++;
      while(i < len && isHexChar(text[i])) i++;
      size_t hexLen = i - start - 1;
      uint8_t cls = hexLen <= 2 ? KINTSUKI_TOK_DP_HEX
                  : hexLen <= 4 ? KINTSUKI_TOK_ABS_HEX
                  :              KINTSUKI_TOK_LONG_HEX;
      for(size_t k = start; k < i; k++) kinds[k] = cls;
    } else if(c == ',') {
      kinds[i++] = KINTSUKI_TOK_PUNCT;
      if(i < len && (text[i] == 'X' || text[i] == 'Y' || text[i] == 'S'
                  || text[i] == 'x' || text[i] == 'y' || text[i] == 's')) {
        kinds[i++] = KINTSUKI_TOK_REG;
      }
    } else if(c == '[' || c == ']' || c == '(' || c == ')') {
      kinds[i++] = KINTSUKI_TOK_PUNCT;
    } else if(c == '-' && i + 1 < len && text[i + 1] == '>') {
      // ` -> name` annotation — paint the arrow as ARROW, the rest as
      // LABEL_REF up to end-of-string.
      kinds[i++] = KINTSUKI_TOK_ARROW;
      kinds[i++] = KINTSUKI_TOK_ARROW;
      while(i < len && text[i] == ' ') kinds[i++] = KINTSUKI_TOK_ARROW;
      while(i < len) kinds[i++] = KINTSUKI_TOK_LABEL_REF;
    } else {
      i++;   // whitespace + punctuation we don't tag stay OTHER (0)
    }
  }
}
}  // namespace

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
    // Tokenize for syntax-highlighted rendering. Cheap (single linear
    // pass over <128 chars). Bytes past sl (NUL + padding) stay OTHER.
    classifyTokens(out[i].text, sl, out[i].kinds);
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

// ---- Project file -------------------------------------------------------

int kintsuki_project_open(kintsuki_t* h, const char* dir) {
  if(!h || !dir) return 0;
  if(!h->program) return 0;
  if(h->program->romSize() == 0) {
    std::fprintf(stderr, "kintsuki_project_open: no ROM loaded\n");
    return 0;
  }
  g_project.reset();
  g_project = kintsuki::Project::open(
    dir,
    h->program->romPristineSha(),
    h->program->romSize(),
    h->program->romManifest(),
    h->program->romIsHiRom());
  if(!g_project) return 0;
  // Ensure execHook is wired so note_exec fires even without user CBs.
  if(!ares::SuperFamicom::execHook) ares::SuperFamicom::execHook = &cOnExec;
  // memReadHook only fires when registered; install cOnRead (which
  // both stamps the project data classifier inline and dispatches
  // user-registered tracing CBs). When the user later adds a CB,
  // kintsuki_add_callback_ex installs cOnRead too — same target,
  // safe to overwrite.
  if(!ares::SuperFamicom::memReadHook) ares::SuperFamicom::memReadHook = &cOnRead;
  g_projectFrameClock    = 0;
  g_projectLastSaveFrame = 0;
  return 1;
}

void kintsuki_project_close(kintsuki_t* h) {
  (void)h;
  g_project.reset();
  g_projectFrameClock    = 0;
  g_projectLastSaveFrame = 0;
}

int kintsuki_project_save(kintsuki_t* h) {
  (void)h;
  if(!g_project) return 0;
  return g_project->save() ? 1 : 0;
}

int kintsuki_project_is_open(kintsuki_t* h) {
  (void)h;
  return g_project ? 1 : 0;
}

uint8_t kintsuki_project_classify(kintsuki_t* h, uint32_t rom_offset) {
  (void)h;
  if(!g_project) return 0;
  auto cls = (uint8_t)g_project->classify(rom_offset);
  if(g_project->is_user_sticky(rom_offset)) cls |= KINTSUKI_BYTE_USER_STICKY;
  return cls;
}

int kintsuki_project_bus_to_rom(kintsuki_t* h, uint32_t bus_addr, uint32_t* out_offset) {
  (void)h;
  if(!g_project || !out_offset) return 0;
  int64_t off = g_project->bus_to_rom_offset(bus_addr);
  if(off < 0) return 0;
  *out_offset = (uint32_t)off;
  return 1;
}

uint32_t kintsuki_project_mark(kintsuki_t* h, uint32_t rom_offset, uint32_t len,
                               kintsuki_byte_class_t cls, int user_sticky) {
  (void)h;
  if(!g_project || len == 0) return 0;
  auto kcls = (kintsuki::ByteClass)((uint8_t)cls & 0x7F);
  if(user_sticky) g_project->mark_user(rom_offset, len, kcls);
  else            g_project->mark_auto(rom_offset, len, kcls);
  return len;
}

uint32_t kintsuki_project_map_dump(kintsuki_t* h, uint8_t* out, uint32_t cap) {
  if(!h || !out || cap == 0 || !g_project) return 0;
  uint32_t total = g_project->stats().total;
  uint32_t n = (cap < total) ? cap : total;
  for(uint32_t i = 0; i < n; i++) {
    out[i] = (uint8_t)g_project->classify(i);
    if(g_project->is_user_sticky(i)) out[i] |= KINTSUKI_BYTE_USER_STICKY;
  }
  return n;
}

void kintsuki_project_set_autosave(kintsuki_t* h, uint32_t frames) {
  (void)h;
  g_projectAutosaveFrames = frames;
}

uint32_t kintsuki_project_get_autosave(kintsuki_t* h) {
  (void)h;
  return g_projectAutosaveFrames;
}

int kintsuki_project_stats(kintsuki_t* h, kintsuki_project_stats_t* out) {
  (void)h;
  if(!g_project || !out) return 0;
  auto s = g_project->stats();
  out->total       = s.total;
  out->classified  = s.classified;
  out->code        = s.code;
  out->data        = s.data;
  out->user_sticky = s.user_sticky;
  return 1;
}

// ---- Labels overlay -----------------------------------------------------

int kintsuki_project_label_set(kintsuki_t* h, uint32_t addr,
                               const char* name, const char* type,
                               const char* comment,
                               int m, int x, int e) {
  (void)h;
  if(!g_project) return 0;
  kintsuki::Project::Label L{};
  L.addr    = addr & 0xFFFFFF;
  if(name)    L.name    = name;
  if(type)    L.type    = type;
  if(comment) L.comment = comment;
  L.m = (int8_t)(m < 0 ? -1 : (m ? 1 : 0));
  L.x = (int8_t)(x < 0 ? -1 : (x ? 1 : 0));
  L.e = (int8_t)(e < 0 ? -1 : (e ? 1 : 0));
  g_project->set_label(L);
  return 1;
}

int kintsuki_project_label_get(kintsuki_t* h, uint32_t addr,
                               kintsuki_project_label_t* out) {
  (void)h;
  if(!g_project || !out) return 0;
  const auto* L = g_project->get_label(addr & 0xFFFFFF);
  if(!L) return 0;
  out->addr    = L->addr;
  out->name    = L->name.c_str();
  out->type    = L->type.c_str();
  out->comment = L->comment.c_str();
  out->m       = L->m;
  out->x       = L->x;
  out->e       = L->e;
  return 1;
}

void kintsuki_project_label_clear(kintsuki_t* h, uint32_t addr) {
  (void)h;
  if(!g_project) return;
  g_project->clear_label(addr & 0xFFFFFF);
}

uint32_t kintsuki_project_label_count(kintsuki_t* h) {
  (void)h;
  return g_project ? g_project->label_count() : 0;
}

uint32_t kintsuki_project_label_snapshot(kintsuki_t* h,
                                         kintsuki_project_label_t* out,
                                         uint32_t cap) {
  (void)h;
  if(!g_project || !out || cap == 0) return 0;
  uint32_t total = g_project->label_count();
  uint32_t n = total < cap ? total : cap;
  for(uint32_t i = 0; i < n; i++) {
    // label_at points into project-owned std::string storage; pointers
    // stay valid until the next mutation (per the contract documented
    // on kintsuki_project_label_t).
    const auto* L = g_project->label_at(i);
    if(!L) { n = i; break; }
    out[i].addr    = L->addr;
    out[i].name    = L->name.c_str();
    out[i].type    = L->type.c_str();
    out[i].comment = L->comment.c_str();
    out[i].m       = L->m;
    out[i].x       = L->x;
    out[i].e       = L->e;
  }
  return n;
}

// ---- DMA provenance -----------------------------------------------------

namespace {
void copyProv(kintsuki_project_dma_prov_t& dst,
              const kintsuki::Project::DmaProv& src) {
  dst.src_rom    = src.src_rom;
  dst.size       = src.size;
  dst.dst_reg    = src.dst_reg;
  dst._pad       = 0;
  dst.caller_pc  = src.caller_pc;
  dst.hits       = src.hits;
  dst.last_frame = src.last_frame;
}
}  // namespace

uint32_t kintsuki_project_dma_prov_count(kintsuki_t* h) {
  (void)h;
  return g_project ? g_project->dma_prov_count() : 0;
}

uint32_t kintsuki_project_dma_prov_snapshot(kintsuki_t* h,
                                            kintsuki_project_dma_prov_t* out,
                                            uint32_t cap) {
  (void)h;
  if(!g_project || !out || cap == 0) return 0;
  uint32_t total = g_project->dma_prov_count();
  uint32_t n = total < cap ? total : cap;
  for(uint32_t i = 0; i < n; i++) {
    const auto* p = g_project->dma_prov_at(i);
    if(!p) { n = i; break; }
    copyProv(out[i], *p);
  }
  return n;
}

uint32_t kintsuki_project_dma_prov_for_range(kintsuki_t* h,
                                             uint32_t rom_offset, uint32_t len,
                                             kintsuki_project_dma_prov_t* out,
                                             uint32_t cap) {
  (void)h;
  if(!g_project || !out || cap == 0) return 0;
  std::vector<kintsuki::Project::DmaProv> tmp(cap);
  uint32_t n = g_project->dma_prov_for_range(rom_offset, len, tmp.data(), cap);
  for(uint32_t i = 0; i < n; i++) copyProv(out[i], tmp[i]);
  return n;
}

// ---- Function exits ----------------------------------------------------

uint32_t kintsuki_project_func_count(kintsuki_t* h) {
  (void)h;
  return g_project ? g_project->func_count() : 0;
}

uint32_t kintsuki_project_func_snapshot(kintsuki_t* h,
                                        kintsuki_project_func_t* out,
                                        uint32_t cap) {
  (void)h;
  if(!g_project || !out || cap == 0) return 0;
  uint32_t total = g_project->func_count();
  uint32_t n = total < cap ? total : cap;
  for(uint32_t i = 0; i < n; i++) {
    const auto* fi = g_project->func_at(i);
    if(!fi) { n = i; break; }
    out[i].entry           = fi->entry;
    out[i].call_count      = fi->call_count;
    out[i].last_exit_frame = fi->last_exit_frame;
    out[i].exit_count      = (uint32_t)fi->exit_pcs.size();
  }
  return n;
}

uint32_t kintsuki_project_func_exits(kintsuki_t* h, uint32_t entry,
                                     kintsuki_project_exit_t* out,
                                     uint32_t cap) {
  (void)h;
  if(!g_project || !out || cap == 0) return 0;
  const auto* fi = g_project->func_for(entry);
  if(!fi) return 0;
  uint32_t n = (uint32_t)std::min<size_t>(fi->exit_pcs.size(), cap);
  for(uint32_t i = 0; i < n; i++) {
    out[i].pc   = fi->exit_pcs[i];
    out[i].kind = fi->exit_kinds[i];
  }
  return n;
}

// ---- Bookmarks ---------------------------------------------------------

int kintsuki_project_bookmark_set(kintsuki_t* h, const char* name, uint32_t addr,
                                  const char* view, const char* comment) {
  (void)h;
  if(!g_project || !name) return 0;
  kintsuki::Project::Bookmark b{};
  b.addr    = addr & 0xFFFFFF;
  b.name    = name;
  if(view)    b.view    = view;
  if(comment) b.comment = comment;
  g_project->set_bookmark(b);
  return 1;
}

void kintsuki_project_bookmark_clear(kintsuki_t* h, const char* name) {
  (void)h;
  if(!g_project || !name) return;
  g_project->clear_bookmark(name);
}

uint32_t kintsuki_project_bookmark_count(kintsuki_t* h) {
  (void)h;
  return g_project ? g_project->bookmark_count() : 0;
}

uint32_t kintsuki_project_bookmark_snapshot(kintsuki_t* h,
                                            kintsuki_project_bookmark_t* out,
                                            uint32_t cap) {
  (void)h;
  if(!g_project || !out || cap == 0) return 0;
  uint32_t total = g_project->bookmark_count();
  uint32_t n = total < cap ? total : cap;
  for(uint32_t i = 0; i < n; i++) {
    const auto* b = g_project->bookmark_at(i);
    if(!b) { n = i; break; }
    out[i].addr    = b->addr;
    out[i].name    = b->name.c_str();
    out[i].view    = b->view.c_str();
    out[i].comment = b->comment.c_str();
  }
  return n;
}

// ---- Breakpoints -------------------------------------------------------

int kintsuki_project_bp_add(kintsuki_t* h, uint8_t kind,
                            uint32_t addr_lo, uint32_t addr_hi,
                            int halt, int enabled, const char* comment) {
  (void)h;
  if(!g_project) return 0;
  kintsuki::Project::Breakpoint bp{};
  bp.kind    = (kintsuki::Project::BpKind)(kind & 0x3);
  bp.halt    = halt != 0;
  bp.enabled = enabled != 0;
  bp.addr_lo = addr_lo & 0xFFFFFF;
  bp.addr_hi = addr_hi & 0xFFFFFF;
  if(comment) bp.comment = comment;
  g_project->add_breakpoint(bp);
  return 1;
}

void kintsuki_project_bp_remove(kintsuki_t* h, uint32_t index) {
  (void)h;
  if(!g_project) return;
  g_project->remove_breakpoint(index);
}

void kintsuki_project_bp_clear(kintsuki_t* h) {
  (void)h;
  if(!g_project) return;
  g_project->clear_breakpoints();
}

uint32_t kintsuki_project_bp_count(kintsuki_t* h) {
  (void)h;
  return g_project ? g_project->breakpoint_count() : 0;
}

uint32_t kintsuki_project_bp_snapshot(kintsuki_t* h, kintsuki_project_bp_t* out,
                                      uint32_t cap) {
  (void)h;
  if(!g_project || !out || cap == 0) return 0;
  uint32_t total = g_project->breakpoint_count();
  uint32_t n = total < cap ? total : cap;
  for(uint32_t i = 0; i < n; i++) {
    const auto* bp = g_project->breakpoint_at(i);
    if(!bp) { n = i; break; }
    out[i].kind    = (uint8_t)bp->kind;
    out[i].halt    = bp->halt ? 1 : 0;
    out[i].enabled = bp->enabled ? 1 : 0;
    out[i]._pad    = 0;
    out[i].addr_lo = bp->addr_lo;
    out[i].addr_hi = bp->addr_hi;
    out[i].comment = bp->comment.c_str();
  }
  return n;
}

}  // extern "C"
