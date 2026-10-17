import VideoToolbox
import CoreMedia
import Foundation

/// Low-latency H.264 hardware decoder (VideoToolbox).
///
/// The decompression session is created lazily from the first sample buffer's format
/// description (which the encoder embeds). Output is NV12 so the luma plane can be
/// read the same way it was written — that's how the watermark survives the trip.
public final class H264Decoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMFormatDescription?

    public enum DecoderError: Error {
        case noFormatDescription
        case sessionCreateFailed(OSStatus)
        case decodeFailed(OSStatus)
    }

    public init() {}

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    private func ensureSession(for sampleBuffer: CMSampleBuffer) throws {
        guard session == nil else { return }
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw DecoderError.noFormatDescription
        }
        formatDesc = fmt

        // Request NV12 IOSurface-backed output — hardware path, luma readable.
        let imageAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmt,
            decoderSpecification: nil,
            imageBufferAttributes: imageAttrs as CFDictionary,
            outputCallback: nil,          // per-frame block API
            decompressionSessionOut: &s)
        guard status == noErr, let s else { throw DecoderError.sessionCreateFailed(status) }
        session = s
    }

    /// Decode one compressed sample. `completion` fires on VideoToolbox's queue with
    /// the decoded NV12 pixel buffer (or nil on failure).
    public func decode(_ sampleBuffer: CMSampleBuffer,
                       completion: @escaping (CVImageBuffer?) -> Void) throws {
        try ensureSession(for: sampleBuffer)
        guard let session else { throw DecoderError.sessionCreateFailed(-1) }

        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],                    // synchronous-ish; handler fires per frame
            infoFlagsOut: &infoFlags,
            outputHandler: { status, _, imageBuffer, _, _ in
                completion(status == noErr ? imageBuffer : nil)
            })
        guard status == noErr else { throw DecoderError.decodeFailed(status) }
    }

    public func finish() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }
}
