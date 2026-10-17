import VideoToolbox
import CoreMedia
import Foundation

/// Low-latency H.264 hardware encoder (VideoToolbox).
///
/// Configured per the rMDP transport research: low-latency rate control (Apple
/// Silicon supports it for H.264 *and* HEVC), no frame reordering (B-frames are a
/// latency bomb), real-time mode, and effectively no periodic IDRs. This is the
/// encoder half of the latency-floor measurement.
public final class H264Encoder {
    private let session: VTCompressionSession
    public let width: Int
    public let height: Int

    public enum EncoderError: Error {
        case sessionCreateFailed(OSStatus)
        case encodeFailed(OSStatus)
    }

    public init(width: Int, height: Int, bitrateBps: Int = 20_000_000) throws {
        self.width = width
        self.height = height

        // Ask specifically for the low-latency-capable encoder.
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!,
        ]

        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,          // using the per-frame block API instead
            refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let s else { throw EncoderError.sessionCreateFailed(status) }
        self.session = s

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 600 as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrateBps as CFNumber)
        // Prioritise latency over power savings.
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse!)
        // Pin colour explicitly — capture is configured BT.709 to match; mismatched defaults show
        // up as washed-out/oversaturated output (CLAUDE.md gotcha).
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Change the target bitrate on the live session (no teardown — CLAUDE.md: reconfigure via
    /// properties). Returns false if VideoToolbox refused it.
    @discardableResult
    public func setBitrate(_ bps: Int) -> Bool {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber) == noErr
    }

    /// Encode one frame. `completion` fires on VideoToolbox's queue with the
    /// compressed sample buffer (or nil on failure). `forceKeyframe` makes this frame an IDR —
    /// used for viewer join and loss recovery.
    public func encode(_ pixelBuffer: CVPixelBuffer,
                       pts: CMTime,
                       forceKeyframe: Bool = false,
                       completion: @escaping (CMSampleBuffer?) -> Void) throws {
        var infoFlags = VTEncodeInfoFlags()
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: &infoFlags,
            outputHandler: { status, _, sampleBuffer in
                completion(status == noErr ? sampleBuffer : nil)
            })
        guard status == noErr else { throw EncoderError.encodeFailed(status) }
    }

    /// Block until all queued frames have been emitted.
    public func finish() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }
}
