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

extern "C" {

struct kintsuki_t {
  std::unique_ptr<Program> program;
};

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

struct kintsuki_cpu_state_t {
  uint16_t a, x, y, s, d;
  uint8_t  b, p;
  uint32_t pc;
  uint8_t  e;
};

void kintsuki_get_state(kintsuki_t* h, kintsuki_cpu_state_t* out) {
  if(!h || !out) return;
  CpuState s = h->program->getCpuState();
  out->a = s.a; out->x = s.x; out->y = s.y;
  out->s = s.s; out->d = s.d; out->b = s.b;
  out->p = s.p; out->pc = s.pc; out->e = s.e ? 1 : 0;
}

void kintsuki_set_state(kintsuki_t* h, const kintsuki_cpu_state_t* in) {
  if(!h || !in) return;
  CpuState s;
  s.a = in->a; s.x = in->x; s.y = in->y;
  s.s = in->s; s.d = in->d; s.b = in->b;
  s.p = in->p; s.pc = in->pc; s.e = in->e != 0;
  h->program->setCpuState(s);
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

}  // extern "C"
