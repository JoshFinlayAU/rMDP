import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation
import RMDPMeasure

/// ScreenCaptureKit wrapper: the `Capture` layer's entry point.
///
/// Delivers NV12 `CVPixelBuffer`s plus the `SCStreamFrameInfo` the adaptive design
/// depends on — frame status (`.complete`/`.idle`/`.blank`/`.suspended`), the content
/// rect, and dirty rects. Callers must skip non-`.complete` frames (a "frame" isn't
/// always new pixels) and can use dirtyRects to narrow the tile hash set.
///
/// Needs the Screen Recording TCC grant and a real console session with an attached
/// display — it will not deliver frames from a headless/SSH session.
public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    public struct Frame {
        public let pixelBuffer: CVPixelBuffer
        public let status: SCFrameStatus
        public let contentRect: CGRect
        public let dirtyRects: [CGRect]
        /// The frame's scheduled scanout time, in `MonotonicClock` ns. SCK usually
        /// delivers ~1ms BEFORE this, so `arrival - displayTimeNanos` is signed.
        public let displayTimeNanos: UInt64
    }

    private var stream: SCStream?
    private let onFrame: (Frame) -> Void
    private let queue = DispatchQueue(label: "rmdp.capture", qos: .userInteractive)

    /// mach ticks → ns (SCStreamFrameInfo.displayTime is in mach_absolute_time ticks).
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    public enum CaptureError: Error {
        case noDisplay
        case notPermitted
    }

    public init(onFrame: @escaping (Frame) -> Void) {
        self.onFrame = onFrame
    }

    /// Start capturing the main display at up to `fps`.
    ///
    /// Default size is the display's POINT size (a 2× downscale on Retina). Pass
    /// `nativeResolution: true` for backing pixels — what crisp text needs. Explicit
    /// `width`/`height` override both.
    public func start(fps: Int = 60,
                      width: Int? = nil, height: Int? = nil,
                      nativeResolution: Bool = false,
                      completion: @escaping (Error?) -> Void) {
        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self else { return }
            if let error { completion(error); return }
            guard let display = content?.displays.first else {
                completion(CaptureError.noDisplay); return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = nativeResolution ? Int(filter.pointPixelScale) : 1
            cfg.width = width ?? display.width * scale
            cfg.height = height ?? display.height * scale
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // NV12
            // Pin BT.709 end to end (encoder + renderer assume it) — never trust defaults to match.
            cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            cfg.colorSpaceName = CGColorSpace.itur_709
            cfg.queueDepth = 6
            cfg.showsCursor = false   // cursor is sent as metadata (design decision)

            do {
                let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = stream
                stream.startCapture(completionHandler: completion)
            } catch {
                completion(error)
            }
        }
    }

    public func stop(completion: @escaping () -> Void) {
        stream?.stopCapture { _ in completion() }
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Attachments carry status + geometry.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else { return }

        let statusRaw = attachments[.status] as? Int ?? SCFrameStatus.complete.rawValue
        let status = SCFrameStatus(rawValue: statusRaw) ?? .complete
        let contentRect = (attachments[.contentRect] as? [String: Any])
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        let dirty = (attachments[.dirtyRects] as? [[String: Any]])?.compactMap {
            CGRect(dictionaryRepresentation: $0 as CFDictionary)
        } ?? []
        // Prefer the compositor's displayTime (mach ticks); fall back to PTS (host clock,
        // same mach domain). Both share MonotonicClock's timebase.
        let displayNanos: UInt64
        if let ticks = attachments[.displayTime] as? UInt64 {
            let tb = Self.timebase
            displayNanos = ticks &* UInt64(tb.numer) / UInt64(tb.denom)
        } else {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            displayNanos = pts.isValid ? UInt64(max(0, pts.seconds) * 1e9) : MonotonicClock.nowNanos()
        }

        onFrame(Frame(pixelBuffer: pb, status: status, contentRect: contentRect,
                      dirtyRects: dirty, displayTimeNanos: displayNanos))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Surface upstream; the harness prints it.
        NSLog("rMDP capture stopped: \(error.localizedDescription)")
    }
}
