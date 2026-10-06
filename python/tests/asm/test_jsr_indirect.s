; JSR (abs,X) exercise ROM: a dispatcher calling two jobs through a jump
; table, the shape of an engine's per-frame job list. Each job's RTS must pop
; its own frame, not the dispatcher's.
;
;   main -> dispatch -> (job_table,X) -> job_a / job_b

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf

*=0x008000
reset:
    sei
    clc
    xce
    rep #0x30
    ldx.w #0x1FFF
    txs

main:
    jsr.w dispatch
    bra main

*=0x008100
dispatch:
    ldx.w #0
    .db 0xFC  ; jsr (job_table, x): raw, the pinned a816 lacks the mode
    .dw 0x8180
    ldx.w #2
    .db 0xFC
    .dw 0x8180
    .for i := 1, 32 {
    nop  ; the dispatcher's own work
    }
    rts

*=0x008180
job_table:
    .dw 0x8200, 0x8300

*=0x008200
job_a:
    nop
    rts

*=0x008300
job_b:
    .for i := 1, 16 {
    nop
    }
    rts

; Cartridge header
*=0x00FFC0
.ascii "KINTSUKI JSRINDIRECT "
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
