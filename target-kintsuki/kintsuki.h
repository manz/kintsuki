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

// Soft reset. Power-cycles the emulator without re-reading the ROM
// from disk. Equivalent to physically tapping the SNES reset button.
// Preserves cart SRAM contents. No-op if no ROM loaded.
void        kintsuki_reset(kintsuki_t*);

// Toggle automatic seeding of cart SRAM from a `<rom>.srm` sidecar
// file at `kintsuki_load_rom` time. Default 1 (mirrors mia loader);
// pass 0 before loading a ROM when you need deterministic zero-filled
// SRAM regardless of files on disk (e.g. test fixtures with stray
// `.srm` siblings). Set persists for the handle's lifetime.
void        kintsuki_set_srm_sidecar(kintsuki_t*, int enable);

// Load `len` bytes from `data` into the cart's SRAM region (the
// in-memory `save.ram` buffer ares allocated at boot). Use this to
// inject a `.srm` blob without binding the file on disk: the emulator
// writes stay in memory and the original file is never touched.
// Returns the number of bytes copied (clamped to the cart's actual
// SRAM size; 0 if no SRAM or no ROM).
uint32_t    kintsuki_inject_sram(kintsuki_t*, const uint8_t* data, uint32_t len);

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
uint32_t    kintsuki_write_range(kintsuki_t*, uint32_t addr, uint32_t len, const uint8_t* in_);

// PPU memory (off-bus)
uint8_t     kintsuki_vram_read (kintsuki_t*, uint32_t addr);
void        kintsuki_vram_write(kintsuki_t*, uint32_t addr, uint8_t v);
uint32_t    kintsuki_vram_read_range (kintsuki_t*, uint32_t addr, uint32_t len, uint8_t* out);
uint32_t    kintsuki_vram_write_range(kintsuki_t*, uint32_t addr, uint32_t len, const uint8_t* in_);
uint8_t     kintsuki_cgram_read (kintsuki_t*, uint32_t addr);
void        kintsuki_cgram_write(kintsuki_t*, uint32_t addr, uint8_t v);
uint32_t    kintsuki_cgram_read_range (kintsuki_t*, uint32_t addr, uint32_t len, uint8_t* out);
uint32_t    kintsuki_cgram_write_range(kintsuki_t*, uint32_t addr, uint32_t len, const uint8_t* in_);
uint8_t     kintsuki_oam_read (kintsuki_t*, uint32_t addr);
void        kintsuki_oam_write(kintsuki_t*, uint32_t addr, uint8_t v);
uint32_t    kintsuki_oam_read_range (kintsuki_t*, uint32_t addr, uint32_t len, uint8_t* out);
uint32_t    kintsuki_oam_write_range(kintsuki_t*, uint32_t addr, uint32_t len, const uint8_t* in_);

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
// 1 if the PPU is in hires (BGMODE 5/6) or pseudo-hires; 0 otherwise.
// Python `framebuffer()` uses this to collapse ares' always-doubled
// 564-wide output back to single columns in normal mode.
int         kintsuki_ppu_hires(kintsuki_t*);

// Input. mask bits: Up=0 Down=1 Left=2 Right=3 B=4 A=5 Y=6 X=7 L=8 R=9 Select=10 Start=11
void        kintsuki_set_input(kintsuki_t*, int port, uint16_t mask);
void        kintsuki_press(kintsuki_t*, int port, int button, int pressed);

// Callbacks. Returns 1-based id, 0 on failure. Pass id back to remove.
int         kintsuki_add_callback(kintsuki_t*, int kind, uint32_t lo, uint32_t hi,
                                  kintsuki_cb_t fn, void* userdata);
// Same as `kintsuki_add_callback`, but when `halt` is non-zero the
// scheduler is asked to bail out at the next safe instruction boundary
// after the callback fires — turning a tracing callback into a real
// breakpoint that pauses the host. The callback still runs first, so
// hit counters / inspector UI updates land before execution stops.
int         kintsuki_add_callback_ex(kintsuki_t*, int kind, uint32_t lo, uint32_t hi,
                                     int halt,
                                     kintsuki_cb_t fn, void* userdata);
