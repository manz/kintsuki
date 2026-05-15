; Profiler exercise ROM. Five-deep call chain hammered in an infinite
; loop so kintsuki's per-function profiler sees enough samples to
; produce a meaningful flat profile across a multi-frame window.
;
;   reset → main_loop → outer → mid_a → mid_b → leaf_fast
;                                              → leaf_slow (much longer)
;
; Expected after run_frames(N):
;   - main_loop, outer, mid_a, mid_b, leaf_fast, leaf_slow all hot
;   - calls(main_loop) == calls(outer) == ... == calls(mid_b)
;   - calls(leaf_fast) == calls(leaf_slow) == calls(mid_b)
;   - excl(leaf_slow) >> excl(leaf_fast)
;   - incl(outer) ≈ sum of children's incl + outer's own cycles

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf

*=0x008000
reset:
    sei
    clc
    xce
    rep #0x30
    ldx.w #0x1FFF
    txs
    sep #0x20

main_loop:
    jsr.w outer
    bra main_loop          ; spin forever; no STP

*=0x008100
outer:
    nop
    jsr.w mid_a
    rts

*=0x008200
mid_a:
    nop
    jsr.w mid_b
    rts

*=0x008300
mid_b:
    nop
    jsr.w leaf_fast
    jsr.w leaf_slow
    rts

*=0x008400
leaf_fast:
    nop
    rts

; ~64 nops → ~128 master cycles of work before rts. Distinguishable
; from leaf_fast's single nop in the profile.
*=0x008500
leaf_slow:
    nop ; 1
    nop
    nop
    nop
    nop
    nop
    nop
    nop ; 8
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop ; 16
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop ; 24
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop ; 32
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop ; 40
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop ; 48
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop ; 56
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop ; 64
    rts

; Cartridge header
*=0x00FFC0
.ascii "KINTSUKI PROFILER    "
.db 0x20
.db 0x00
.db 0x09
.db 0x00
.db 0x01
.db 0x33
.db 0x00

*=0x00FFDC
.dw 0xFFFF
.dw 0x0000

*=0x00FFE4
.dw 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000

*=0x00FFF4
.dw 0x0000, 0x0000, 0x0000, 0x0000
.dw reset
.dw 0x0000

*=0x01FFFF
.db 0x00
