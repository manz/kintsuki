; HDMA bands: channel 0 writes INIDISP ($2100) every 16 lines, alternating full
; brightness and black over a white backdrop, so the picture shows which scanline
; each HDMA write lands on.

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf

*=0x008000
reset:
    sei
    clc
    xce
    sep #0x20
    lda #0x80  ; force blank while setting up
    sta.w 0x2100
    stz.w 0x2121  ; backdrop white
    lda #0xFF
    sta.w 0x2122
    lda #0x7F
    sta.w 0x2122
    stz.w 0x212C  ; no layers: the backdrop only
    stz.w 0x4300  ; mode 0, direct
    stz.w 0x4301  ; to $2100
    rep #0x20
    lda.w #bands
    sta.w 0x4302
    sep #0x20
    stz.w 0x4304
    lda #0x01
    sta.w 0x420C
loop:
    bra loop

bands:
    .for i := 1, 7 {
    .db 0x10, 0x0F
    .db 0x10, 0x00
    }
    .db 0x00

; Cartridge header
*=0x00FFC0
.ascii "KINTSUKI HDMA BANDS  "
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
