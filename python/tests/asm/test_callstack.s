; Tiny LoROM that drives a JSL → JSR → STP call chain so the kintsuki
; shadow callstack can be verified end-to-end:
;   reset → (JSL outer) → (JSR inner) → STP
; Expected snapshot at halt (deepest first):
;   [0] callsite=outer_call_jsl  target=outer  kind=JSL
;   [1] callsite=outer_call_jsr  target=inner  kind=JSR

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

outer_call_jsl:
    jsr.l outer          ; JSL — pushed return is right after this 4-byte op
    stp                  ; never reached — outer's chain halts the CPU

*=0x008100
outer:
    nop
outer_call_jsr:
    jsr.w inner          ; nested JSR so the snapshot has 2 frames
    rtl

*=0x008200
inner:
    nop
    stp                  ; halt here; CPU won't pop outer's RTL afterwards

; Cartridge header
*=0x00FFC0
.ascii "KINTSUKI CALLSTACK   "
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
