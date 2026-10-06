; Cooperative task switch exercise ROM: a kernel stack at $1FFF and one task
; stack at $0FFF, swapped with TCS (the shape of cacheguard's task.s, DQ6's
; fibers, Bahamut Lagoon's scheduler).
;
;   kernel:  main -> frame_work -> run_task      (TCS onto the task stack,
;                              -> kernel_after    RTS into the task)
;   task:    task_main -> task_step -> task_work
;                                   -> yield      (TCS back, RTS out of
;                                   -> task_work   run_task's frame)
;
; task_main is entered through a fabricated frame (no JSR), and the task
; yields from inside task_step, so a single shadow stack would pop the wrong
; frames. kernel_after also carves a local frame with TSC / SBC / TCS, which
; must not count as a switch.
;
; Expected with per-stack shadow stacks:
;   - calls(frame_work) == calls(run_task) == calls(kernel_after)
;   - calls(task_step) == calls(yield), calls(task_work) == 2 * calls(task_step)
;   - incl(task_step) ~ 2 * incl(task_work): the kernel's time while the task
;     is parked (kernel_after, 4x task_work) is not counted. A single shadow
;     stack lets frame_work's RTS pop task_step, billing it kernel_after.

KERNEL_SP = 0x0000  ; saved kernel S (word)
TASK_SP = 0x0002  ; saved task S (word)

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf

*=0x008000
reset:
    sei
    clc
    xce
    rep #0x30
    ; Fabricate the task's first resume frame: run_task's RTS lands on
    ; task_main.
    ldx.w #0x0FFF
    txs
    pea 0x83FF  ; task_main - 1 (pinned at $8400 below)
    tsc
    sta.b TASK_SP
    ldx.w #0x1FFF
    txs

main:
    jsr.w frame_work
    bra main

*=0x008100
frame_work:
    jsr.w run_task
    jsr.w kernel_after
    rts

*=0x008200
run_task:
    tsc
    sta.b KERNEL_SP
    lda.b TASK_SP
    tcs
    rts  ; into the task

*=0x008300
kernel_after:
    tsc
    sec
    sbc.w #0x0010  ; a 16-byte local frame
    tcs
    .for i := 1, 128 {
    nop  ; 4x task_work: kernel time a single shadow stack would bill to the task
    }
    tsc
    clc
    adc.w #0x0010
    tcs
    rts

*=0x008400
task_main:
    jsr.w task_step
    bra task_main

*=0x008500
task_step:
    jsr.w task_work
    jsr.w yield
    jsr.w task_work
    rts

*=0x008600
yield:
    tsc
    sta.b TASK_SP
    lda.b KERNEL_SP
    tcs
    rts  ; out of run_task's frame, back in the kernel

*=0x008700
task_work:
    .for i := 1, 32 {
    nop
    }
    rts

; Cartridge header
*=0x00FFC0
.ascii "KINTSUKI TASKSWITCH  "
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
