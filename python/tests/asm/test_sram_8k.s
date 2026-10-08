; test_sram.s with an 8 KB SRAM: a second cart size for SRAM-mismatch tests. Used by
; test_kssf_footer.py to exercise the KSSF footer path (footer is only
; emitted when the bound cart has a non-zero SRAM region).

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf
.map identifier=2 bank_range=0x7e, 0x7f addr_range=0x0000, 0xffff mask=0x10000 writable=1

*=0x008000
reset:
    sei
    clc
    xce                  ; native mode
    rep #0x30            ; 16-bit A/X/Y
    ldx.w #0x1FFF
    txs

    sep #0x20            ; 8-bit A
    lda.b #0x00
    sta.l 0x004200       ; NMITIMEN off

idle:
    bra idle

; Cartridge header
*=0x00FFC0
.ascii "KINTSUKI SRAM 8K     "
.db 0x20            ; map mode: LoROM + fast
.db 0x02            ; cart type: ROM + SRAM
.db 0x09            ; ROM size = 1<<9 KB = 512 KB
.db 0x03            ; SRAM size byte: 1024 << 3 = 8 KB
.db 0x01            ; country (NTSC)
.db 0x33            ; publisher (use $33 = extended)
.db 0x00            ; ROM version

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
