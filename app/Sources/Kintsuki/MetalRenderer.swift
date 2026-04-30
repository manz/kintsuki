import Foundation
import Metal
import MetalKit

/// MTKView delegate that uploads the latest emulator framebuffer into a
/// MTLTexture and draws it as a fullscreen quad with nearest-neighbor
/// scaling. ares packs its framebuffer as 0x00RRGGBB uint32 little-endian
/// → memory order BGRA → matches MTLPixelFormat.bgra8Unorm with no swizzle.
final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var texture: MTLTexture?
    private var texW: Int = 0
    private var texH: Int = 0

    weak var emulator: Emulator?

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60

        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        // Textured quad with aspect-correct letterbox. The vertex shader
        // scales the [-1,1] quad by a `scale` uniform pushed each draw.
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut vs(uint vid [[vertex_id]],
                       constant float2& scale [[buffer(0)]]) {
            float2 verts[6] = {
                {-1, -1}, { 1, -1}, {-1,  1},
                { 1, -1}, { 1,  1}, {-1,  1}
            };
            float2 uvs[6] = {
                {0, 1}, {1, 1}, {0, 0},
                {1, 1}, {1, 0}, {0, 0}
            };
            VOut o;
            o.pos = float4(verts[vid] * scale, 0, 1);
            o.uv  = uvs[vid];
            return o;
        }
        fragment float4 fs(VOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           sampler smp [[sampler(0)]]) {
            return tex.sample(smp, in.uv);
        }
        """
        guard let library = try? device.makeLibrary(source: src, options: nil) else { return nil }

        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction = library.makeFunction(name: "vs")
        pdesc.fragmentFunction = library.makeFunction(name: "fs")
        pdesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let pipe = try? device.makeRenderPipelineState(descriptor: pdesc) else { return nil }
        self.pipeline = pipe

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .nearest
        sdesc.magFilter = .nearest
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        guard let smp = device.makeSamplerState(descriptor: sdesc) else { return nil }
        self.sampler = smp

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private var drawTickCount = 0

    func draw(in view: MTKView) {
        guard let emu = emulator else { return }
        let w = Int(emu.fbWidth)
        let h = Int(emu.fbHeight)
        uploadIfNeeded(width: w, height: h, data: emu.framebuffer)
        drawTickCount += 1
        let logThis = drawTickCount % 120 == 0

        // Diagnose where we early-return.
        guard let descriptor = view.currentRenderPassDescriptor else {
            if logThis { NSLog("kintsuki: draw early-out, no renderPassDescriptor (size=\(view.drawableSize))") }
            return
        }
        guard let drawable = view.currentDrawable else {
            if logThis { NSLog("kintsuki: draw early-out, no drawable") }
            return
        }
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor) else {
            if logThis { NSLog("kintsuki: draw early-out, cmd/enc nil") }
            return
        }

        // Always run a draw call: clearColor only is presented even if
        // texture isn't ready, so the user sees the diagnostic clear color
        // instead of black-from-no-present.
        if let texture = texture {
            // Letterbox to native 8:7 PAR. ares performance PPU emits at
            // 564 × N (double-width for hires), the SNES picture aspect
            // (assuming square output pixels at 256 × 224) is 8:7.
            let drawSize = view.drawableSize
            let texAspect: Double = 8.0 / 7.0   // image aspect after PAR
            let viewAspect = drawSize.width / drawSize.height
            var sx: Float = 1, sy: Float = 1
            if viewAspect > texAspect {
                sx = Float(texAspect / viewAspect)
            } else {
                sy = Float(viewAspect / texAspect)
            }
            var scale = SIMD2<Float>(sx, sy)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        if logThis {
            NSLog("kintsuki: draw committed tick=\(drawTickCount) fb=\(w)x\(h) bytes=\(emu.framebuffer.count) tex=\(texture != nil) drawableSize=\(view.drawableSize)")
        }
    }

    private func uploadIfNeeded(width: Int, height: Int, data: Data) {
        guard width > 0, height > 0, data.count == width * height * 4 else { return }
        if texture == nil || texW != width || texH != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width, height: height,
                mipmapped: false)
            desc.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: desc)
            texW = width
            texH = height
        }
        guard let tex = texture else { return }
        let region = MTLRegionMake2D(0, 0, width, height)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                tex.replace(region: region, mipmapLevel: 0,
                            withBytes: base, bytesPerRow: width * 4)
            }
        }
    }
}