void        kintsuki_remove_callback(kintsuki_t*, int kind, int id);

// ---- Shadow callstack ----------------------------------------------------
// Maintained transparently by the WDC65816 JSR/JSL/RTS/RTL hooks. Frames
// stay live across `kintsuki_run_*` calls and are explicitly cleared by
// `kintsuki_callstack_clear` (and implicitly by `kintsuki_load_state` /
// `kintsuki_rearm_cpu`, since both invalidate the live call chain).
typedef struct {
  uint32_t callsite_pc;   // 24-bit; address of the JSR/JSL opcode itself
  uint32_t target_pc;     // 24-bit; address jumped to
  uint8_t  kind;          // 0=JSR, 1=JSL
} kintsuki_call_frame_t;

// Snapshot the shadow callstack into `out` (deepest frame first). Returns
// number of frames actually written (min of `cap` and current depth).
uint32_t kintsuki_callstack_snapshot(kintsuki_t*,
                                     kintsuki_call_frame_t* out,
                                     uint32_t cap);
void     kintsuki_callstack_clear(kintsuki_t*);

// ---- a816 .adbg label table ---------------------------------------------
// LABEL-only loader (constants/aliases ignored). Returns 1 on success,
// 0 on missing file / bad magic / unsupported version. Replaces the
// previously-loaded table if any.
int          kintsuki_load_adbg(kintsuki_t*, const char* path);
void         kintsuki_clear_adbg(kintsuki_t*);
// O(1) lookup at the *exact* address. NULL if no label is bound there
// or no .adbg is loaded. `addr` is masked to 24 bits.
const char*  kintsuki_lookup_label(kintsuki_t*, uint32_t addr);

// Containing-label lookup: returns the label whose address is the
// largest ≤ `addr` (i.e. the routine `addr` lives inside). When
// `out_offset` is non-NULL it receives `addr - labelAddr`. NULL when
// no label precedes `addr`. O(log N), backed by a sorted vector
// computed once at .adbg load time. Use this for crash-backtrace
// symbolication where the callsite is rarely on a symbol boundary.
const char*  kintsuki_lookup_label_containing(kintsuki_t*, uint32_t addr,
                                              uint32_t* out_offset);

// Source-line lookup. Returns 1 + fills out_* when the loaded .adbg has
// a LINES entry covering `addr` (last instruction emitted up to that
// address). Returns 0 + leaves outputs untouched otherwise. The
// `out_file` pointer follows the same lifetime rules as
// `kintsuki_lookup_label`. Pass NULL for any output you don't need.
int          kintsuki_lookup_source(kintsuki_t*, uint32_t addr,
                                    const char** out_file,
                                    uint32_t* out_line,
                                    uint16_t* out_column);

// Reverse symbol lookup: name → 24-bit address. Returns 1 + fills
// `out_addr` on hit, 0 if no label by that name is loaded. Used by
// the tracer-mask API to translate `(symbol_name, size)` ranges into
// PC ranges client-side.
int          kintsuki_lookup_symbol_addr(kintsuki_t*, const char* name,
                                         uint32_t* out_addr);

// Number of labels currently loaded from .adbg. 0 when no .adbg is
// loaded. Used to size buffers passed to `kintsuki_label_snapshot`.
uint32_t     kintsuki_label_count(kintsuki_t*);

// Snapshot the loaded label table into `out`, sorted by 24-bit address
// ascending. Each `name` pointer borrows from .adbg-owned storage and
// stays valid until the next `kintsuki_load_adbg`/`kintsuki_clear_adbg`
// call. Returns the number of entries actually written
// (min of `cap` and `kintsuki_label_count`).
typedef struct {
  uint32_t    addr;   // 24-bit
  const char* name;
} kintsuki_label_entry_t;
uint32_t     kintsuki_label_snapshot(kintsuki_t*,
                                     kintsuki_label_entry_t* out,
                                     uint32_t cap);

