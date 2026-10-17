import Metal
import QuartzCore
import CoreVideo
import Foundation

/// On-screen NV12 → RGB renderer for the viewer: draws a decoded frame straight into a
/// `CAMetalLayer` drawable. Same zero-copy path and BT.709 shader as `MetalRenderer` (which
/// stays the offscreen, read-back-able variant for the latency harness).
///
/// Thread-safe to call `draw` from the decoder's callback thread; draws are serialised on a
/// private queue so a slow present never stalls VideoToolbox.
public final class LayerRenderer: @unchecked Sendable {
    public let layer: CAMetalLayer
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache!
    private let drawQueue = DispatchQueue(label: "rmdp.render", qos: .userInteractive)
    /// Frames handed to `draw` but not yet presented. If the GPU/display falls behind we skip
    /// to the newest frame instead of queueing (queueing is latency).
    private var inFlight = 0
    private let lock = NSLock()
    public static let maxInFlight = 2

    public init(layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else {
            throw MetalRenderer.RenderError.noDevice
        }
        self.device = device
        self.queue = q
        self.layer = layer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        // Don't block forever if the window is occluded — drop the frame instead.
        layer.allowsNextDrawableTimeout = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)

        let library = try device.makeLibrary(source: MetalRenderer.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "rmdp_vmain")
        desc.fragmentFunction = library.makeFunction(name: "rmdp_fmain")
        desc.colorAttachments[0].pixelFormat = layer.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear; sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge; sdesc.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sdesc) else { throw MetalRenderer.RenderError.noDevice }
        sampler = s

        let ret = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard ret == kCVReturnSuccess else { throw MetalRenderer.RenderError.textureCacheFailed(ret) }
    }

    /// Draw and present one frame. `presented` fires when the GPU work completes (the
    /// "frame ready" timestamp for latency); nil if the frame was skipped.
    public func draw(_ pb: CVPixelBuffer, completion: @escaping (_ presented: Bool) -> Void) {
        lock.lock()
        if inFlight >= Self.maxInFlight { lock.unlock(); completion(false); return }
        inFlight += 1
        lock.unlock()
        drawQueue.async { [self] in
            let ok = encode(pb) { [self] in
                lock.lock(); inFlight -= 1; lock.unlock()
                completion(true)
            }
            if !ok { lock.lock(); inFlight -= 1; lock.unlock(); completion(false) }
        }
    }

    private func plane(_ pb: CVPixelBuffer, _ i: Int, _ f: MTLPixelFormat) -> MTLTexture? {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil, f,
                                                  CVPixelBufferGetWidthOfPlane(pb, i),
                                                  CVPixelBufferGetHeightOfPlane(pb, i), i, &t)
        return t.flatMap(CVMetalTextureGetTexture)
    }

    private func encode(_ pb: CVPixelBuffer, done: @escaping () -> Void) -> Bool {
        guard let luma = plane(pb, 0, .r8Unorm), let chroma = plane(pb, 1, .rg8Unorm),
              let drawable = layer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return false }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(luma, index: 0)
        enc.setFragmentTexture(chroma, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.addCompletedHandler { _ in done() }
        cb.commit()
        return true
    }
}
