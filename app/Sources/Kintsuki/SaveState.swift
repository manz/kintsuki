import AppKit
import Foundation
import SwiftData

/// Per-ROM persisted save state. Blob is the raw `kintsuki_save_state` payload;
/// thumbnailPNG is the framebuffer at capture time, encoded as PNG.
@Model
final class SaveStateEntry {
    var id: UUID = UUID()
    var romPath: String = ""
    var name: String = ""
    var createdAt: Date = Date()
    @Attribute(.externalStorage) var blob: Data = Data()
    @Attribute(.externalStorage) var thumbnailPNG: Data = Data()

    init(romPath: String, name: String, blob: Data, thumbnailPNG: Data) {
        self.id = UUID()
        self.romPath = romPath
        self.name = name
        self.createdAt = .now
        self.blob = blob
        self.thumbnailPNG = thumbnailPNG
    }
}

/// PNG-encode a BGRA framebuffer (matches MetalRenderer's upload format).
/// Resamples to a fixed 256×224 (SNES picture aspect after 8:7 PAR
/// correction — close enough; cards display at 8:7) so hires modes
/// (512×448) and doubled-width (564×N) collapse to the same shape.
enum SaveStateThumbnail {
    static let outputWidth = 256
    static let outputHeight = 224

    static func png(fromBGRA data: Data, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, data.count == width * height * 4 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: data as CFData),
              let src = CGImage(width: width, height: height,
                                bitsPerComponent: 8,
                                bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: info),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        let outW = outputWidth, outH = outputHeight
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: outW * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let resized = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: resized)
        return rep.representation(using: .png, properties: [:])
    }
}