// Formatted execution tracer. Wraps an exec callback that disassembles
// the instruction at PC + dumps CPU registers, producing one Mesen-
// style line per exec event in [lo,hi]. Single tracer per emulator —
// `tracer_start` stops the previous one. Modes:
//   RING: in-memory bounded ring; oldest bytes evicted when full so
//         drain returns at most `ring_capacity` bytes.
//   FILE: lines appended to `path` (truncated on start). `drain` is 0.
typedef enum {
  KINTSUKI_TRACE_RING = 0,
  KINTSUKI_TRACE_FILE = 1,
} kintsuki_trace_mode_t;

void        kintsuki_tracer_start(kintsuki_t*, uint32_t lo, uint32_t hi,
                                  kintsuki_trace_mode_t mode,
                                  const char* path,
                                  uint32_t ring_capacity);
void        kintsuki_tracer_stop(kintsuki_t*);
// Copy ring contents to `out` (max `cap` bytes), return bytes written.
// Drain clears the ring. In FILE mode returns 0.
uint32_t    kintsuki_tracer_drain(kintsuki_t*, char* out, uint32_t cap);

// Optional fine-grained PC mask. Each `(start, size)` describes a
// half-open `[start, start+size)` 24-bit address range; tracer lines
// only fire when PC falls inside *any* range in the list. Pass `count
// == 0` (or `ranges == NULL`) to clear the mask and fall back to the
// `[lo, hi]` range that `kintsuki_tracer_start` set. Sticky across
// stop/start so callers can configure once and run multiple traces.
typedef struct {
  uint32_t start;   // 24-bit, masked at apply time
  uint32_t size;    // bytes; entries with size == 0 are dropped
} kintsuki_trace_range_t;
void        kintsuki_tracer_set_ranges(kintsuki_t*,
                                       const kintsuki_trace_range_t* ranges,
                                       uint32_t count);

// ---- Disassemble-at -----------------------------------------------------
// Render `count` consecutive 65816 instructions starting at `pc` (24-bit)
// into `out`. Each entry holds the source PC, the byte length, and the
// formatted line text. Uses the live CPU's E/M/X register flags as the
// initial state and tracks REP/SEP flips through the disassembled stream
// so a `rep #$30` advance into 16-bit immediates stays correctly sized.
// Returns the number of entries actually produced.
typedef struct kintsuki_disasm_line_t {
  uint32_t pc;       // 24-bit
  uint8_t  length;   // 1..4 bytes
  uint8_t  _pad[3];
  // Static control-flow target for JMP/JML/JSR/JSL/Bxx/BRL when it can
  // be resolved without runtime register state. 0xFFFFFFFF when the
  // instruction is non-branching or its target depends on registers
  // (indirect/indexed). UI can use this for "double-click to follow".
  uint32_t target;
  char     text[128];
} kintsuki_disasm_line_t;

uint32_t kintsuki_disassemble_at(kintsuki_t*, uint32_t pc, uint32_t count,
                                 kintsuki_disasm_line_t* out);

// Same as `kintsuki_disassemble_at` but with explicit overrides for the
// initial E/M/X register flags. Pass -1 for any flag you want sourced
// from the live CPU state (the default behaviour). Use this when
// disassembling far from the current PC — at a fresh symbol the live
// M/X may not reflect what the call site actually expects (caller is
// either guessing a sane default like M=0,X=0 or reading flags from
// a previous trace / .adbg annotation).
uint32_t kintsuki_disassemble_at_ex(kintsuki_t*, uint32_t pc, uint32_t count,
                                    int e_override, int m_override, int x_override,
                                    kintsuki_disasm_line_t* out);

// ---- DMA transfer log ---------------------------------------------------
// Captures every Channel::dmaRun fire. Deduplicates by (src + dst + size)
// — if a game re-pushes the same buffer every frame the entry's hit
// count bumps instead of growing the log. Most-recent at index 0.
// Bounded to 64 entries on the host side.
typedef struct kintsuki_dma_event_t {
  uint32_t src_addr;     // 24-bit
  uint16_t size;
  uint8_t  channel;
  uint8_t  direction;    // 0 = A->B (CPU->PPU), 1 = B->A
  uint8_t  mode;         // transferMode (0..7)
  uint8_t  dst_reg;      // PPU register low byte ($21XX)
  uint16_t vram_addr;    // VMADDR at fire (word address); meaningful
                         // only when dst_reg == 0x18 / 0x19
  uint32_t hits;
  uint64_t last_frame;
  // Caller PC at the moment DMA fired. Sourced from the top of the
  // shadow callstack (deepest live JSR/JSL target), falling back to the
  // live cpu.r.pc.d if the callstack is empty. Lets viewers answer
  // "who pushed this VRAM block?" without a separate trace.
  uint32_t caller_pc;    // 24-bit
} kintsuki_dma_event_t;

