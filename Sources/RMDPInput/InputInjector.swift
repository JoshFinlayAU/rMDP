import CoreGraphics
import ApplicationServices
import Foundation
import RMDPGeometry

/// Host-side input injection (§2.8): turns viewer input — in CAPTURE PIXELS — into `CGEvent`s.
///
/// Coordinates go through `DisplayGeometry`, the one tested transform; the cursor-offset field
/// bug (memory/cursor-offset-issue.md) was exactly this mapping done naively.
///
/// Needs the Accessibility TCC grant. Without it `CGEventPost` is silently swallowed — no error
/// at all — so check `isTrusted` up front and tell the user.
public final class InputInjector {
    private let geometry: DisplayGeometry
    private let displayOrigin: CGPoint
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown = Set<UInt8>()
    private var lastPoint: CGPoint
    /// Sub-pixel scroll remainders — trackpads send fractional deltas, CGEvent takes integers.
    private var scrollRemainder = (x: 0.0, y: 0.0)

    /// `streamWidth/Height`: the encoded stream size the viewer's coordinates are in.
    /// `displayBounds`: the captured display in global Quartz points (`CGDisplayBounds`).
    public init(streamWidth: Int, streamHeight: Int, displayBounds: CGRect) {
        geometry = DisplayGeometry(capturePixelW: streamWidth, capturePixelH: streamHeight,
                                   contentPointW: displayBounds.width, contentPointH: displayBounds.height)
        displayOrigin = displayBounds.origin
        lastPoint = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt if not yet granted.
    @discardableResult
    public static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    private func globalPoint(_ x: Float, _ y: Float) -> CGPoint {
        let px = min(max(Double(x), 0), Double(geometry.capturePixelW - 1))
        let py = min(max(Double(y), 0), Double(geometry.capturePixelH - 1))
        let p = geometry.pixelToPoint(x: px, y: py)
        return CGPoint(x: displayOrigin.x + p.x, y: displayOrigin.y + p.y)
    }

    public func mouseMove(x: Float, y: Float) {
        let p = globalPoint(x, y)
        lastPoint = p
        let (type, button): (CGEventType, CGMouseButton) =
            buttonsDown.contains(0) ? (.leftMouseDragged, .left)
            : buttonsDown.contains(1) ? (.rightMouseDragged, .right)
            : !buttonsDown.isEmpty ? (.otherMouseDragged, .center)
            : (.mouseMoved, .left)
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    /// `button`: 0 left, 1 right, 2+ other (NSEvent.buttonNumber numbering).
    public func mouseButton(_ button: UInt8, down: Bool, x: Float, y: Float, clickCount: UInt8) {
        let p = globalPoint(x, y)
        lastPoint = p
        postButton(button, down: down, at: p, clickCount: clickCount)
    }

    private func postButton(_ button: UInt8, down: Bool, at p: CGPoint, clickCount: UInt8) {
        if down { buttonsDown.insert(button) } else { buttonsDown.remove(button) }
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case 0: type = down ? .leftMouseDown : .leftMouseUp; cgButton = .left
        case 1: type = down ? .rightMouseDown : .rightMouseUp; cgButton = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; cgButton = CGMouseButton(rawValue: UInt32(button)) ?? .center
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        e.post(tap: .cghidEventTap)
    }

    /// Deltas in points (pixel-precise scrolling), already in the viewer's scroll direction.
    public func scroll(dx: Float, dy: Float) {
        scrollRemainder.x += Double(dx)
        scrollRemainder.y += Double(dy)
        let ix = Int32(scrollRemainder.x.rounded(.towardZero))
        let iy = Int32(scrollRemainder.y.rounded(.towardZero))
        scrollRemainder.x -= Double(ix)
        scrollRemainder.y -= Double(iy)
        guard ix != 0 || iy != 0 else { return }
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    /// Modifier keys arrive as their own key events; macOS models them as `flagsChanged`.
    static let modifierKeyCodes: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]

    /// `keyCode` is the macOS virtual key code (same on both ends). `flags` are
    /// `NSEvent.ModifierFlags` raw bits, which share CGEventFlags' layout.
    public func key(_ keyCode: UInt16, down: Bool, flags: UInt64) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        if Self.modifierKeyCodes.contains(keyCode) { e.type = .flagsChanged }
        e.flags = CGEventFlags(rawValue: flags & 0xFFFF_0000)   // device-independent modifier bits only
        e.post(tap: .cghidEventTap)
    }

    /// Release anything still held — call when the viewer disconnects, so a dropped connection
    /// mid-drag or mid-Cmd doesn't leave the host with a stuck button or modifier.
    public func releaseAll() {
        for b in buttonsDown { postButton(b, down: false, at: lastPoint, clickCount: 1) }
        buttonsDown.removeAll()
        for k in Self.modifierKeyCodes { key(k, down: false, flags: 0) }
    }
}
