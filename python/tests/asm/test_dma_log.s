; SFC LoROM exercising the kintsuki DMA transfer log:
;   reset configures GDMA channel 0 to copy 32 bytes from WRAM $7E:9000
;   to VRAM via VMDATA, but doesn't fire it. NMI is enabled. The main
;   loop waits for vblank; on first NMI we kick MDMAEN and STP.
;
; Expected after running ~2 frames:
;   - emulator halted (CPU executed STP).
;   - DMA log holds an entry with src=$7E9000, dst_reg=$18 (VMDATAL),
;     size=32, hits>=1.

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf
.map identifier=2 bank_range=0x7e, 0x7f addr_range=0x0000, 0xffff mask=0x10000 writable=1

*=0x008000
reset:
    sei
    clc
    xce                  ; native mode
    rep #0x30
    ldx.w #0x1FFF
    txs
    sep #0x20

    ; VMAIN = $80 (word access, +1 word increment after VMDATAH).
    lda.b #0x80
    sta.l 0x002115
    ; VMADDR = $0000 — DMA writes start at VRAM offset 0.
    rep #0x20
    lda.w #0x0000
    sta.l 0x002116
    sep #0x20

    ; Seed WRAM source buffer: 32 bytes of 0xAA at $7E:9000.
    ldx.w #0x0000
seed_loop:
    lda.b #0xAA
    sta.l 0x7E9000, x
    inx
    cpx.w #0x0020
    bne seed_loop

    ; DMAP0 ($4300) = $01: GDMA, mode 1 (2 regs alternating low/high)
    ; suits VMDATAL/VMDATAH at $2118/$2119.
    lda.b #0x01
    sta.l 0x004300
    ; BBAD0 ($4301) = $18 → start writes at VMDATAL ($2118).
    lda.b #0x18
    sta.l 0x004301
    ; A1T0/A1B0 ($4302..4304) = $7E:9000 source.
    rep #0x20
    lda.w #0x9000
    sta.l 0x004302
    sep #0x20
    lda.b #0x7E
    sta.l 0x004304
    ; DAS0 ($4305..4306) = 32 bytes.
    rep #0x20
    lda.w #0x0020
    sta.l 0x004305
    sep #0x20

    ; Enable NMI (bit 7) so the handler at FFEA fires on vblank.
    lda.b #0x80
    sta.l 0x004200

main:
    bra main             ; spin until NMI

; ----- NMI: kick the DMA once, then halt.
*=0x008100
nmi:
    sei
    ; Read RDNMI ($4210) low byte to ack the NMI flag.
    lda.l 0x004210
    ; Trigger MDMAEN bit 0 — channel 0 fires its 32-byte transfer.
    lda.b #0x01
    sta.l 0x00420B
    ; Halt so the test reads a deterministic stopping point.
    stp

; Cartridge header
*=0x00FFC0
.ascii "KINTSUKI DMA LOG     "
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

; Native-mode vectors at $FFE4..$FFEF: COP, BRK, ABORT, NMI, ?, IRQ.
*=0x00FFE4
.dw 0x0000, 0x0000, 0x0000
.dw nmi               ; NMI vector
.dw 0x0000, 0x0000

*=0x00FFF4
.dw 0x0000, 0x0000, 0x0000, 0x0000
.dw reset
.dw 0x0000

*=0x01FFFF
.db 0x00