uint32_t kintsuki_dma_log_count(kintsuki_t*);
uint32_t kintsuki_dma_log_snapshot(kintsuki_t*,
                                   kintsuki_dma_event_t* out,
                                   uint32_t cap);
void     kintsuki_dma_log_clear(kintsuki_t*);

// Per-scanline HDMA channel mask for the most recently completed
// frame (double-buffered). `out[i]` = bitmask of channels that fired
// on scanline `i` (bit 0 = channel 0). Returns the number of bytes
// written (min of `cap` and the internal scanline buffer size, 320).
uint32_t kintsuki_hdma_scanline_mask(kintsuki_t*, uint8_t* out, uint32_t cap);

// ---- Project file -------------------------------------------------------
// Persistent reversing state attached to the currently-loaded ROM. The
// project lives in a `.kintsuki/` directory next to the ROM. Slice 1 ships
// the byte-classification map (`map.bin`); labels/bookmarks/notes are
// reserved slots filled by later slices.
//
// Lifecycle: call `project_open` after `load_rom`. The project handle is
// owned by the kintsuki_t instance and torn down on `destroy` or on the
// next `project_open`/`project_close`. ROM size + sha256 must match what
// was recorded on first creation, otherwise open fails.
//
// While a project is open the emulator auto-populates `map.bin`:
//   - every executed PC marks its bytes as KINTSUKI_BYTE_CODE,
//   - every DMA fire marks its source range based on the destination PPU
//     register ($2118/9 -> GRAPHICS, $2122 -> PALETTE, etc.),
// unless the bytes are already user-sticky.
//
// Saves are explicit — call `project_save` before quitting. No autosave.

typedef enum {
  KINTSUKI_BYTE_UNKNOWN  = 0,
  KINTSUKI_BYTE_CODE     = 1,
  KINTSUKI_BYTE_DATA     = 2,
  KINTSUKI_BYTE_POINTER  = 3,
  KINTSUKI_BYTE_STRING   = 4,
  KINTSUKI_BYTE_GRAPHICS = 5,
  KINTSUKI_BYTE_TILEMAP  = 6,
  KINTSUKI_BYTE_PALETTE  = 7,
  KINTSUKI_BYTE_AUDIO    = 8,
  KINTSUKI_BYTE_CODE_OPERAND = 9,
} kintsuki_byte_class_t;

// User-sticky flag: OR'd into the byte stored in map.bin to mark a class as
// user-set, protecting it from auto-reclassification. Mask off when reading
// the base class.
#define KINTSUKI_BYTE_USER_STICKY 0x80
#define KINTSUKI_BYTE_CLASS_MASK  0x7F

// Returns 1 on success, 0 on failure (no ROM loaded, dir unwritable, sha
// mismatch on reload). On first open the directory is created.
int  kintsuki_project_open (kintsuki_t*, const char* dir);
// Closes without saving. Safe to call when no project is open.
void kintsuki_project_close(kintsuki_t*);
// Persist dirty state to disk. Returns 1 on success.
int  kintsuki_project_save (kintsuki_t*);
// 1 if a project is currently open.
int  kintsuki_project_is_open(kintsuki_t*);

// Single-byte classify at a ROM offset (NOT a bus address — caller is
// expected to have run `kintsuki_project_bus_to_rom` first when starting
// from a CPU bus address). Returns the raw byte value (class | sticky).
// 0 if no project open or offset out of range.
uint8_t kintsuki_project_classify(kintsuki_t*, uint32_t rom_offset);

