; SFC LoROM that programs deterministic PPU state for `test_ppu_state.py`.
; Sets BG3 on the main screen, BG3VOFS = $1234, configures HDMA channel 5
; (DIRECT mode 2 → $2112) with a tiny table at WRAM $7E:9800. After NMI
; runs once, all registers are visible to the kintsuki PPU snapshot API.

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

    ; Disable NMI / IRQ — vectors are zeroed in this ROM and an NMI would
    ; jump to $0000 = chaos.
    lda.b #0x00
    sta.l 0x004200       ; NMITIMEN

    ; BGMODE = $01 (mode 1, all BG sizes 8x8). Lets BG1/BG2/BG3 all draw.
    lda.b #0x01
    sta.l 0x002105

    ; BG3SC: tilemap base $7000 word (32x32 plane). Bits 7..2 = base>>10.
    ; $7000 >> 10 = $1C → byte $70.
    lda.b #0x70
    sta.l 0x002109

    ; Main screen designation TM = $07 → BG1+BG2+BG3 main visible.
    lda.b #0x07
    sta.l 0x00212C

    ; Sub screen designation TS = $00.
    lda.b #0x00
    sta.l 0x00212D

    ; BG3VOFS double-write: $1234 (= +$34 then +$12).
    lda.b #0x34
    sta.l 0x002112
    lda.b #0x12
    sta.l 0x002112

    ; --- HDMA channel 5: BG3VOFS rolling demo ---
    ; DMAP5 ($4350) = $02: DIRECT mode, transfer mode 2 (2 bytes / scanline,
    ; one register).
    lda.b #0x02
    sta.l 0x004350
    ; BBAD5 ($4351) = $12 → write to $2112 (BG3VOFS).
    lda.b #0x12
    sta.l 0x004351

    ; A1Tx + A1Bx ($4352..$4354) = $7E:9800 source.
    rep #0x20
    lda.w #0x9800
    sta.l 0x004352      ; A1T5 lo+hi
    sep #0x20
    lda.b #0x7E
    sta.l 0x004354      ; A1B5

    ; Lay out a static HDMA table at $7E:9800.
    ; [count=$60 (96 sl), value=$1234] [count=$10 (16 sl), value=$5678]
    ; [count=$00 terminator]
    lda.b #0x60
    sta.l 0x7E9800
    rep #0x20
    lda.w #0x1234
    sta.l 0x7E9801
    sep #0x20
    lda.b #0x10
    sta.l 0x7E9803
    rep #0x20
    lda.w #0x5678
    sta.l 0x7E9805
    sep #0x20
    lda.b #0x00
    sta.l 0x7E9807

    ; Channel 5 registers are configured but HDMAEN stays off — otherwise
    ; HDMA fires every frame and overwrites BG3VOFS, hiding the direct
    ; $1234 write made above. Tests for HDMA-active behavior live in a
    ; separate ROM (Phase 5 dream-loop work).

    ; Sentinel byte at $7E:1700 so generic tests still pass.
    lda.b #0xAB
    sta.l 0x7E1700

idle:
    bra idle

; Cartridge header
*=0x00FFC0
.ascii "KINTSUKI PPU STATE   "
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
