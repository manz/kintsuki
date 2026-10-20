// Standalone Swift test for TileSheet / TilePalette / HexDump (S-DD1
// viewer helpers). Compiled + run by Tests/run-swift-tests.sh (no XCTest).

import Foundation

@main
struct TileSheetTest {
    static var failed = 0

    static func check(_ ok: Bool, _ msg: String,
                      file: StaticString = #file, line: UInt = #line) {
        if !ok {
            print("FAIL [\(file):\(line)] \(msg)")
            failed += 1
        }
    }

    static func pixel(_ s: TileSheet, _ x: Int, _ y: Int) -> [UInt8] {
        let o = (y * s.width + x) * 4
        return Array(s.rgba[o..<o + 4])
    }

    static func testGreyscale() {
        let g2 = TilePalette.greyscale(.bpp2)
        check(g2[0] == (0, 0, 0) && g2[3] == (255, 255, 255), "2bpp ramp ends")
        check(g2[1] == (85, 85, 85), "2bpp ramp step")
        check(TilePalette.greyscale(.bpp8)[255] == (255, 255, 255), "8bpp ramp end")
    }

    static func testCGRAM() {
        // Entry 0 = pure red (BGR555 $001F), entry 1 = pure blue ($7C00).
        let pal = TilePalette.rgb(fromCGRAM: Data([0x1F, 0x00, 0x00, 0x7C]))
        check(pal[0] == (255, 0, 0), "CGRAM red")
        check(pal[1] == (0, 0, 255), "CGRAM blue")
        check(pal[2] == (0, 0, 0), "short CGRAM pads black")
    }

    static func testSheetGeometry() {
        // 3 full 2bpp tiles + 1 byte → 4 tiles, 2 wide → 16×16 px.
        let s = TileSheet(data: Data(count: 49), bpp: .bpp2, widthTiles: 2,
                          palette: TilePalette.greyscale(.bpp2))
        check(s.tileCount == 4, "partial tile counted")
        check(s.width == 16 && s.height == 16, "sheet dims \(s.width)x\(s.height)")
        check(s.cgImage != nil, "CGImage builds")
        let empty = TileSheet(data: Data(), bpp: .bpp4, widthTiles: 16,
                              palette: TilePalette.greyscale(.bpp4))
        check(empty.tileCount == 0 && empty.height == 8, "empty data renders one blank row")
    }

    static func testSheetPixels() {
        // 2bpp tile, row 0 plane0 = $80 → leftmost pixel index 1; rest 0.
        var tile = [UInt8](repeating: 0, count: 16)
        tile[0] = 0x80
        let s = TileSheet(data: Data(tile), bpp: .bpp2, widthTiles: 1,
                          palette: TilePalette.greyscale(.bpp2))
        check(pixel(s, 0, 0) == [85, 85, 85, 255], "index 1 decodes to grey")
        check(pixel(s, 1, 0) == [0, 0, 0, 255], "index 0 is opaque backdrop")
    }

    static func testHexDump() {
        let bytes: [UInt8] = Array(0x41...0x52) // 18 bytes: "A".."R"
        check(HexDump.rowCount(bytes.count) == 2, "row count")
        check(HexDump.row(bytes, 0) ==
              "000000  41 42 43 44 45 46 47 48 49 4A 4B 4C 4D 4E 4F 50  ABCDEFGHIJKLMNOP",
              "full row: \(HexDump.row(bytes, 0))")
        let last = HexDump.row(bytes, 1)
        check(last.hasPrefix("000010  51 52 ") && last.hasSuffix("  QR"), "partial row: \(last)")
        check(last.count == HexDump.row(bytes, 0).count - 14, "partial row keeps ASCII column aligned")
        check(HexDump.row([0x00, 0x7F], 0).hasSuffix(".."), "non-printables dotted")
    }

    static func main() {
        testGreyscale()
        testCGRAM()
        testSheetGeometry()
        testSheetPixels()
        testHexDump()
        if failed > 0 {
            print("\(failed) failure(s)")
            exit(1)
        }
        print("TileSheet: OK")
    }
}
