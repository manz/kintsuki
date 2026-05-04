// kintsuki C ABI. Single-instance for now (bsnes core uses globals).
// Link: -lkintsuki

#ifndef KINTSUKI_H
#define KINTSUKI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kintsuki_t kintsuki_t;

typedef struct {
  uint16_t a, x, y, s, d;
  uint8_t  b, p;
  uint32_t pc;   // 24-bit
  uint8_t  e;    // emulation flag (1 = 6502 mode)
  uint8_t  stp;  // 1 if CPU is halted by STP
  uint8_t  wai;  // 1 if CPU is waiting for IRQ via WAI
} kintsuki_cpu_state_t;

// 0=exec, 1=read, 2=write
typedef enum {
  KINTSUKI_CB_EXEC  = 0,
  KINTSUKI_CB_READ  = 1,
  KINTSUKI_CB_WRITE = 2,
} kintsuki_cb_kind_t;

// Callback signature. For exec hooks `value` is 0; for read it is the byte
// just returned by the bus; for write it is the byte being written.
typedef void (*kintsuki_cb_t)(uint32_t addr, uint8_t value, void* userdata);

// Lifecycle
kintsuki_t* kintsuki_create(void);
void        kintsuki_destroy(kintsuki_t*);
int         kintsuki_load_rom(kintsuki_t*, const char* path);

// Execution
void        kintsuki_run_frames(kintsuki_t*, uint32_t n);
void        kintsuki_step(kintsuki_t*);
uint64_t    kintsuki_frame_count(kintsuki_t*);

// Mid-frame run-until. Yields the scheduler the moment the CPU is about
// to execute target_pc — does NOT wait for vblank. Returns 1 on hit,
// 0 if max_frames of emulated time elapsed without reaching the target.
int         kintsuki_run_until(kintsuki_t*, uint32_t target_pc, uint32_t max_frames);

// Rearm the CPU coroutine. Use this between back-to-back test stubs that
// end with STP — the CPU coroutine is suspended inside instructionStop's
// idle loop, and just clearing r.stp doesn't unwind it cleanly. Rearm
// destroys + recreates the libco coroutine, clears pending interrupts,
// preserves WRAM and all other emulator state. Cheap (microseconds).
void        kintsuki_rearm_cpu(kintsuki_t*);

// Memory (CPU bus, 24-bit address)
uint8_t     kintsuki_read_u8 (kintsuki_t*, uint32_t addr);
void        kintsuki_write_u8(kintsuki_t*, uint32_t addr, uint8_t val);
uint32_t    kintsuki_read_range(kintsuki_t*, uint32_t addr, uint32_t len, uint8_t* out);

// PPU memory (off-bus)
uint8_t     kintsuki_vram_read (kintsuki_t*, uint32_t addr);
void        kintsuki_vram_write(kintsuki_t*, uint32_t addr, uint8_t v);
uint8_t     kintsuki_cgram_read (kintsuki_t*, uint32_t addr);
void        kintsuki_cgram_write(kintsuki_t*, uint32_t addr, uint8_t v);
uint8_t     kintsuki_oam_read (kintsuki_t*, uint32_t addr);
void        kintsuki_oam_write(kintsuki_t*, uint32_t addr, uint8_t v);

// Bulk dumps. One FFI hop for the whole region — way faster than looping
// per-byte read for inspector views.
//   VRAM  = 64 KB (n16[32K] copied as little-endian bytes)
//   CGRAM = 512 B (n15[256])
//   OAM   = 544 B (512 B sprite table + 32 B high table)
// Returns bytes actually copied (min of region size and `len`).
uint32_t    kintsuki_vram_dump (kintsuki_t*, uint8_t* out, uint32_t len);
uint32_t    kintsuki_cgram_dump(kintsuki_t*, uint8_t* out, uint32_t len);
uint32_t    kintsuki_oam_dump  (kintsuki_t*, uint8_t* out, uint32_t len);

