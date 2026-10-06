; Live counter exercise ROM: a loop that writes INIDISP ($2100) every pass, so
; a write callback on $2100 and the PPU write log see the same writes. The
; callback's live counters must match the log's live scanline/dot.

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf

*=0x008000
reset:
    sei
    clc
    xce
    sep #0x20
    lda #0x80  ; force blank, brightness 0

loop:
    sta.w 0x2100
    .for i := 1, 40 {
    nop
    }
    bra loop

; Cartridge header
*=0x00FFC0
.ascii "KINTSUKI LIVECOUNTER "
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
