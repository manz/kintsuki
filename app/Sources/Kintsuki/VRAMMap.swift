import Foundation

/// The VRAM map `kintsuki_vram_map_snapshot` records: per VRAM word, the
/// layers the PPU fetched it for, the writes that landed in it and the
/// routine of the last one. Pure model so the standalone tests cover it.
struct VRAMMap {
    static let bgMap: [UInt16] = [0x1, 0x2, 0x4, 0x8]       // BG1-4 tilemap
    static let bgTiles: [UInt16] = [0x10, 0x20, 0x40, 0x80] // BG1-4 tiles
    static let objTiles: UInt16 = 0x100

    let reads: [UInt16]
    let writes: [UInt32]
    let writers: [UInt32]

    var words: Int { reads.count }

    /// VRAM cut where a word's reads change or it goes from written to not.
    func runs() -> [VRAMRun] {
        guard words > 0 else { return [] }
        var out: [VRAMRun] = []
        var start = 0
        for word in 1...words where word == words || !sameRun(word, start) {
            var total: UInt32 = 0
            var routines = Set<UInt32>()
            for w in start..<word where writes[w] > 0 {
                total &+= writes[w]
                routines.insert(writers[w])
            }
            out.append(VRAMRun(start: start, end: word - 1, reads: reads[start],
                               writes: total, writers: routines))
            start = word
        }
        return out
    }

    private func sameRun(_ a: Int, _ b: Int) -> Bool {
        reads[a] == reads[b] && (writes[a] > 0) == (writes[b] > 0)
    }

    /// "BG1 map", "BG3 tiles", "OBJ tiles": the layers `reads` has bits for.
    static func layerNames(_ reads: UInt16) -> [String] {
        var names: [String] = []
        for n in 0..<4 where reads & bgMap[n] != 0 { names.append("BG\(n + 1) map") }
        for n in 0..<4 where reads & bgTiles[n] != 0 { names.append("BG\(n + 1) tiles") }
        if reads & objTiles != 0 { names.append("OBJ tiles") }
        return names
    }
}

struct VRAMRun: Identifiable, Hashable {
    enum Kind: String { case read, dead, free }

    let start: Int       // word address
    let end: Int         // word address, inclusive
    let reads: UInt16
    let writes: UInt32
    let writers: Set<UInt32>

    var id: Int { start }
    var words: Int { end - start + 1 }
    /// Read when a layer drew from it, else dead when written, else free.
    var kind: Kind { reads != 0 ? .read : writes > 0 ? .dead : .free }
}

/// Where the PPU's registers put each enabled layer: a BG's tilemap from
/// BGnSC, the reach of its tiles from BGnNBA (1024 tiles at the mode's
/// depth), OBJ's two tile tables from OBSEL.
struct VRAMRegion: Hashable {
    let name: String
    let layer: Int       // 0-3 BG1-4, 4 OBJ
    let start: Int       // word address
    let end: Int         // word address, inclusive
}

enum VRAMLayout {
    /// Bits per pixel of BG1-4 in each mode; 0: the BG doesn't exist.
    static let depth: [[Int]] = [
        [2, 2, 2, 2], [4, 4, 2, 0], [4, 4, 0, 0], [8, 4, 0, 0],
        [8, 2, 0, 0], [4, 2, 0, 0], [4, 0, 0, 0], [0, 0, 0, 0],
    ]

    static func regions(bgmode: UInt8, sc: [UInt8], nba: [UInt8], obsel: UInt8,
                        layers: UInt8, words: Int = 0x8000) -> [VRAMRegion] {
        let last = words - 1
        let mode = Int(bgmode & 7)
        var out: [VRAMRegion] = []
        if mode == 7 {
            if layers & 1 != 0 {
                out.append(VRAMRegion(name: "BG1 mode 7", layer: 0, start: 0, end: 0x3FFF))
            }
        } else {
            for n in 0..<4 where layers & (1 << n) != 0 && depth[mode][n] > 0 {
                let screens = [1, 2, 2, 4][Int(sc[n] & 3)]
                let map = Int(sc[n] & 0xFC) << 8
                out.append(VRAMRegion(name: "BG\(n + 1) map", layer: n, start: map,
                                      end: min(last, map + 0x400 * screens - 1)))
                let tiles = Int(nba[n / 2] >> (n % 2 * 4) & 0x0F) << 12
                out.append(VRAMRegion(name: "BG\(n + 1) tiles", layer: n, start: tiles,
                                      end: min(last, tiles + 1024 * depth[mode][n] * 4 - 1)))
            }
        }
        if layers & 0x10 != 0 {
            let base = Int(obsel & 7) << 13
            let second = base + (Int(obsel >> 3 & 3) + 1) << 12
            out.append(VRAMRegion(name: "OBJ tiles", layer: 4, start: base & last,
                                  end: (base & last) + 0xFFF))
            out.append(VRAMRegion(name: "OBJ tiles 2", layer: 4, start: second & last,
                                  end: (second & last) + 0xFFF))
        }
        return out
    }
}

/// RGBA pixels, a word a pixel: each layer has its
/// colour (lighter for a map), a word read by several gets their mix,
/// dead words are orange and free ones near black.
enum VRAMMapImage {
    static let layerColors: [(UInt8, UInt8, UInt8)] = [
        (230, 80, 80), (80, 200, 90), (80, 140, 240), (230, 200, 60), (190, 90, 230),
    ]
    static let dead: (UInt8, UInt8, UInt8) = (255, 140, 0)
    static let free: (UInt8, UInt8, UInt8) = (28, 28, 28)

    static func color(reads: UInt16, written: Bool) -> (UInt8, UInt8, UInt8) {
        if reads == 0 { return written ? dead : free }
        var r = 0, g = 0, b = 0, n = 0
        for layer in 0..<5 {
            let isMap = layer < 4 && reads & VRAMMap.bgMap[layer] != 0
            let isTiles = layer < 4 ? reads & VRAMMap.bgTiles[layer] != 0
                                    : reads & VRAMMap.objTiles != 0
            guard isMap || isTiles else { continue }
            var c = layerColors[layer]
            if isMap && !isTiles {
                c = (UInt8((Int(c.0) + 255) / 2), UInt8((Int(c.1) + 255) / 2), UInt8((Int(c.2) + 255) / 2))
            }
            r += Int(c.0); g += Int(c.1); b += Int(c.2); n += 1
        }
        return (UInt8(r / n), UInt8(g / n), UInt8(b / n))
    }

    static func rgba(_ map: VRAMMap) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: map.words * 4)
        for w in 0..<map.words {
            let c = color(reads: map.reads[w], written: map.writes[w] > 0)
            out[w * 4] = c.0
            out[w * 4 + 1] = c.1
            out[w * 4 + 2] = c.2
        }
        return out
    }
}
