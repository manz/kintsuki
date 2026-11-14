"""
Render switch exercise ROM: 40 8x8 sprites share lines 16-23, more than the 32 a line holds, so the PPU sets the range
over flag in $213E. Tile 0 at word $4000 is solid colour 1 (red), so the 32 sprites that make it are visible. Each NMI
copies $213E to FLAGS and steps the backdrop colour, so every frame's picture differs.
"""

.import "@std/snes/ppu"
.import "@std/snes/cpu"
.import "@std/snes/header"

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf
.map identifier=2 bank_range=0x7e, 0x7f addr_range=0x0000, 0xffff mask=0x10000 writable=1

ppu := (PPU_BASE as PPU)
cpu_regs := (CPU_REGS_BASE as CPU_REGS)
FLAGS = 0x7E0010
BACKDROP = 0x7E0012
OBJ_WORD = 0x4000
LINE_SPRITES = 40
OTHER_SPRITES = 128 - LINE_SPRITES

.alloc code at 0x008000 {
reset:
    sei
    clc
    xce
    rep #0x30
    ldx.w #0x1FFF
    txs
    sep #0x20
    lda.b #0x80
    sta.l ppu.INIDISP  ; force blank while VRAM, CGRAM and OAM are set up
    sta.l ppu.VMAIN
    lda.b #0x02  ; OBJ tiles at $4000, 8x8
    sta.l ppu.OBSEL
    rep #0x30
    lda.w #OBJ_WORD
    sta.l ppu.VMADDL
    ldx.w #0x0008
    lda.w #0x00FF
_tile:
    sta.l ppu.VMDATAL  ; 16-bit: plane 0 set, plane 1 clear
    dex
    bne _tile
    sep #0x20
    lda.b #0x81
    sta.l ppu.CGADD
    lda.b #0x1F
    sta.l ppu.CGDATA  ; OBJ palette 0 colour 1: red
    lda.b #0x00
    sta.l ppu.CGDATA
    sta.l ppu.OAMADDL
    sta.l ppu.OAMADDH
    rep #0x10
    ldx.w #LINE_SPRITES
    lda.b #0x00
_line:
    sta.l ppu.OAMDATA  ; x
    pha
    lda.b #16
    sta.l ppu.OAMDATA  ; y
    lda.b #0x00
    sta.l ppu.OAMDATA  ; tile 0
    lda.b #0x30
    sta.l ppu.OAMDATA  ; priority 3, palette 0
    pla
    clc
    adc.b #6
    dex
    bne _line
    ldx.w #OTHER_SPRITES
_others:
    lda.b #0x00
    sta.l ppu.OAMDATA
    lda.b #0xF0  ; below the screen
    sta.l ppu.OAMDATA
    lda.b #0x00
    sta.l ppu.OAMDATA
    sta.l ppu.OAMDATA
    dex
    bne _others
    ldx.w #0x0020
_high:
    sta.l ppu.OAMDATA  ; x bit 8 clear, small
    dex
    bne _high
    lda.b #0x10  ; OBJ only
    sta.l ppu.TM
    lda.b #0x0F
    sta.l ppu.INIDISP
    lda.b #NMITIMEN.nmi_enable.mask
    sta.l cpu_regs.NMITIMEN
    cli

main:
    bra main

nmi:
    rep #0x30
    pha
    sep #0x20
    lda.l cpu_regs.RDNMI  ; ack
    lda.l ppu.STAT77
    sta.l FLAGS
    lda.b #0x00
    sta.l ppu.CGADD
    lda.l BACKDROP
    clc
    adc.b #1
    sta.l BACKDROP
    sta.l ppu.CGDATA
    lda.b #0x00
    sta.l ppu.CGDATA
    rep #0x30
    pla
    rti
}

.alloc header at SNES_HEADER_BASE {
    .istruct SnesHeader {
        title = "KINTSUKI RENDER      "
        map_mode = 0x20
        rom_size = 0x09
        old_maker_code = 0x33
        checksum_complement = 0xFFFF
    }
}

.alloc vectors at SNES_VECTORS_BASE {
    .istruct SnesVectors {
        native = { nmi = nmi }
        emulation = { reset = reset }
    }
}

.alloc at 0x01FFFF size 1 {
    .db 0x00
}
