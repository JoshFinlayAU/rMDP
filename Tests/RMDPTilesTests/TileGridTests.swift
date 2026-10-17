import Testing
import Foundation
@testable import RMDPTiles

/// Heap luma canvas with rect painters — no CVPixelBuffer needed.
private final class Canvas {
    let w: Int, h: Int, bpr: Int
    let ptr: UnsafeMutablePointer<UInt8>
    init(_ w: Int, _ h: Int) { self.w = w; self.h = h; self.bpr = w
        ptr = .allocate(capacity: w * h); ptr.update(repeating: 16, count: w * h) }
    deinit { ptr.deallocate() }

    func twoColor(_ rect: (Int, Int, Int, Int)) {   // x0,y0,x1,y1 — few distinct luma
        for y in rect.1..<rect.3 { for x in rect.0..<rect.2 {
            ptr[y * bpr + x] = ((x ^ y) & 1) == 0 ? 16 : 235
        } }
    }
    func noise(_ rect: (Int, Int, Int, Int), seed: Int) {   // high colour count, changes per seed
        var s = UInt64(bitPattern: Int64(seed &* 2_654_435_761 &+ 1))
        for y in rect.1..<rect.3 { for x in rect.0..<rect.2 {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            ptr[y * bpr + x] = UInt8(truncatingIfNeeded: s)
        } }
    }
    func run(_ grid: TileGrid, frames: Int, fps: Int = 60, repaint: (Int) -> Void) {
        for f in 0..<frames { repaint(f)
            grid.update(luma: UnsafePointer(ptr), bytesPerRow: bpr, frameIndex: UInt32(f), fps: fps) }
    }
    func plane(_ grid: TileGrid, _ col: Int, _ row: Int) -> Plane {
        grid.states[grid.index(col: col, row: row)].plane
    }
}

@Test func staticTextIsCrisp_movingNoiseIsVideo() {
    let cv = Canvas(256, 256)                     // 4×4 tiles of 64
    let grid = TileGrid(width: 256, height: 256)
    cv.twoColor((0, 0, 128, 256))                 // left half: static, few colours
    cv.run(grid, frames: 20) { f in
        cv.noise((128, 0, 256, 256), seed: f)     // right half: fresh noise every frame
    }
    // Left half → crisp (few colours, no motion)
    for r in 0..<4 { for c in 0..<2 { #expect(cv.plane(grid, c, r) == .crisp) } }
    // Right half → video (sustained high motion, 8 connected tiles survive coherence)
    for r in 0..<4 { for c in 2..<4 { #expect(cv.plane(grid, c, r) == .video) } }
}

@Test func videoRegionDecaysToCrispWhenMotionStops() {
    let cv = Canvas(256, 256)
    let grid = TileGrid(width: 256, height: 256)
    cv.run(grid, frames: 20) { f in cv.noise((0, 0, 256, 256), seed: f) }   // all video
    #expect(cv.plane(grid, 2, 2) == .video)
    // Stop changing: same buffer, no repaint → hashes stable, change-rate decays.
    cv.run(grid, frames: 30) { _ in }
    for r in 0..<4 { for c in 0..<4 { #expect(cv.plane(grid, c, r) == .crisp) } }
}

@Test func isolatedMovingTileIsDemoted() {
    let cv = Canvas(256, 256)
    let grid = TileGrid(width: 256, height: 256)
    cv.twoColor((0, 0, 256, 256))                 // static crisp everywhere
    cv.run(grid, frames: 20) { f in cv.noise((0, 0, 64, 64), seed: f) }   // one tile flickers
    // Cluster size 1 < minClusterTiles(4) → demoted back to crisp.
    #expect(cv.plane(grid, 0, 0) == .crisp)
}

@Test func largeMovingClusterStaysVideo() {
    let cv = Canvas(256, 256)
    let grid = TileGrid(width: 256, height: 256)
    cv.twoColor((0, 0, 256, 256))
    cv.run(grid, frames: 20) { f in cv.noise((0, 0, 128, 128), seed: f) }  // 2×2 = 4 tiles
    for r in 0..<2 { for c in 0..<2 { #expect(cv.plane(grid, c, r) == .video) } }
}

@Test func colorCountIsExact() {
    let cv = Canvas(64, 64)
    let grid = TileGrid(width: 64, height: 64)
    cv.twoColor((0, 0, 64, 64))                   // exactly two luma values
    grid.update(luma: UnsafePointer(cv.ptr), bytesPerRow: cv.bpr, frameIndex: 0, fps: 60)
    #expect(grid.states[0].colorCount == 2)
}

@Test func dirtyRectNarrowingOnlyAnalysesDirtyTiles() {
    let cv = Canvas(256, 256)
    let grid = TileGrid(width: 256, height: 256)
    cv.twoColor((0, 0, 256, 256))
    let dirty: Set<Int> = [grid.index(col: 1, row: 1), grid.index(col: 2, row: 3)]
    let res = grid.update(luma: UnsafePointer(cv.ptr), bytesPerRow: cv.bpr,
                          frameIndex: 0, fps: 60, dirtyTiles: dirty)
    #expect(res.analyzed == 2)                    // only the two dirty tiles hashed
}

@Test func partialEdgeTilesDoNotCrash() {
    // 200×140 is not a multiple of 64 — right/bottom tiles are partial.
    let cv = Canvas(200, 140)
    let grid = TileGrid(width: 200, height: 140)
    #expect(grid.cols == 4 && grid.rows == 3)
    cv.twoColor((0, 0, 200, 140))
    let res = grid.update(luma: UnsafePointer(cv.ptr), bytesPerRow: cv.bpr, frameIndex: 0, fps: 60)
    #expect(res.analyzed == 12)
}