// Convert a CPU bus 24-bit address to a ROM offset using the active
// cartridge mapper. Returns 1 + fills `out_offset` on hit, 0 if the
// address is not in ROM. Used by viewers that work in bus addresses.
int  kintsuki_project_bus_to_rom(kintsuki_t*, uint32_t bus_addr, uint32_t* out_offset);

// Mark a ROM range. `user_sticky` non-zero sets the sticky bit so auto-
// reclassification will not overwrite. Passing `cls == UNKNOWN` with
// `user_sticky=1` clears any existing classification + clears the sticky
// flag (use this to "un-mark" a region). Returns bytes actually written
// (clamped to map.bin size).
uint32_t kintsuki_project_mark(kintsuki_t*, uint32_t rom_offset, uint32_t len,
                               kintsuki_byte_class_t cls, int user_sticky);

// Bulk dump of map.bin to caller buffer. Returns bytes written (min of
// `cap` and ROM size). 0 if no project open.
uint32_t kintsuki_project_map_dump(kintsuki_t*, uint8_t* out, uint32_t cap);

// Summary counters for inspector header.
typedef struct {
  uint32_t total;       // ROM size in bytes
  uint32_t classified;  // bytes with class != UNKNOWN
  uint32_t code;
  uint32_t data;
  uint32_t user_sticky; // bytes the user has hand-marked
} kintsuki_project_stats_t;

int kintsuki_project_stats(kintsuki_t*, kintsuki_project_stats_t* out);

// Autosave: when non-zero, `kintsuki_run_frames` flushes the project
// every Nth completed frame if anything is dirty. Saves are debounced
// (no fsync storm when nothing changed). Default 60 frames (~1s NTSC).
// Set to 0 to disable and rely on explicit `kintsuki_project_save`.
void kintsuki_project_set_autosave(kintsuki_t*, uint32_t frames);
uint32_t kintsuki_project_get_autosave(kintsuki_t*);

// ---- Labels overlay (slice 2) ------------------------------------------
// Per-address user metadata layered on top of the loaded `.adbg`. Labels
// here win over .adbg labels at the same address — used for renaming
// routines mid-reverse without touching the assembly source. m/x/e are
// tri-state ints encoding the processor flag state expected at this
// entry point: 0 (clear / 16-bit), 1 (set / 8-bit), -1 (unset / not known).
//
// Auto-seeded: every JSR/JSL fire records the live M/X (E is fixed at
// reset) on the target address. First writer wins — manual `label_set`
// overrides via the same struct.

typedef struct {
  uint32_t    addr;     // 24-bit
  const char* name;     // borrowed; valid until next label_set/clear/close
  const char* type;     // optional; lowercase
  const char* comment;  // optional
  int8_t      m;        // -1 unset, 0/1
  int8_t      x;
  int8_t      e;
  uint8_t     _pad;
} kintsuki_project_label_t;

// Pass NULL for any optional string. Returns 1 on success, 0 if no
// project open. Replaces any existing entry at addr.
int kintsuki_project_label_set(kintsuki_t*, uint32_t addr,
                               const char* name,
                               const char* type,
                               const char* comment,
                               int m, int x, int e);
// Look up overlay-only (does NOT consult .adbg). Returns 1 + fills out
// on hit; pointers borrow storage owned by the project, valid until the
// next mutation.
int kintsuki_project_label_get(kintsuki_t*, uint32_t addr,
                               kintsuki_project_label_t* out);
void kintsuki_project_label_clear(kintsuki_t*, uint32_t addr);
uint32_t kintsuki_project_label_count(kintsuki_t*);
// Snapshot in address-ascending order. Returns number written.
uint32_t kintsuki_project_label_snapshot(kintsuki_t*,
                                         kintsuki_project_label_t* out,
                                         uint32_t cap);

// ---- DMA provenance (slice 3) ------------------------------------------
// Per (src_rom, size, dst_reg, caller_pc) record: who pushed which buffer
// where, and how often. Auto-populated from every DMA fire while a
// project is open. Persisted as `dma_log.tsv` on save.

typedef struct {
  uint32_t src_rom;     // ROM offset of source bytes
  uint16_t size;
  uint8_t  dst_reg;
  uint8_t  _pad;
  uint32_t caller_pc;   // 24-bit
  uint32_t hits;
  uint64_t last_frame;
} kintsuki_project_dma_prov_t;

