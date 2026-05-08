import Foundation

/// SNES BG tile decoders. 2bpp / 4bpp / 8bpp, all 8x8 tiles, planar layout.
///
/// Plane layout per bpp (planes pair (p0,p1) interleaved by row, 2 bytes/row):
///   2bpp: 16 bytes  — planes 0,1
///   4bpp: 32 bytes  — planes 0,1 (rows 0..7), then 2,3 (rows 0..7)
///   8bpp: 64 bytes  — 0,1 then 2,3 then 4,5 then 6,7
///
/// Mode 7 is intentionally omitted — different format (256 8-bit indices,
/// no planes, byte-interleaved with tilemap), tracked separately.
enum TileBpp: Int {
    case bpp2 = 2, bpp4 = 4, bpp8 = 8

    /// Bytes per 8x8 tile.
    var tileBytes: Int { rawValue * 8 }

    /// Sub-palette stride (number of CGRAM entries per palette group).
    /// 8bpp ignores the tilemap palette field and uses the full palette.
    var paletteStride: Int {
        switch self {
        case .bpp2: return 4
        case .bpp4: return 16
        case .bpp8: return 256
        }
    }
}

/// 0x00RRGGBB palette entry (RGBA byte order in destination buffer is RGBA8888).
struct TileDecoder {
    /// Blit one 8x8 tile into `out` at (dstX, dstY). `out` is RGBA8888 with
    /// row stride `dstStride` (in bytes). Pixels with palette index 0 are
    /// drawn fully transparent so layers can stack visually.
    static func blitTile(vram: UnsafePointer<UInt8>, vramSize: Int,
                         charBase: Int, tileIndex: Int, bpp: TileBpp,
                         paletteRGB: [(UInt8, UInt8, UInt8)],
                         paletteBase: Int,
                         hflip: Bool, vflip: Bool,
                         out: UnsafeMutablePointer<UInt8>, dstStride: Int,
                         dstX: Int, dstY: Int) {
        let bytes = bpp.tileBytes
        // VRAM is a 64KB ring; tile bases wrap.
        let base = (charBase + tileIndex * bytes) & 0xFFFF
        // Fast path: tile entirely inside [0, 0x10000).
        for y in 0..<8 {
            let srcY = vflip ? (7 - y) : y
            let p01_lo = vram[(base + srcY * 2)     & 0xFFFF]
            let p01_hi = vram[(base + srcY * 2 + 1) & 0xFFFF]
            var p23_lo: UInt8 = 0, p23_hi: UInt8 = 0
            var p45_lo: UInt8 = 0, p45_hi: UInt8 = 0
            var p67_lo: UInt8 = 0, p67_hi: UInt8 = 0
            if bpp == .bpp4 || bpp == .bpp8 {
                p23_lo = vram[(base + 16 + srcY * 2)     & 0xFFFF]
                p23_hi = vram[(base + 16 + srcY * 2 + 1) & 0xFFFF]
            }
            if bpp == .bpp8 {
                p45_lo = vram[(base + 32 + srcY * 2)     & 0xFFFF]
                p45_hi = vram[(base + 32 + srcY * 2 + 1) & 0xFFFF]
                p67_lo = vram[(base + 48 + srcY * 2)     & 0xFFFF]
                p67_hi = vram[(base + 48 + srcY * 2 + 1) & 0xFFFF]
            }
            for x in 0..<8 {
                let srcX = hflip ? x : (7 - x)
                let mask: UInt8 = 1 << UInt8(srcX)
                var idx: UInt16 = 0
                if (p01_lo & mask) != 0 { idx |= 1 }
                if (p01_hi & mask) != 0 { idx |= 2 }
                if bpp != .bpp2 {
                    if (p23_lo & mask) != 0 { idx |= 4 }
                    if (p23_hi & mask) != 0 { idx |= 8 }
                }
                if bpp == .bpp8 {
                    if (p45_lo & mask) != 0 { idx |= 0x10 }
                    if (p45_hi & mask) != 0 { idx |= 0x20 }
                    if (p67_lo & mask) != 0 { idx |= 0x40 }
                    if (p67_hi & mask) != 0 { idx |= 0x80 }
                }
                let off = (dstY + y) * dstStride + (dstX + x) * 4
                if idx == 0 {
                    // Transparent — leave destination untouched.
                    continue
                }
                let palIdx = bpp == .bpp8 ? Int(idx) : (paletteBase + Int(idx))
                let c = paletteRGB[palIdx & 0xFF]
                out[off + 0] = c.0
                out[off + 1] = c.1
                out[off + 2] = c.2
                out[off + 3] = 0xFF
                _ = vramSize  // silence unused, asserts at boundary not needed (VRAM is 64KB ring)
            }
        }
    }
}

/// One decoded BG tilemap entry (16-bit cell).
///   bits  0..9   tile character index (10 bits → 0..1023)
///   bits 10..12  palette group (3 bits)
///   bit  13      priority
///   bit  14      hflip
///   bit  15      vflip
struct TilemapCell: Equatable {
    var tile: UInt16
    var palette: UInt8
    var priority: Bool
    var hflip: Bool
    var vflip: Bool

    init(raw: UInt16) {
        self.tile     = raw & 0x3FF
        self.palette  = UInt8((raw >> 10) & 0x07)
        self.priority = (raw & 0x2000) != 0
        self.hflip    = (raw & 0x4000) != 0
        self.vflip    = (raw & 0x8000) != 0
    }
}

/// Plane dimensions encoded in BGxSC bits 1..0.
enum TilemapSize {
    case s32x32, s64x32, s32x64, s64x64

    init(bgsc: UInt8) {
        switch bgsc & 0x03 {
        case 1: self = .s64x32
        case 2: self = .s32x64
        case 3: self = .s64x64
        default: self = .s32x32
        }
    }

    var widthCells: Int  { (self == .s64x32 || self == .s64x64) ? 64 : 32 }
    var heightCells: Int { (self == .s32x64 || self == .s64x64) ? 64 : 32 }
    var subPlanes: Int   { (widthCells / 32) * (heightCells / 32) }
}

/// Locate a cell within the multi-sub-plane VRAM layout. Each 32x32
/// sub-plane is 1024 words = 2048 bytes contiguous in VRAM; sub-planes
/// are concatenated row-major.
func tilemapCellByteOffset(size: TilemapSize, mapBaseByte: Int,
                           row: Int, col: Int) -> Int {
    let subW = (size.widthCells / 32)
    let subRow = row / 32
    let subCol = col / 32
    let subIdx = subRow * subW + subCol
    let localRow = row % 32
    let localCol = col % 32
    return mapBaseByte + subIdx * 0x800 + (localRow * 32 + localCol) * 2
}
