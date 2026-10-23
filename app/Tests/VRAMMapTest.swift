// Standalone Swift test for VRAMMap / VRAMLayout / VRAMMapImage (VRAM Map
// window model). Compiled + run by Tests/run-swift-tests.sh (no XCTest).

import Foundation

@main
struct VRAMMapTest {
    static var failed = 0

    static func check(_ ok: Bool, _ msg: String,
                      file: StaticString = #file, line: UInt = #line) {
        if !ok {
            print("FAIL [\(file):\(line)] \(msg)")
            failed += 1
        }
    }

    /// 8 words: 0-1 BG1 map, 2-3 written by $C0F157 only, 4-7 untouched,
    /// 6 also written by $808000.
    static func sample() -> VRAMMap {
        VRAMMap(reads: [1, 1, 0, 0, 0, 0, 0, 0],
                writes: [0, 0, 2, 2, 0, 0, 1, 0],
                writers: [0, 0, 0xC0F157, 0xC0F157, 0, 0, 0x808000, 0])
    }

    static func testRuns() {
        let runs = sample().runs()
        check(runs.map { [$0.start, $0.end] } == [[0, 1], [2, 3], [4, 5], [6, 6], [7, 7]], "run bounds")
        check(runs.map(\.kind) == [.read, .dead, .free, .dead, .free], "run kinds")
        check(runs[1].writes == 4 && runs[1].writers == [0xC0F157], "dead run writes + writers")
        check(VRAMMap(reads: [], writes: [], writers: []).runs().isEmpty, "empty map has no runs")
    }

    static func testLayerNames() {
        check(VRAMMap.layerNames(0x4 | 0x10 | 0x100) == ["BG3 map", "BG1 tiles", "OBJ tiles"],
              "maps, then tiles, then OBJ")
    }

    static func testLayout() {
        // Bahamut Lagoon's battle map: mode 1, BG1SC $49, BG2SC $50, BG3SC $58,
        // BG12NBA $00, BG34NBA $03, OBSEL $03, BG1-3 + OBJ on.
        let regions = VRAMLayout.regions(bgmode: 0x09, sc: [0x49, 0x50, 0x58, 0],
                                         nba: [0x00, 0x03], obsel: 0x03, layers: 0x17)
        let byName = Dictionary(uniqueKeysWithValues: regions.map { ($0.name, [$0.start, $0.end]) })
        check(byName["BG1 map"] == [0x4800, 0x4FFF], "64x32 map spans two screens")
        check(byName["BG2 map"] == [0x5000, 0x53FF], "32x32 map spans one")
        check(byName["BG1 tiles"] == [0x0000, 0x3FFF], "4bpp reach: 1024 tiles of 16 words")
        check(byName["BG3 tiles"] == [0x3000, 0x4FFF], "2bpp reach: 1024 tiles of 8 words")
        check(byName["OBJ tiles"] == [0x6000, 0x6FFF] && byName["OBJ tiles 2"] == [0x7000, 0x7FFF],
              "OBJ tables follow OBSEL")
        check(byName["BG4 map"] == nil, "disabled layer left out")
        let mode7 = VRAMLayout.regions(bgmode: 7, sc: [0, 0, 0, 0], nba: [0, 0], obsel: 0, layers: 1)
        check(mode7 == [VRAMRegion(name: "BG1 mode 7", layer: 0, start: 0, end: 0x3FFF)], "mode 7")
    }

    static func testColors() {
        check(VRAMMapImage.color(reads: 0, written: false) == VRAMMapImage.free, "free")
        check(VRAMMapImage.color(reads: 0, written: true) == VRAMMapImage.dead, "dead")
        check(VRAMMapImage.color(reads: 0x10, written: true) == VRAMMapImage.layerColors[0], "BG1 tiles")
        check(VRAMMapImage.color(reads: 0x1, written: false) == (242, 167, 167), "a map is lighter")
        let px = VRAMMapImage.rgba(sample())
        check(px.count == 32 && Array(px[8..<12]) == [255, 140, 0, 255], "rgba row")
    }

    static func main() {
        testRuns()
        testLayerNames()
        testLayout()
        testColors()
        if failed > 0 {
            print("\(failed) failure(s)")
            exit(1)
        }
        print("VRAMMap: OK")
    }
}
