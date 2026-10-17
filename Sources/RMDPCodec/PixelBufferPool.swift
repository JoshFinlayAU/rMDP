import CoreVideo
import Foundation

/// IOSurface-backed NV12 pixel-buffer pool. IOSurface backing is what lets
/// VideoToolbox use the hardware media engine rather than copying through the CPU.
///
/// NV12 (`420YpCbCr8BiPlanarVideoRange`) means plane 0 is full-resolution luma —
/// exactly where the watermark lives.
public final class PixelBufferPool {
    public let width: Int
    public let height: Int
    private let pool: CVPixelBufferPool

    public enum PoolError: Error { case creationFailed(CVReturn) }

    public init(width: Int, height: Int, minBuffers: Int = 32) throws {
        self.width = width
        self.height = height

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],   // IOSurface-backed
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: minBuffers,
        ]
        var p: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttrs as CFDictionary,
                                             pixelAttrs as CFDictionary, &p)
        guard status == kCVReturnSuccess, let p else { throw PoolError.creationFailed(status) }
        self.pool = p
    }

    public func makeBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard status == kCVReturnSuccess, let pb else { throw PoolError.creationFailed(status) }
        return pb
    }
}

/// Run `body` with mutable access to the luma (plane 0) of a locked pixel buffer.
public func withLumaPlane<T>(_ pb: CVPixelBuffer,
                             _ body: (_ luma: UnsafeMutablePointer<UInt8>,
                                      _ width: Int, _ height: Int, _ bytesPerRow: Int) -> T) -> T {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
        .assumingMemoryBound(to: UInt8.self)
    let w = CVPixelBufferGetWidthOfPlane(pb, 0)
    let h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    return body(base, w, h, bpr)
}

/// Read-only variant.
public func withLumaPlaneReadOnly<T>(_ pb: CVPixelBuffer,
                                     _ body: (_ luma: UnsafePointer<UInt8>,
                                              _ width: Int, _ height: Int, _ bytesPerRow: Int) -> T) -> T {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
        .assumingMemoryBound(to: UInt8.self)
    let w = CVPixelBufferGetWidthOfPlane(pb, 0)
    let h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    return body(UnsafePointer(base), w, h, bpr)
}
