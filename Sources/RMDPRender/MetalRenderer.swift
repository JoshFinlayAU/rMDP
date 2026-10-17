import Metal
import CoreVideo
import Foundation

/// Zero-copy NV12 → RGB Metal renderer.
///
/// Decoded frames arrive as NV12 `CVPixelBuffer`s. We wrap their luma and chroma
/// planes as Metal textures via `CVMetalTextureCache` (no CPU copy), convert
/// BT.709 video-range YCbCr → RGB in a fragment shader, and render to an offscreen
/// target. The GPU command-buffer completion timestamp is when the frame is "ready
/// to present" — that's the render cost we add to the codec floor. (True photon needs
/// a light sensor for the final scanout; this is everything up to it.)
///
/// The shader is compiled at runtime from source so the package needs no `.metallib`
/// build integration.
public final class MetalRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache!
    private let target: MTLTexture
    public let width: Int
    public let height: Int

    public enum RenderError: Error {
        case noDevice
        case shaderCompileFailed(String)
        case pipelineFailed(String)
        case textureCacheFailed(CVReturn)
        case planeTextureFailed(CVReturn)
    }

    public init(width: Int, height: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        self.device = device
        self.width = width
        self.height = height
        guard let q = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = q

        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaderSource, options: nil) }
        catch { throw RenderError.shaderCompileFailed("\(error)") }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "rmdp_vmain")
        desc.fragmentFunction = library.makeFunction(name: "rmdp_fmain")
        desc.colorAttachments[0].pixelFormat = .rgba8Unorm
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineFailed("\(error)") }

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear; sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge; sdesc.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sdesc) else { throw RenderError.noDevice }
        self.sampler = s

        // Offscreen target — shared storage so readback is a plain pointer on Apple
        // Silicon's unified memory (cheap; no blit).
        let tdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        tdesc.usage = [.renderTarget, .shaderRead]
        tdesc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: tdesc) else { throw RenderError.noDevice }
        self.target = t

        let cvret = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard cvret == kCVReturnSuccess else { throw RenderError.textureCacheFailed(cvret) }
    }

    private func planeTexture(_ pb: CVPixelBuffer, plane: Int,
                             format: MTLPixelFormat) throws -> MTLTexture {
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var cvTex: CVMetalTexture?
        let ret = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil, format, w, h, plane, &cvTex)
        guard ret == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            throw RenderError.planeTextureFailed(ret)
        }
        return tex
    }

    /// Render one NV12 frame. `completion` fires when the GPU has finished — that's the
    /// "frame ready" timestamp for latency accounting.
    public func render(_ pb: CVPixelBuffer, completion: @escaping () -> Void) throws {
        let luma = try planeTexture(pb, plane: 0, format: .r8Unorm)
        let chroma = try planeTexture(pb, plane: 1, format: .rg8Unorm)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            throw RenderError.noDevice
        }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(luma, index: 0)
        enc.setFragmentTexture(chroma, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.addCompletedHandler { _ in completion() }
        cb.commit()
    }

    /// Read the rendered target back as luma (BT.709) for watermark verification.
    /// Not on the timed path — correctness check only.
    public func readbackLuma() -> (luma: [UInt8], width: Int, height: Int, bytesPerRow: Int) {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var luma = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Double(rgba[i * 4]), g = Double(rgba[i * 4 + 1]), b = Double(rgba[i * 4 + 2])
            luma[i] = UInt8(max(0, min(255, 0.2126 * r + 0.7152 * g + 0.0722 * b)))
        }
        return (luma, width, height, width)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut rmdp_vmain(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        float2 t[3] = { float2(0,1),  float2(2,1),  float2(0,-1) };
        VOut o; o.pos = float4(p[vid], 0, 1); o.uv = t[vid]; return o;
    }
    fragment float4 rmdp_fmain(VOut in [[stage_in]],
                               texture2d<float> lumaTex   [[texture(0)]],
                               texture2d<float> chromaTex [[texture(1)]],
                               sampler s [[sampler(0)]]) {
        float y  = lumaTex.sample(s, in.uv).r;
        float2 c = chromaTex.sample(s, in.uv).rg;
        // BT.709 video-range YCbCr -> RGB
        y = (y - 16.0/255.0) * (255.0/219.0);
        float cb = (c.r - 128.0/255.0) * (255.0/224.0);
        float cr = (c.g - 128.0/255.0) * (255.0/224.0);
        float r = y + 1.5748 * cr;
        float g = y - 0.1873 * cb - 0.4681 * cr;
        float b = y + 1.8556 * cb;
        return float4(saturate(r), saturate(g), saturate(b), 1.0);
    }
    """
}
