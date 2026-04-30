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

        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        // Inline shader: textured fullscreen quad.
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut vs(uint vid [[vertex_id]]) {
            float2 verts[6] = {
                {-1, -1}, { 1, -1}, {-1,  1},
                { 1, -1}, { 1,  1}, {-1,  1}
            };
            float2 uvs[6] = {
                {0, 1}, {1, 1}, {0, 0},
                {1, 1}, {1, 0}, {0, 0}
            };
            VOut o;
            o.pos = float4(verts[vid], 0, 1);
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

    func draw(in view: MTKView) {
        guard let emu = emulator else { return }
        uploadIfNeeded(width: Int(emu.fbWidth), height: Int(emu.fbHeight),
                       data: emu.framebuffer)
        guard let texture = texture,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
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
