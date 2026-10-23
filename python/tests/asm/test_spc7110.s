; SFC SPC7110 cart (cart type $F5) exercising the program / data ROM split:
;   the image is 1 MB of program ROM followed by 1 MB of data ROM. Reset
;   reads 4 bytes at data ROM offset $1234 through the data port ($4811-13
;   offset, $4818 mode 0, $4810 auto-increment) into WRAM $7E:2000, the same
;   4 bytes through the $D0 window into $7E:2004, then STPs.
;
; The assembler map is LoROM so `*=` names file offsets directly
; (file = bank * 0x8000 + addr - 0x8000); the code runs from $00:8000
; (HiROM, file 0x8000) and only uses its own labels for branches.

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf

*=0x018000
reset:
    sei
    clc
    xce                  ; native mode
    rep #0x30
    ldx.w #0x1FFF
    txs
    sep #0x30

    ; Data port: mode 0 (no adjust), offset $001234, 4 auto-increment reads.
    lda.b #0x00
    sta.l 0x004818
    lda.b #0x34
    sta.l 0x004811
    lda.b #0x12
    sta.l 0x004812
    lda.b #0x00
    sta.l 0x004813
    ldx.b #0x00
port:
    lda.l 0x004810
    sta.l 0x7E2000, x
    inx
    cpx.b #0x04
    bne port

    ; $D0-$DF show data ROM MB [$4831]: MB 0 after reset.
    ldx.b #0x00
window:
    lda.l 0xD01234, x
    sta.l 0x7E2004, x
    inx
    cpx.b #0x04
    bne window
    stp

; Cartridge header (file 0xFFC0)
*=0x01FFC0
.ascii "KINTSUKI SPC7110     "
.db 0x3A            ; map mode: HiROM + fast (SPC7110 carts use $3A)
.db 0xF5            ; cart type: SPC7110 + RAM + battery
.db 0x0B            ; 2 MB
.db 0x03            ; 8 KB SRAM
.db 0x00
.db 0x33
.db 0x00

*=0x01FFDC
.dw 0xFFFF
.dw 0x0000

*=0x01FFE4
.dw 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000

*=0x01FFF4
.dw 0x0000, 0x0000, 0x0000, 0x0000
.dw 0x8000          ; reset: $00:8000
.dw 0x0000

; Data ROM offset $1234 (file 0x101234): the marker the reads look for.
*=0x209234
.db 0xD5, 0x7A, 0x11, 0xC0

; Pad the image to 2 MB.
*=0x3FFFFF
.db 0x00
