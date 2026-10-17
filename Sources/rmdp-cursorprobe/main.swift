// rMDP cursor/geometry probe — run on a CONSOLE session (needs a real display).
//
// Diagnoses the "remote cursor doesn't match my cursor" offset Josh saw. It reads THIS machine's
// real display geometry (point size, backing scale → pixel size) and, as you move the mouse,
// shows where a correct viewer would draw the cursor (should sit exactly on it) vs where a NAÏVE
// viewer (treats capture pixels as points — the classic Retina bug) would draw it, and the gap.
//
// Move the cursor to the top-left, then centre, then bottom-right and watch the gap: if it GROWS
// with distance from the origin, it's the points/pixels scale bug; if it's CONSTANT, it's an
// origin flip or a display-origin offset. Paste the output back.

import AppKit
import RMDPGeometry

guard let screen = NSScreen.main else {
    print("no main screen — are you on a console session?"); exit(2)
}
let scale = screen.backingScaleFactor
let f = screen.frame                        // points, bottom-left origin, main screen at (0,0)
let ptW = Double(f.width), ptH = Double(f.height)
let pxW = Int(ptW * scale), pxH = Int(ptH * scale)

print("rMDP cursor/geometry probe")
print(String(format: "  display: %.0f×%.0f points, backingScale %.2f → %d×%d pixels (native capture)",
             ptW, ptH, scale, pxW, pxH))
print("  note: rmdp-capturetest currently sets the stream to POINT size (\(Int(ptW))×\(Int(ptH))),")
print("        i.e. a downscaled stream — that scale choice also feeds this transform.\n")

// The transform the viewer SHOULD use, for a native-pixel capture.
let geo = DisplayGeometry(capturePixelW: pxW, capturePixelH: pxH,
                          contentPointW: ptW, contentPointH: ptH)

print("Move the cursor slowly: top-left corner → centre → bottom-right corner.")
print("Watch 'naive gap'. Ctrl-C when done.\n")
// NB: never use %s in Swift String(format:) with a Swift String — it reads it as a C pointer and
// segfaults. Plain padded columns instead.
func col(_ s: String, _ w: Int) -> String { s.padding(toLength: w, withPad: " ", startingAt: 0) }
print(col("mouse(pt, btm-left)", 22) + col("host reports(px)", 22)
      + col("naive would draw(pt)", 22) + "naive gap(pt)")

var ticks = 0
while ticks < 120 {                          // ~30s at 4 Hz
    let m = NSEvent.mouseLocation            // points, bottom-left origin, global
    // Host reports the cursor in capture-pixel space (top-left origin):
    let hostPx = geo.pointFlippedToPixel(x: Double(m.x), y: Double(m.y))
    // Correct viewer redraw → point (bottom-left): equals the real cursor.
    let correct = geo.pixelToPointFlipped(x: hostPx.x, y: hostPx.y)
    // Naïve viewer: uses the pixel numbers AS points (the bug). In a bottom-left space that draws
    // at (hostPx.x, contentH - hostPx.y).
    let naiveX = hostPx.x, naiveY = ptH - hostPx.y
    _ = correct                              // correct redraw == real cursor (0 gap) by construction
    let dx = naiveX - Double(m.x), dy = naiveY - Double(m.y)
    let gapMag = (dx * dx + dy * dy).squareRoot()

    print(String(format: "(%6.0f,%6.0f)        (%7.0f,%7.0f)      (%7.0f,%7.0f)      %.0f",
                 Double(m.x), Double(m.y), hostPx.x, hostPx.y, naiveX, naiveY, gapMag))
    Thread.sleep(forTimeInterval: 0.25)
    ticks += 1
}
print("\ndone. If the gap grew with distance from a corner → points/pixels scale bug (scale \(scale)×).")
print("If it was ~constant → origin flip / display-origin offset. Either way the fix is the")
print("single DisplayGeometry transform (RMDPGeometry), now unit-tested.")
