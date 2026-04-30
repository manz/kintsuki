// kintsuki C ABI shim. Stub — full port pending in next session.

#include "program.hpp"
#include <memory>

extern "C" {

struct kintsuki_t { std::unique_ptr<Program> program; };
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
  if(h->program) ares::SuperFamicom::system.unload();
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

void kintsuki_run_frames(kintsuki_t* h, uint32_t n) {
  if(h) h->program->runFrames(n);
}

uint64_t kintsuki_frame_count(kintsuki_t* h) {
  return h ? h->program->framesRendered : 0;
}

uint8_t kintsuki_read_u8(kintsuki_t* h, uint32_t addr) {
  return h ? h->program->memRead(addr) : 0;
}

void kintsuki_write_u8(kintsuki_t* h, uint32_t addr, uint8_t val) {
  if(h) h->program->memWrite(addr, val);
}

}  // extern "C"
