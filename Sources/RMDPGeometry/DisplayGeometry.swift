import Foundation

/// The single coordinate transform between capture space and on-screen space — the "one tested
/// function, never inlined again" the design (CLAUDE.md gotchas, §2.8) insists on.
///
/// Three spaces, and every cursor/input offset bug is a confusion between them:
///   - **Capture pixels**: what `SCStream` delivers. Top-left origin. On a 2× Retina display a
///     1920×1080-*point* screen captures at 3840×2160 *pixels* (unless you downscale the stream).
///   - **Content points**: the display's (or viewer view's) point dimensions. Top-left origin for
///     Quartz/CGEvent; **bottom-left** for AppKit/`NSEvent.mouseLocation` (hence the flip helpers).
///
/// The transform is a pure ratio `contentPoints / capturePixels`, which absorbs the Retina scale
/// factor **and** any stream downscale uniformly — you never special-case `backingScaleFactor`.
/// The classic bug is assuming capture pixels == content points (scale 1): that yields an offset
/// of `pixel · (1 − scale)` which **grows with distance from the origin** — exactly the "substantial,
/// worse further out" symptom of a Retina mismatch.
public struct DisplayGeometry: Sendable, Equatable {
    public let capturePixelW: Int
    public let capturePixelH: Int
    public let contentPointW: Double
    public let contentPointH: Double

    public init(capturePixelW: Int, capturePixelH: Int,
                contentPointW: Double, contentPointH: Double) {
        precondition(capturePixelW > 0 && capturePixelH > 0)
        precondition(contentPointW > 0 && contentPointH > 0)
        self.capturePixelW = capturePixelW
        self.capturePixelH = capturePixelH
        self.contentPointW = contentPointW
        self.contentPointH = contentPointH
    }

    public var scaleX: Double { contentPointW / Double(capturePixelW) }
    public var scaleY: Double { contentPointH / Double(capturePixelH) }

    /// Capture pixel (top-left origin) → content point (top-left origin, e.g. Quartz/CGEvent).
    public func pixelToPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        (x * scaleX, y * scaleY)
    }

    /// Content point (top-left) → capture pixel (top-left). Inverse of `pixelToPoint`.
    public func pointToPixel(x: Double, y: Double) -> (x: Double, y: Double) {
        (x / scaleX, y / scaleY)
    }

    /// Capture pixel (top-left) → AppKit point (bottom-left origin, e.g. `NSEvent.mouseLocation`).
    public func pixelToPointFlipped(x: Double, y: Double) -> (x: Double, y: Double) {
        (x * scaleX, contentPointH - y * scaleY)
    }

    /// AppKit point (bottom-left) → capture pixel (top-left). Inverse of `pixelToPointFlipped`.
    public func pointFlippedToPixel(x: Double, y: Double) -> (x: Double, y: Double) {
        (x / scaleX, (contentPointH - y) / scaleY)
    }

    /// What a NAÏVE implementation (treats capture pixels as content points, scale 1) would place
    /// a capture pixel at — for showing the bug and its magnitude. The gap from `pixelToPoint`
    /// is the offset the user would see.
    public func naivePixelToPoint(x: Double, y: Double) -> (x: Double, y: Double) { (x, y) }
}
