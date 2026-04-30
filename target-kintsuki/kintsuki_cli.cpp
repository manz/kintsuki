// kintsuki CLI: headless ares runner with embedded LuaJIT for SNES test
// scripts. Wraps the lua-free Program (program.hpp/program.cpp) and exposes
// it as the `emu.*` table inside the script.

#include "program.hpp"

extern "C" {
  #include <lua.h>
  #include <lualib.h>
  #include <lauxlib.h>
}

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>

static lua_State* g_lua = nullptr;

// =============================================================================
// Memory/exec callback storage. Each kind has its own list and 256-byte page
// bitmap for fast-skip when the current address isn't covered.
// =============================================================================

struct LuaCallback {
  uint32_t lo;
  uint32_t hi;
  int luaRef;
  bool active;
};

static std::vector<LuaCallback> g_execCallbacks;
static std::vector<LuaCallback> g_readCallbacks;
static std::vector<LuaCallback> g_writeCallbacks;

static uint8_t g_pcPageHits[65536]    = {};
static uint8_t g_readPageHits[65536]  = {};
static uint8_t g_writePageHits[65536] = {};

static auto markPages(uint8_t* pages, uint32_t lo, uint32_t hi, int delta) -> void {
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

// =============================================================================
// Hook trampolines
// =============================================================================

static auto fireCallbacks(std::vector<LuaCallback>& list, uint32_t addr,
                          int extraValue = -1) -> void {
  if(!g_lua) return;
  for(auto& cb : list) {
    if(!cb.active) continue;
    if(addr < cb.lo || addr > cb.hi) continue;
    lua_rawgeti(g_lua, LUA_REGISTRYINDEX, cb.luaRef);
    lua_pushinteger(g_lua, addr);
    int nargs = 1;
    if(extraValue >= 0) {
      lua_pushinteger(g_lua, extraValue);
      nargs = 2;
    }
    int rc = lua_pcall(g_lua, nargs, 0, 0);
    if(rc != LUA_OK) {
      std::fprintf(stderr, "callback error: %s\n", lua_tostring(g_lua, -1));
      lua_pop(g_lua, 1);
    }
  }
}

static auto onCpuExec(uint32_t pc) -> void {
  if(g_pcPageHits[(pc & 0xffffff) >> 8] == 0) return;
  fireCallbacks(g_execCallbacks, pc);
}

static auto onMemRead(uint32_t addr, uint8_t value) -> void {
  if(g_readPageHits[(addr & 0xffffff) >> 8] == 0) return;
  fireCallbacks(g_readCallbacks, addr, value);
}

static auto onMemWrite(uint32_t addr, uint8_t value) -> void {
  if(g_writePageHits[(addr & 0xffffff) >> 8] == 0) return;
  fireCallbacks(g_writeCallbacks, addr, value);
}

// =============================================================================
// Lua bindings (emu.*)
// =============================================================================

static auto buttonByName(const char* name) -> int {
  static const char* names[12] = {
    "Up","Down","Left","Right","B","A","Y","X","L","R","Select","Start"
  };
  for(int i = 0; i < 12; i++) {
    if(std::strcmp(name, names[i]) == 0) return i;
  }
  return -1;
}

static int lua_run_frames(lua_State* L) {
  uint n = (uint)luaL_checkinteger(L, 1);
  kintsukiProgram->runFrames(n);
  return 0;
}

static int lua_read_u8(lua_State* L) {
  uint addr = (uint)luaL_checkinteger(L, 1);
  lua_pushinteger(L, kintsukiProgram->memRead(addr));
  return 1;
}

static int lua_read_u16(lua_State* L) {
  uint addr = (uint)luaL_checkinteger(L, 1);
  uint8_t lo = kintsukiProgram->memRead(addr);
  uint8_t hi = kintsukiProgram->memRead(addr + 1);
  lua_pushinteger(L, lo | (hi << 8));
  return 1;
}

static int lua_write_u8(lua_State* L) {
  uint addr = (uint)luaL_checkinteger(L, 1);
  uint8_t val = (uint8_t)luaL_checkinteger(L, 2);
  kintsukiProgram->memWrite(addr, val);
  return 0;
}

static int lua_vram_read(lua_State* L) {
  lua_pushinteger(L, kintsukiProgram->vramRead((uint)luaL_checkinteger(L, 1)));
  return 1;
}
static int lua_vram_write(lua_State* L) {
  kintsukiProgram->vramWrite((uint)luaL_checkinteger(L, 1), (uint8_t)luaL_checkinteger(L, 2));
  return 0;
}
static int lua_cgram_read(lua_State* L) {
  lua_pushinteger(L, kintsukiProgram->cgramRead((uint)luaL_checkinteger(L, 1)));
  return 1;
}
static int lua_cgram_write(lua_State* L) {
  kintsukiProgram->cgramWrite((uint)luaL_checkinteger(L, 1), (uint8_t)luaL_checkinteger(L, 2));
  return 0;
}
static int lua_oam_read(lua_State* L) {
  lua_pushinteger(L, kintsukiProgram->oamRead((uint)luaL_checkinteger(L, 1)));
  return 1;
}
static int lua_oam_write(lua_State* L) {
  kintsukiProgram->oamWrite((uint)luaL_checkinteger(L, 1), (uint8_t)luaL_checkinteger(L, 2));
  return 0;
}

static int lua_read_range(lua_State* L) {
  uint32_t addr = (uint32_t)luaL_checkinteger(L, 1);
  uint32_t len  = (uint32_t)luaL_checkinteger(L, 2);
  if(len > (16u << 20)) return luaL_error(L, "read_range: length too large");
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for(uint32_t i = 0; i < len; i++) {
    luaL_addchar(&b, (char)kintsukiProgram->memRead(addr + i));
  }
  luaL_pushresult(&b);
  return 1;
}

static int lua_press(lua_State* L) {
  uint port = (uint)luaL_checkinteger(L, 1);
  const char* name = luaL_checkstring(L, 2);
  int b = buttonByName(name);
  if(b < 0) return luaL_error(L, "unknown button: %s", name);
  kintsukiProgram->setButton(port, (uint)b, true);
  return 0;
}

static int lua_release(lua_State* L) {
  uint port = (uint)luaL_checkinteger(L, 1);
  const char* name = luaL_checkstring(L, 2);
  int b = buttonByName(name);
  if(b < 0) return luaL_error(L, "unknown button: %s", name);
  kintsukiProgram->setButton(port, (uint)b, false);
  return 0;
}

static int lua_clear_input(lua_State* L) {
  kintsukiProgram->clearInput();
  return 0;
}

static int lua_save_state(lua_State* L) {
  auto blob = kintsukiProgram->saveStateBlob();
  lua_pushlstring(L, (const char*)blob.data(), blob.size());
  return 1;
}

static int lua_load_state(lua_State* L) {
  size_t len = 0;
  const char* s = luaL_checklstring(L, 1, &len);
  lua_pushboolean(L, kintsukiProgram->loadStateBlob((const uint8_t*)s, len));
  return 1;
}

static int lua_save_state_file(lua_State* L) {
  lua_pushboolean(L, kintsukiProgram->saveStateFile(luaL_checkstring(L, 1)));
  return 1;
}

static int lua_load_state_file(lua_State* L) {
  lua_pushboolean(L, kintsukiProgram->loadStateFile(luaL_checkstring(L, 1)));
  return 1;
}

static int lua_screenshot(lua_State* L) {
  lua_pushboolean(L, kintsukiProgram->writeScreenshot(luaL_checkstring(L, 1)));
  return 1;
}

static int lua_log(lua_State* L) {
  std::fprintf(stderr, "%s\n", luaL_checkstring(L, 1));
  return 0;
}

// Replace Lua's built-in print() so script output stays on stderr in headless.
static int lua_print_stderr(lua_State* L) {
  int n = lua_gettop(L);
  lua_getglobal(L, "tostring");
  for(int i = 1; i <= n; i++) {
    lua_pushvalue(L, -1);
    lua_pushvalue(L, i);
    lua_call(L, 1, 1);
    size_t len = 0;
    const char* s = lua_tolstring(L, -1, &len);
    if(s == nullptr) s = "(?)";
    if(i > 1) std::fputc('\t', stderr);
    std::fwrite(s, 1, len, stderr);
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  std::fputc('\n', stderr);
  return 0;
}

static int lua_frame_count(lua_State* L) {
  lua_pushinteger(L, (lua_Integer)kintsukiProgram->framesRendered);
  return 1;
}

// CPU register access. Mesen-compat wrapper in mesen_compat.lua puts this
// behind {cpu = ...}.
static int lua_get_state(lua_State* L) {
  CpuState s = kintsukiProgram->getCpuState();
  lua_newtable(L);
  #define SETI(k, v) lua_pushinteger(L, (lua_Integer)(v)); lua_setfield(L, -2, k)
  SETI("a", s.a); SETI("x", s.x); SETI("y", s.y);
  SETI("s", s.s); SETI("d", s.d); SETI("b", s.b);
  SETI("p", s.p); SETI("pc", s.pc); SETI("e", s.e ? 1 : 0);
  #undef SETI
  return 1;
}

static int lua_set_state(lua_State* L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  CpuState s = kintsukiProgram->getCpuState();
  auto getI = [&](const char* k, lua_Integer def) -> lua_Integer {
    lua_getfield(L, 1, k);
    lua_Integer v = lua_isnil(L, -1) ? def : lua_tointeger(L, -1);
    lua_pop(L, 1);
    return v;
  };
  s.a  = (uint16_t)getI("a", s.a);
  s.x  = (uint16_t)getI("x", s.x);
  s.y  = (uint16_t)getI("y", s.y);
  s.s  = (uint16_t)getI("s", s.s);
  s.d  = (uint16_t)getI("d", s.d);
  s.b  = (uint8_t) getI("b", s.b);
  s.p  = (uint8_t) getI("p", s.p);
  s.pc = (uint32_t)getI("pc", s.pc);
  s.e  = (bool)    getI("e", s.e);
  kintsukiProgram->setCpuState(s);
  return 0;
}

// Callback registration — generic helpers shared across exec/read/write.
static int addCallback(lua_State* L, std::vector<LuaCallback>& list, uint8_t* pages,
                       int luaArgIndex = 3) {
  uint32_t lo = (uint32_t)luaL_checkinteger(L, 1);
  uint32_t hi = (uint32_t)luaL_checkinteger(L, 2);
  luaL_checktype(L, luaArgIndex, LUA_TFUNCTION);
  lua_pushvalue(L, luaArgIndex);
  int ref = luaL_ref(L, LUA_REGISTRYINDEX);
  list.push_back({lo, hi, ref, true});
  markPages(pages, lo, hi, +1);
  lua_pushinteger(L, (lua_Integer)list.size());  // 1-based id
  return 1;
}

static auto removeCallback(lua_State* L, std::vector<LuaCallback>& list,
                           uint8_t* pages, int id) -> bool {
  if(id < 1 || (size_t)id > list.size()) return false;
  auto& cb = list[id - 1];
  if(cb.active) {
    luaL_unref(L, LUA_REGISTRYINDEX, cb.luaRef);
    markPages(pages, cb.lo, cb.hi, -1);
    cb.active = false;
  }
  for(auto& c : list) if(c.active) return true;
  return false;  // none active
}

static int lua_add_exec_callback(lua_State* L) {
  int rv = addCallback(L, g_execCallbacks, g_pcPageHits);
  ares::SuperFamicom::execHook = &onCpuExec;
  return rv;
}
static int lua_add_read_callback(lua_State* L) {
  int rv = addCallback(L, g_readCallbacks, g_readPageHits);
  ares::SuperFamicom::memReadHook = &onMemRead;
  return rv;
}
static int lua_add_write_callback(lua_State* L) {
  int rv = addCallback(L, g_writeCallbacks, g_writePageHits);
  ares::SuperFamicom::memWriteHook = &onMemWrite;
  return rv;
}

static int lua_remove_exec_callback(lua_State* L) {
  if(!removeCallback(L, g_execCallbacks, g_pcPageHits, (int)luaL_checkinteger(L, 1))) {
    ares::SuperFamicom::execHook = nullptr;
  }
  return 0;
}
static int lua_remove_read_callback(lua_State* L) {
  if(!removeCallback(L, g_readCallbacks, g_readPageHits, (int)luaL_checkinteger(L, 1))) {
    ares::SuperFamicom::memReadHook = nullptr;
  }
  return 0;
}
static int lua_remove_write_callback(lua_State* L) {
  if(!removeCallback(L, g_writeCallbacks, g_writePageHits, (int)luaL_checkinteger(L, 1))) {
    ares::SuperFamicom::memWriteHook = nullptr;
  }
  return 0;
}

static auto registerEmuTable(lua_State* L) -> void {
  static const luaL_Reg fns[] = {
    {"run_frames",            lua_run_frames},
    {"read_u8",               lua_read_u8},
    {"read_u16",              lua_read_u16},
    {"write_u8",              lua_write_u8},
    {"vram_read",             lua_vram_read},
    {"vram_write",            lua_vram_write},
    {"cgram_read",            lua_cgram_read},
    {"cgram_write",           lua_cgram_write},
    {"oam_read",              lua_oam_read},
    {"oam_write",             lua_oam_write},
    {"read_range",            lua_read_range},
    {"press",                 lua_press},
    {"release",               lua_release},
    {"clear_input",           lua_clear_input},
    {"save_state",            lua_save_state},
    {"load_state",            lua_load_state},
    {"save_state_file",       lua_save_state_file},
    {"load_state_file",       lua_load_state_file},
    {"screenshot",            lua_screenshot},
    {"log",                   lua_log},
    {"frame_count",           lua_frame_count},
    {"get_state",             lua_get_state},
    {"set_state",             lua_set_state},
    {"add_exec_callback",     lua_add_exec_callback},
    {"remove_exec_callback",  lua_remove_exec_callback},
    {"add_read_callback",     lua_add_read_callback},
    {"add_write_callback",    lua_add_write_callback},
    {"remove_read_callback",  lua_remove_read_callback},
    {"remove_write_callback", lua_remove_write_callback},
    {nullptr, nullptr},
  };
  lua_newtable(L);
  luaL_setfuncs(L, fns, 0);
  lua_setglobal(L, "emu");
}

static auto runScript(const char* path) -> int {
  lua_State* L = luaL_newstate();
  luaL_openlibs(L);
  // Headless: redirect Lua's built-in print() to stderr so stdout stays clean.
  lua_pushcfunction(L, lua_print_stderr);
  lua_setglobal(L, "print");
  registerEmuTable(L);
  g_lua = L;
  int rc = luaL_dofile(L, path);
  if(rc == LUA_OK) {
    // Mesen-compat shim registers a drive loop here so tests that only
    // register frame callbacks (no explicit run_frames) get driven.
    lua_getglobal(L, "emu");
    if(lua_istable(L, -1)) {
      lua_getfield(L, -1, "_shim_drive_loop");
      if(lua_isfunction(L, -1)) rc = lua_pcall(L, 0, 0, 0);
      else lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
  // Tear down hooks BEFORE closing Lua — they capture g_lua.
  ares::SuperFamicom::execHook = nullptr;
  ares::SuperFamicom::memReadHook = nullptr;
  ares::SuperFamicom::memWriteHook = nullptr;
  auto teardown = [&](std::vector<LuaCallback>& list, uint8_t* pages) {
    for(auto& cb : list) {
      if(cb.active) {
        luaL_unref(L, LUA_REGISTRYINDEX, cb.luaRef);
        markPages(pages, cb.lo, cb.hi, -1);
      }
    }
    list.clear();
  };
  teardown(g_execCallbacks,  g_pcPageHits);
  teardown(g_readCallbacks,  g_readPageHits);
  teardown(g_writeCallbacks, g_writePageHits);
  g_lua = nullptr;
  if(rc != LUA_OK) {
    std::fprintf(stderr, "lua error: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 1;
  }
  lua_close(L);
  return 0;
}

// =============================================================================
// CLI
// =============================================================================

static auto parseButtons(const char* spec) -> uint16_t {
  static const char* names[12] = {
    "Up","Down","Left","Right","B","A","Y","X","L","R","Select","Start"
  };
  uint16_t mask = 0;
  const char* p = spec;
  while(*p) {
    const char* end = p;
    while(*end && *end != ',') end++;
    size_t len = end - p;
    for(uint i = 0; i < 12; i++) {
      if(std::strlen(names[i]) == len && std::strncmp(p, names[i], len) == 0) {
        mask |= (uint16_t(1) << i);
        break;
      }
    }
    p = (*end == ',') ? end + 1 : end;
  }
  return mask;
}

static auto usage(const char* exe) -> void {
  std::fprintf(stderr,
    "usage: %s <rom.sfc> [options]\n"
    "  --frames N             run N frames (default 120)\n"
    "  --screenshot path      write framebuffer at end (.png or .ppm)\n"
    "  --load-state path      load savestate after boot\n"
    "  --save-state path      write savestate at end\n"
    "  --press p1=A,Start     hold buttons on port (p1 or p2) every frame\n"
    "  --mem-read 0x7E1700    print byte at end (CPU bus addr)\n"
    "  --mem-write 0x7E1700=5 write byte before run\n"
    "  --script test.lua      run a Lua test script (overrides --frames)\n",
    exe);
}

int main(int argc, char** argv) {
  if(argc < 2) { usage(argv[0]); return 2; }

  const char* romPath = argv[1];
  uint frames = 120;
  const char* screenshotPath = nullptr;
  const char* loadStatePath = nullptr;
  const char* saveStatePath = nullptr;
  uint16_t pressP1 = 0, pressP2 = 0;
  std::vector<uint> memReadAddrs;
  std::vector<std::pair<uint, uint8_t>> memWrites;
  const char* scriptPath = nullptr;

  for(int i = 2; i < argc; i++) {
    auto need = [&](const char* flag) -> const char* {
      if(i + 1 >= argc) {
        std::fprintf(stderr, "%s requires an argument\n", flag);
        std::exit(2);
      }
      return argv[++i];
    };
    string a = argv[i];
    if(a == "--frames")          frames = (uint)std::atoi(need("--frames"));
    else if(a == "--screenshot") screenshotPath = need("--screenshot");
    else if(a == "--load-state") loadStatePath = need("--load-state");
    else if(a == "--save-state") saveStatePath = need("--save-state");
    else if(a == "--script")     scriptPath = need("--script");
    else if(a == "--press") {
      const char* spec = need("--press");
      if(!std::strncmp(spec, "p1=", 3))      pressP1 = parseButtons(spec + 3);
      else if(!std::strncmp(spec, "p2=", 3)) pressP2 = parseButtons(spec + 3);
      else { std::fprintf(stderr, "--press needs p1=... or p2=...\n"); return 2; }
    }
    else if(a == "--mem-read") {
      memReadAddrs.push_back((uint)std::strtoul(need("--mem-read"), nullptr, 0));
    }
    else if(a == "--mem-write") {
      const char* spec = need("--mem-write");
      const char* eq = std::strchr(spec, '=');
      if(!eq) { std::fprintf(stderr, "--mem-write needs ADDR=VAL\n"); return 2; }
      uint addr = (uint)std::strtoul(spec, nullptr, 0);
      uint8_t val = (uint8_t)std::strtoul(eq + 1, nullptr, 0);
      memWrites.push_back({addr, val});
    }
    else { std::fprintf(stderr, "unknown flag: %s\n", (const char*)a); usage(argv[0]); return 2; }
  }

  auto program = std::make_unique<Program>();
  kintsukiProgram = program.get();

  if(!program->loadRom(romPath)) {
    std::fprintf(stderr, "failed to load ROM: %s\n", romPath);
    return 1;
  }
  if(!program->bootRom()) {
    std::fprintf(stderr, "failed to boot ROM\n");
    return 1;
  }

  if(loadStatePath) {
    if(!program->loadStateFile(loadStatePath)) {
      std::fprintf(stderr, "failed to load state: %s\n", loadStatePath);
      return 1;
    }
    std::fprintf(stderr, "loaded state: %s\n", loadStatePath);
  }

  for(auto& [addr, val] : memWrites) program->memWrite(addr, val);

  program->inputState[0] = pressP1;
  program->inputState[1] = pressP2;

  if(scriptPath) {
    int rc = runScript(scriptPath);
    if(rc != 0) { ares::SuperFamicom::system.unload(); return rc; }
  } else {
    program->runFrames(frames);
  }

  std::fprintf(stderr, "rendered %llu frames (%ux%u)\n",
    (unsigned long long)program->framesRendered, program->fbWidth, program->fbHeight);

  for(auto addr : memReadAddrs) {
    std::fprintf(stderr, "0x%06x = 0x%02x\n", addr, program->memRead(addr));
  }

  if(saveStatePath) {
    if(!program->saveStateFile(saveStatePath)) {
      std::fprintf(stderr, "failed to save state: %s\n", saveStatePath);
      return 1;
    }
    std::fprintf(stderr, "wrote state: %s\n", saveStatePath);
  }

  if(screenshotPath) {
    if(!program->writeScreenshot(screenshotPath)) {
      std::fprintf(stderr, "no framebuffer / failed to write %s\n", screenshotPath);
      return 1;
    }
    std::fprintf(stderr, "wrote %s\n", screenshotPath);
  }

  ares::SuperFamicom::system.unload();
  return 0;
}
