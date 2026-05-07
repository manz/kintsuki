# C ABI reference

Header: `target-kintsuki/kintsuki.h`. Single-instance for now (ares uses
globals); only one `kintsuki_t*` may exist at a time.

## Lifecycle

```c
kintsuki_t* kintsuki_create(void);
void        kintsuki_destroy(kintsuki_t*);
int         kintsuki_load_rom(kintsuki_t*, const char* path);
```

## Execution

```c
void     kintsuki_run_frames(kintsuki_t*, uint32_t n);
void     kintsuki_step(kintsuki_t*);
uint64_t kintsuki_frame_count(kintsuki_t*);
int      kintsuki_run_until(kintsuki_t*, uint32_t target_pc, uint32_t max_frames);
void     kintsuki_rearm_cpu(kintsuki_t*);
```

`kintsuki_rearm_cpu` rebuilds the libco coroutine. Always called by
`kintsuki_load_state` internally; expose if you need to drive it
yourself.

## Memory

CPU bus, 24-bit address.

```c
uint8_t  kintsuki_read_u8 (kintsuki_t*, uint32_t addr);
void     kintsuki_write_u8(kintsuki_t*, uint32_t addr, uint8_t val);
uint32_t kintsuki_read_range (kintsuki_t*, uint32_t addr, uint32_t len, uint8_t* out);
uint32_t kintsuki_write_range(kintsuki_t*, uint32_t addr, uint32_t len, const uint8_t* in_);
```

PPU memory (off-bus): same shape with `vram`, `cgram`, `oam` prefixes
plus `kintsuki_ppu_hires` to query whether a column-collapse is wanted
in canonical-output paths.

## State

```c
void kintsuki_get_state(kintsuki_t*, kintsuki_cpu_state_t* out);
void kintsuki_set_state(kintsuki_t*, const kintsuki_cpu_state_t* in);
void kintsuki_get_ppu_state(kintsuki_t*, kintsuki_ppu_state_t* out);
```

## Save state

```c
uint32_t kintsuki_save_state(kintsuki_t*, void* buf, uint32_t cap);
int      kintsuki_load_state(kintsuki_t*, const void* buf, uint32_t len);
```

Two-call: pass `buf=NULL, cap=0` to query required size; call again with
a buffer of at least the returned size.

## Framebuffer + screenshot

```c
const uint32_t* kintsuki_framebuffer(kintsuki_t*, uint32_t* w, uint32_t* h);
int             kintsuki_screenshot(kintsuki_t*, const char* path);
int             kintsuki_ppu_hires(kintsuki_t*);
```

## Tracer

```c
typedef enum { KINTSUKI_TRACE_RING = 0, KINTSUKI_TRACE_FILE = 1 } kintsuki_trace_mode_t;

void     kintsuki_tracer_start(kintsuki_t*, uint32_t lo, uint32_t hi,
                               kintsuki_trace_mode_t mode,
                               const char* path, uint32_t ring_capacity);
void     kintsuki_tracer_stop(kintsuki_t*);
uint32_t kintsuki_tracer_drain(kintsuki_t*, char* out, uint32_t cap);

typedef struct { uint32_t start; uint32_t size; } kintsuki_trace_range_t;
void     kintsuki_tracer_set_ranges(kintsuki_t*,
                                    const kintsuki_trace_range_t*, uint32_t count);
```

## Shadow callstack

```c
typedef struct {
  uint32_t callsite_pc;
  uint32_t target_pc;
  uint8_t  kind;
} kintsuki_call_frame_t;

uint32_t kintsuki_callstack_snapshot(kintsuki_t*,
                                     kintsuki_call_frame_t* out, uint32_t cap);
void     kintsuki_callstack_clear(kintsuki_t*);
```

## .adbg debug info

```c
int          kintsuki_load_adbg(kintsuki_t*, const char* path);
void         kintsuki_clear_adbg(kintsuki_t*);
const char*  kintsuki_lookup_label(kintsuki_t*, uint32_t addr);
const char*  kintsuki_lookup_label_containing(kintsuki_t*, uint32_t addr,
                                              uint32_t* out_offset);
int          kintsuki_lookup_symbol_addr(kintsuki_t*, const char* name,
                                         uint32_t* out_addr);
int          kintsuki_lookup_source(kintsuki_t*, uint32_t addr,
                                    const char** out_file,
                                    uint32_t* out_line, uint16_t* out_column);
```

`lookup_label` is exact-match. Use `lookup_label_containing` for runtime
PCs (callsite, crash backtrace, etc.).

## Callbacks

```c
typedef void (*kintsuki_cb_t)(uint32_t addr, uint8_t value, void* userdata);

int  kintsuki_add_callback   (kintsuki_t*, int kind, uint32_t lo, uint32_t hi,
                              kintsuki_cb_t fn, void* userdata);
void kintsuki_remove_callback(kintsuki_t*, int kind, int id);
```

`kind`: `KINTSUKI_CB_EXEC` (`0`), `_READ` (`1`), `_WRITE` (`2`). Returns
a 1-based id; `0` on failure. Range filter is page-granular (256-entry
bitmap) for cheap dispatch.