uint32_t kintsuki_project_dma_prov_count(kintsuki_t*);
uint32_t kintsuki_project_dma_prov_snapshot(kintsuki_t*,
                                            kintsuki_project_dma_prov_t* out,
                                            uint32_t cap);
// Filter to entries overlapping `[rom_offset, rom_offset+len)` — viewer
// "who uploads this tile?" lookup.
uint32_t kintsuki_project_dma_prov_for_range(kintsuki_t*,
                                             uint32_t rom_offset, uint32_t len,
                                             kintsuki_project_dma_prov_t* out,
                                             uint32_t cap);

// ---- Function exits (slice 7) ------------------------------------------
// Per-function aggregated exit info, populated from the JSR/JSL <-> RTS/
// RTL hook pair while a project is open. Lets the UI answer "where does
// this routine return from?" for any known entry — drives the "end of
// function" view on the labels panel.

typedef struct {
  uint32_t entry;          // 24-bit
  uint32_t call_count;
  uint64_t last_exit_frame;
  uint32_t exit_count;     // number of unique (pc, kind) exit points
} kintsuki_project_func_t;

uint32_t kintsuki_project_func_count(kintsuki_t*);
uint32_t kintsuki_project_func_snapshot(kintsuki_t*,
                                        kintsuki_project_func_t* out,
                                        uint32_t cap);

// Per-function exit-PC list. Returns count actually written. The exits
// are de-duplicated by (pc, kind) on the C++ side.
typedef struct {
  uint32_t pc;             // 24-bit; address of the RTS/RTL opcode
  uint8_t  kind;           // 0=RTS, 1=RTL
  uint8_t  _pad[3];
} kintsuki_project_exit_t;

uint32_t kintsuki_project_func_exits(kintsuki_t*, uint32_t entry,
                                     kintsuki_project_exit_t* out,
                                     uint32_t cap);

// ---- Bookmarks (slice 4) -----------------------------------------------
typedef struct {
  uint32_t    addr;
  const char* name;
  const char* view;     // free-form short string
  const char* comment;
} kintsuki_project_bookmark_t;

int  kintsuki_project_bookmark_set(kintsuki_t*, const char* name, uint32_t addr,
                                   const char* view, const char* comment);
void kintsuki_project_bookmark_clear(kintsuki_t*, const char* name);
uint32_t kintsuki_project_bookmark_count(kintsuki_t*);
uint32_t kintsuki_project_bookmark_snapshot(kintsuki_t*,
                                            kintsuki_project_bookmark_t* out,
                                            uint32_t cap);

// ---- Breakpoints (slice 4) ---------------------------------------------
// Persistent records only — the project does NOT auto-install live BPs
// on attach. The frontend walks the snapshot at project_open time and
// re-calls kintsuki_add_callback_ex(...) for each enabled record, then
// drives removal through the existing callback handle if the user
// toggles the BP off.
typedef enum {
  KINTSUKI_PROJECT_BP_EXEC  = 0,
  KINTSUKI_PROJECT_BP_READ  = 1,
  KINTSUKI_PROJECT_BP_WRITE = 2,
} kintsuki_project_bp_kind_t;

typedef struct {
  uint8_t  kind;
  uint8_t  halt;
  uint8_t  enabled;
  uint8_t  _pad;
  uint32_t addr_lo;     // inclusive
  uint32_t addr_hi;     // inclusive
  const char* comment;
} kintsuki_project_bp_t;

int kintsuki_project_bp_add(kintsuki_t*, uint8_t kind,
                            uint32_t addr_lo, uint32_t addr_hi,
                            int halt, int enabled, const char* comment);
void kintsuki_project_bp_remove(kintsuki_t*, uint32_t index);
void kintsuki_project_bp_clear(kintsuki_t*);
uint32_t kintsuki_project_bp_count(kintsuki_t*);
uint32_t kintsuki_project_bp_snapshot(kintsuki_t*, kintsuki_project_bp_t* out,
                                      uint32_t cap);

#ifdef __cplusplus
}
#endif

#endif
