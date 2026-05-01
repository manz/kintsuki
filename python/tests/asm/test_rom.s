; Minimal SFC LoROM used by kintsuki's CI test suite.
;
; Boot to native mode, drop a sentinel byte at $7E1700 so the savestate
; roundtrip test can compare WRAM, enable NMI so writes hit the $4200
; MMIO block (exercising write callbacks), then idle in a WAI loop.
;
; Assembled with a816. Output is a 32 KB LoROM (the smallest size ares
; reliably auto-detects via heuristics).

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf
.map identifier=2 bank_range=0x7e, 0x7f addr_range=0x0000, 0xffff mask=0x10000 writable=1

*=0x008000
reset:
    sei
    clc
    xce                  ; switch to native mode
    rep #0x30            ; 16-bit A, X, Y
    ldx.w #0x1FFF
    txs

    ; Sentinel at $7E1700 — savestate roundtrip test compares this byte
    ; before and after save/load.
    sep #0x20
    lda.b #0xAB
    sta.l 0x7E1700

    ; Write to $4200 (NMITIMEN). Exercises the $4200..$420F write
    ; callback range used in test_write_callback. Leaves NMI disabled —
    ; just need at least one write inside the watched range.
    lda.b #0x00
    sta.l 0x004200

    ; Tight spin loop. WAI would deadlock here since this ROM doesn't
    ; enable any interrupt source and ares would tick the PPU forever
    ; without ever advancing the scheduler past the WAI.
idle:
    bra idle

; ---------- Cartridge header (LoROM at $00:FFC0) -----------------------
*=0x00FFC0
.ascii "KINTSUKI TEST ROM    "  ; 21-byte title, space-padded
.db 0x20                    ; map mode: LoROM, slow
.db 0x00                    ; ROM-only cart
.db 0x09                    ; 512 KB ROM size hint (heuristic accepts 8..14)
.db 0x00                    ; no SRAM
.db 0x01                    ; region: North America (NTSC)
.db 0x33                    ; dev id (anything non-zero is fine)
.db 0x00                    ; ROM version

*=0x00FFDC
.dw 0xFFFF                  ; checksum complement (placeholder)
.dw 0x0000                  ; checksum (placeholder)

; Native-mode vectors (unused by this test ROM).
*=0x00FFE4
.dw 0x0000                  ; COP
.dw 0x0000                  ; BRK
.dw 0x0000                  ; ABORT
.dw 0x0000                  ; NMI
.dw 0x0000                  ; reserved
.dw 0x0000                  ; IRQ

; Emulation-mode vectors. Only RESET matters at boot.
*=0x00FFF4
.dw 0x0000                  ; COP
.dw 0x0000                  ; reserved
.dw 0x0000                  ; ABORT
.dw 0x0000                  ; NMI
.dw reset                   ; RESET
.dw 0x0000                  ; IRQ / BRK

; ares heuristic refuses ROMs below 64 KB. Pad out to the end of
; bank $01 so the assembled file lands at exactly 64 KB.
*=0x01FFFF
.db 0x00
