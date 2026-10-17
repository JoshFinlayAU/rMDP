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
        public let displayTimeNanos: UInt64   // capture presentation time
    }

    private var stream: SCStream?
    private let onFrame: (Frame) -> Void
    private let queue = DispatchQueue(label: "rmdp.capture", qos: .userInteractive)

    public enum CaptureError: Error {
        case noDisplay
        case notPermitted
    }

    public init(onFrame: @escaping (Frame) -> Void) {
        self.onFrame = onFrame
    }

    /// Start capturing the main display at up to `fps`.
    public func start(fps: Int = 60,
                      width: Int? = nil, height: Int? = nil,
                      completion: @escaping (Error?) -> Void) {
        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self else { return }
            if let error { completion(error); return }
            guard let display = content?.displays.first else {
                completion(CaptureError.noDisplay); return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = width ?? display.width
            cfg.height = height ?? display.height
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // NV12
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
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNanos = pts.isValid ? UInt64(max(0, pts.seconds) * 1e9) : MonotonicClock.nowNanos()

        onFrame(Frame(pixelBuffer: pb, status: status, contentRect: contentRect,
                      dirtyRects: dirty, displayTimeNanos: ptsNanos))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Surface upstream; the harness prints it.
        NSLog("rMDP capture stopped: \(error.localizedDescription)")
    }
}
