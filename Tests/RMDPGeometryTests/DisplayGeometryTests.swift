import Testing
@testable import RMDPGeometry

@Test func nonRetinaIsIdentity() {
    let g = DisplayGeometry(capturePixelW: 1920, capturePixelH: 1080,
                            contentPointW: 1920, contentPointH: 1080)
    let p = g.pixelToPoint(x: 640, y: 480)
    #expect(p.x == 640 && p.y == 480)
}

@Test func retina2xHalvesPixels() {
    // 1920×1080-point display captured at native 3840×2160 pixels.
    let g = DisplayGeometry(capturePixelW: 3840, capturePixelH: 2160,
                            contentPointW: 1920, contentPointH: 1080)
    #expect(g.scaleX == 0.5 && g.scaleY == 0.5)
    let p = g.pixelToPoint(x: 3000, y: 2000)
    #expect(p.x == 1500 && p.y == 1000)
}

@Test func roundTripsExactly() {
    for g in [DisplayGeometry(capturePixelW: 3840, capturePixelH: 2160, contentPointW: 1920, contentPointH: 1080),
              DisplayGeometry(capturePixelW: 1280, capturePixelH: 800, contentPointW: 2560, contentPointH: 1600),
              DisplayGeometry(capturePixelW: 1512, capturePixelH: 982, contentPointW: 1512, contentPointH: 982)] {
        for (x, y) in [(0.0, 0.0), (100.0, 200.0), (1200.0, 700.0)] {
            let pt = g.pixelToPoint(x: x, y: y)
            let back = g.pointToPixel(x: pt.x, y: pt.y)
            #expect(abs(back.x - x) < 1e-9 && abs(back.y - y) < 1e-9)
        }
    }
}

@Test func flippedRoundTripsForAppKitSpace() {
    let g = DisplayGeometry(capturePixelW: 3840, capturePixelH: 2160,
                            contentPointW: 1920, contentPointH: 1080)
    // capture pixel (top-left) → NSEvent point (bottom-left) → back
    let pt = g.pixelToPointFlipped(x: 0, y: 0)          // top-left pixel → top of screen
    #expect(pt.y == 1080)                                // bottom-left origin: top is max-Y
    let back = g.pointFlippedToPixel(x: pt.x, y: pt.y)
    #expect(abs(back.x) < 1e-9 && abs(back.y) < 1e-9)
}

@Test func naiveTransformErrorGrowsWithDistance() {
    // The bug: treating capture pixels as points on a 2× display.
    let g = DisplayGeometry(capturePixelW: 3840, capturePixelH: 2160,
                            contentPointW: 1920, contentPointH: 1080)
    func gap(_ x: Double, _ y: Double) -> Double {
        let correct = g.pixelToPoint(x: x, y: y)
        let naive = g.naivePixelToPoint(x: x, y: y)
        return abs(naive.x - correct.x)
    }
    #expect(gap(0, 0) == 0)             // no error at the origin
    #expect(gap(1920, 0) == 960)        // half the pixel offset, mid-screen
    #expect(gap(3840, 0) == 1920)       // grows with distance — the "worse further out" symptom
}