// CPU state
void        kintsuki_get_state(kintsuki_t*, kintsuki_cpu_state_t* out);
void        kintsuki_set_state(kintsuki_t*, const kintsuki_cpu_state_t* in);

// PPU/DMA snapshot. Read-only view of registers that are write-only on the
// CPU bus (BGMODE, BGxSC, BGxHOFS/VOFS, TM/TS/TMW/TSW, CGWSEL/CGADSUB,
// SETINI) plus per-channel HDMA state (mode, dest reg, src addr/bank,
// indirect, lineCounter, enabled bit). Reconstructs TM/TS/TMW/TSW from the
// per-layer enable bits stored inside ares.
typedef struct {
  uint8_t  ctrl;        // $43xa low (transferMode | direction | indirect | ...)
  uint8_t  dest;        // $43xb BBADx (PPU register $21XX low byte)
  uint16_t src_addr;    // $43xc-d A1Tx
  uint8_t  src_bank;    // $43xe A1Bx
  uint16_t ind_count;   // $43xf-g (transferSize / indirectAddress)
  uint8_t  ind_bank;    // $43xh
  uint8_t  line_count;  // $43xa internal lineCounter
  uint8_t  enabled;     // 1 if HDMAEN bit is set
} kintsuki_dma_channel_t;

typedef struct {
  uint8_t  inidisp;       // $2100 brightness + force-blank
  uint8_t  bgmode;        // $2105 (mode | priority | tile-size bits)
  uint8_t  mosaic;        // $2106
  uint8_t  bg1sc, bg2sc, bg3sc, bg4sc;     // $2107..$210A
  uint8_t  bg12nba, bg34nba;                // $210B,$210C
  uint16_t bg1hofs, bg1vofs, bg2hofs, bg2vofs;
  uint16_t bg3hofs, bg3vofs, bg4hofs, bg4vofs;
  uint8_t  vmain;         // $2115 reconstructed
  uint16_t vmaddr;        // $2116/$2117
  uint8_t  m7sel;
  uint16_t m7a, m7b, m7c, m7d, m7x, m7y;
  uint8_t  cgadd;
  uint8_t  tm, ts, tmw, tsw;       // $212C..$212F (rebuilt from per-layer bits)
  uint8_t  cgwsel, cgadsub;        // $2130/$2131
  uint8_t  setini;        // $2133
  uint16_t hcounter, vcounter;
  kintsuki_dma_channel_t dma[8];
  uint8_t  mdmaen, hdmaen;  // reconstructed from cpu.channels[].dmaEnable/hdmaEnable
} kintsuki_ppu_state_t;

void kintsuki_get_ppu_state(kintsuki_t*, kintsuki_ppu_state_t* out);

// Savestate. Two-call style: pass buf=NULL,cap=0 to query required size,
// then call again with a buffer of at least the returned size. Returns
// the required size on success or 0 on failure.
uint32_t    kintsuki_save_state(kintsuki_t*, void* buf, uint32_t cap);
int         kintsuki_load_state(kintsuki_t*, const void* buf, uint32_t len);

// Framebuffer. Returns pointer to internal RGBA buffer (0x00RRGGBB packed
// in uint32) valid until next frame. Width and height filled out.
const uint32_t* kintsuki_framebuffer(kintsuki_t*, uint32_t* out_w, uint32_t* out_h);
int         kintsuki_screenshot(kintsuki_t*, const char* path);

// Input. mask bits: Up=0 Down=1 Left=2 Right=3 B=4 A=5 Y=6 X=7 L=8 R=9 Select=10 Start=11
void        kintsuki_set_input(kintsuki_t*, int port, uint16_t mask);
void        kintsuki_press(kintsuki_t*, int port, int button, int pressed);

// Callbacks. Returns 1-based id, 0 on failure. Pass id back to remove.
int         kintsuki_add_callback(kintsuki_t*, int kind, uint32_t lo, uint32_t hi,
                                  kintsuki_cb_t fn, void* userdata);
void        kintsuki_remove_callback(kintsuki_t*, int kind, int id);

#ifdef __cplusplus
}
#endif

#endif
