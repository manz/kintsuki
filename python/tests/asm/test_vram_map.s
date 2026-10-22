"""
VRAM map exercise ROM: BG1 (mode 1, 4bpp) draws tile 0 everywhere from a 32x32 map at word $1000 with its tiles at
$2000, and OBJ draws sprite 0 (tile 0, 8x8) at 16,16 with its tiles at $4000; the other sprites sit off screen. Each
NMI DMAs 32 bytes to word $3000, which no layer reads.
"""

.import "@std/snes/ppu"
.import "@std/snes/cpu"
.import "@std/snes/dma"
.import "@std/snes/header"

.map identifier=1 bank_range=0x00, 0x6f addr_range=0x8000, 0xffff mask=0x8000 mirror_bank_range=0x80, 0xcf
.map identifier=2 bank_range=0x7e, 0x7f addr_range=0x0000, 0xffff mask=0x10000 writable=1

ppu := (PPU_BASE as PPU)
cpu_regs := (CPU_REGS_BASE as CPU_REGS)
dma0 := (DMA_BASE as DMAChannel)
MAP_WORD = 0x1000
SOURCE = 0x7E9000
DEAD_WORD = 0x3000
BYTES = 0x20
SPRITES = 128

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
    sta.l ppu.INIDISP  ; force blank while VRAM and OAM are set up
    sta.l ppu.VMAIN
    lda.b #0x01
    sta.l ppu.BGMODE
    lda.b #(MAP_WORD >> 10) << 2
    sta.l ppu.BG1SC
    lda.b #0x02  ; BG1 tiles at $2000
    sta.l ppu.BG12NBA
    lda.b #0x02  ; OBJ tiles at $4000, 8x8
    sta.l ppu.OBSEL
    rep #0x30
    lda.w #MAP_WORD
    sta.l ppu.VMADDL
    ldx.w #0x0400
    lda.w #0x0000
_map:
    sta.l ppu.VMDATAL  ; 16-bit: a map entry for tile 0
    dex
    bne _map
    sep #0x20
    lda.b #0x00
    sta.l ppu.OAMADDL
    sta.l ppu.OAMADDH
    lda.b #16
    sta.l ppu.OAMDATA  ; sprite 0: x, y, tile, attributes
    sta.l ppu.OAMDATA
    lda.b #0x00
    sta.l ppu.OAMDATA
    sta.l ppu.OAMDATA
    ldx.w #SPRITES - 1
_sprites:
    lda.b #0x00
    sta.l ppu.OAMDATA
    lda.b #0xF0  ; below the screen
    sta.l ppu.OAMDATA
    lda.b #0x00
    sta.l ppu.OAMDATA
    sta.l ppu.OAMDATA
    dex
    bne _sprites
    ldx.w #0x0020
_high:
    sta.l ppu.OAMDATA  ; x bit 8 clear, small
    dex
    bne _high
    lda.b #0x01
    sta.l dma0.DMAP  ; mode 1: VMDATAL / VMDATAH
    lda.b #ppu.VMDATAL & 0xFF
    sta.l dma0.BBAD
    lda.b #0x11  ; BG1 + OBJ
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
    rep #0x20
    lda.w #SOURCE & 0xFFFF
    sta.l dma0.A1TL
    lda.w #BYTES
    sta.l dma0.DASL
    lda.w #DEAD_WORD
    sta.l ppu.VMADDL
    sep #0x20
    lda.b #SOURCE >> 16
    sta.l dma0.A1B
    lda.b #0x01
    sta.l cpu_regs.MDMAEN
    rep #0x30
    pla
    rti
}

.alloc header at SNES_HEADER_BASE {
    .istruct SnesHeader {
        title = "KINTSUKI VRAM MAP    "
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
