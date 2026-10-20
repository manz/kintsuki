import CoreGraphics
import Foundation

/// 256-entry RGB palettes for the tile decoders.
enum TilePalette {
    typealias RGB = (UInt8, UInt8, UInt8)

    /// CGRAM (256 × BGR555, little-endian) → 8-bit RGB. Short input
    /// leaves the missing entries black.
    static func rgb(fromCGRAM cgram: Data) -> [RGB] {
        var out = [RGB](repeating: (0, 0, 0), count: 256)
        let bytes = [UInt8](cgram)
        for i in 0..<min(256, bytes.count / 2) {
            let bgr = UInt16(bytes[i * 2]) | (UInt16(bytes[i * 2 + 1]) << 8)
            out[i] = (expand5(bgr), expand5(bgr >> 5), expand5(bgr >> 10))
        }
        return out
    }

    /// Linear ramp over the `bpp` index range (0 = black, max = white),
    /// for data that has no meaningful palette yet (e.g. a decompressed
    /// stream that never reached VRAM).
    static func greyscale(_ bpp: TileBpp) -> [RGB] {
        let levels = 1 << bpp.rawValue
        return (0..<256).map { i in
            let v = UInt8((min(i, levels - 1) * 255) / (levels - 1))
            return (v, v, v)
        }
    }

    private static func expand5(_ v: UInt16) -> UInt8 {
        let c = UInt8(v & 0x1F)
        return (c << 3) | (c >> 2)
    }
}

/// Lays an arbitrary byte buffer out as a grid of 8×8 tiles, `widthTiles`
/// per row. A trailing partial tile is zero-padded; index 0 and unused
/// cells render as palette entry `paletteBase` (opaque), so the result is
/// exportable as-is.
struct TileSheet {
    let width: Int
    let height: Int
    let tileCount: Int
    let rgba: [UInt8]

    init(data: Data, bpp: TileBpp, widthTiles: Int,
         palette: [TilePalette.RGB], paletteBase: Int = 0) {
        let cols = max(1, widthTiles)
        let tiles = (data.count + bpp.tileBytes - 1) / bpp.tileBytes
        let rows = max(1, (tiles + cols - 1) / cols)
        width = cols * 8
        height = rows * 8
        tileCount = tiles
        var px = TileSheet.backdrop(count: width * height,
                                    color: palette[paletteBase & 0xFF])
        TileSheet.blit(data: data, tiles: tiles, cols: cols, bpp: bpp,
                       palette: palette, paletteBase: paletteBase,
                       stride: width * 4, out: &px)
        rgba = px
    }

    var cgImage: CGImage? { cgImageFromRGBA(rgba: rgba, width: width, height: height) }

    private static func backdrop(count: Int, color: TilePalette.RGB) -> [UInt8] {
        var px = [UInt8](repeating: 0xFF, count: count * 4)
        for i in 0..<count {
            px[i * 4] = color.0
            px[i * 4 + 1] = color.1
            px[i * 4 + 2] = color.2
        }
        return px
    }

    /// `TileDecoder.blitTile` masks addresses by a power-of-two ring
    /// size, so the source is copied into a zero-padded power-of-two
    /// buffer first.
    private static func blit(data: Data, tiles: Int, cols: Int, bpp: TileBpp,
                             palette: [TilePalette.RGB], paletteBase: Int,
                             stride: Int, out: inout [UInt8]) {
        guard tiles > 0 else { return }
        var ring = [UInt8](repeating: 0, count: nextPow2(tiles * bpp.tileBytes))
        ring.replaceSubrange(0..<data.count, with: data)
        ring.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                for t in 0..<tiles {
                    TileDecoder.blitTile(vram: s, vramSize: src.count,
                                         charBase: 0, tileIndex: t, bpp: bpp,
                                         paletteRGB: palette, paletteBase: paletteBase,
                                         hflip: false, vflip: false,
                                         out: d, dstStride: stride,
                                         dstX: (t % cols) * 8, dstY: (t / cols) * 8)
                }
            }
        }
    }

    private static func nextPow2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}

/// Classic 16-bytes-per-row hex dump line: offset, bytes, ASCII gutter.
enum HexDump {
    static let bytesPerRow = 16

    static func rowCount(_ size: Int) -> Int {
        (size + bytesPerRow - 1) / bytesPerRow
    }

    static func row(_ bytes: [UInt8], _ row: Int) -> String {
        let lo = row * bytesPerRow
        let slice = bytes[lo..<min(lo + bytesPerRow, bytes.count)]
        let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        let pad = String(repeating: " ", count: (bytesPerRow - slice.count) * 3)
        let ascii = String(slice.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return String(format: "%06X  ", lo) + hex + pad + "  " + ascii
    }
}

func cgImageFromRGBA(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGImage(width: width, height: height,
                   bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: cs,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}
