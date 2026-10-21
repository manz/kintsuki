"""
Timeline exercise ROM: the main loop calls `work` forever; each NMI calls `nmi_sub`, fires a 32-byte DMA (WRAM
$7E:9000 -> VMDATA) and returns with RTI; HDMA channel 1 writes COLDATA on lines 0-15. A timeline sees `work`
slices, an NMI slice per frame wrapping `nmi_sub`, a DMA slice and a 16-line HDMA slice per frame; the callstack and
profiler see the NMI as a frame.
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
hdma1 := (DMA_BASE + sizeof(DMAChannel) as DMAChannel)
HDMA_LINES = 16
SOURCE = 0x7E9000
BYTES = 0x20

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
    sta.l ppu.INIDISP  ; force blank: VRAM writes at any time
    sta.l ppu.VMAIN
    lda.b #0x01
    sta.l dma0.DMAP  ; mode 1: VMDATAL / VMDATAH
    lda.b #ppu.VMDATAL & 0xFF
    sta.l dma0.BBAD
    stz.w hdma1.DMAP  ; mode 0: one byte a line
    lda.b #ppu.COLDATA & 0xFF
    sta.l hdma1.BBAD
    rep #0x20
    lda.w #coldata_table & 0xFFFF
    sta.l hdma1.A1TL
    sep #0x20
    lda.b #coldata_table >> 16
    sta.l hdma1.A1B
    lda.b #0x02
    sta.l cpu_regs.HDMAEN
    lda.b #NMITIMEN.nmi_enable.mask
    sta.l cpu_regs.NMITIMEN
    cli

main:
    jsr.w work
    bra main

work:
    ldx.w #0x0100
_spin:
    dex
    bne _spin
    rts

nmi:
    rep #0x30
    pha
    phx
    sep #0x20
    lda.l cpu_regs.RDNMI  ; ack
    jsr.w nmi_sub
    rep #0x20
    lda.w #SOURCE & 0xFFFF
    sta.l dma0.A1TL
    lda.w #BYTES
    sta.l dma0.DASL
    lda.w #0x0000
    sta.l ppu.VMADDL
    sep #0x20
    lda.b #SOURCE >> 16
    sta.l dma0.A1B
    lda.b #0x01
    sta.l cpu_regs.MDMAEN
    rep #0x30
    plx
    pla
    rti

nmi_sub:
    nop
    nop
    rts

coldata_table:
    .db 0x80 | HDMA_LINES  ; repeat: a byte every line
    .for i := 0, HDMA_LINES {
    .db 0xE0 | i
    }
    .db 0x00
}

.alloc header at SNES_HEADER_BASE {
    .istruct SnesHeader {
        title = "KINTSUKI TIMELINE    "
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
