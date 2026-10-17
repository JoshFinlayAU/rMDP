// rMDP CLASSIFY cost benchmark (headless).
//
// The design (§2.1) says hash tiles on the GPU so the CPU never walks 8M pixels. This measures
// the CPU cost of the tile analysis (FNV hash + distinct-luma count + classify + coherence) so we
// know whether the CPU path is viable and where the GPU becomes necessary — a real number, not an
// assumption. Two regimes: full-frame (every tile, worst case) and dirty-rect (typical desktop).

import Foundation
import RMDPMeasure
import RMDPTiles

func envInt(_ k: String, _ d: Int) -> Int { ProcessInfo.processInfo.environment[k].flatMap(Int.init) ?? d }

let width = envInt("RMDP_W", 3840)
let height = envInt("RMDP_H", 2160)
let iters = envInt("RMDP_ITERS", 200)
let dirtyPct = envInt("RMDP_DIRTY_PCT", 5)     // typical desktop: a few % of tiles change

print("rMDP CLASSIFY cost — \(width)x\(height), \(iters) iters")
let ts = 64
let cols = (width + ts - 1) / ts, rows = (height + ts - 1) / ts
print("tiles: \(cols)x\(rows) = \(cols*rows)\n")

// Synthetic frame: mostly static two-colour (text-like) with a noisy region.
let bpr = width
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bpr * height)
defer { buf.deallocate() }
func paint(seed: Int) {
    var s = UInt64(bitPattern: Int64(seed &* 2_654_435_761 &+ 1))
    for y in 0..<height {
        let row = buf + y * bpr
        for x in 0..<width {
            if x > width * 3 / 4 && y < height / 4 {      // top-right: noisy video-ish region
                s ^= s << 13; s ^= s >> 7; s ^= s << 17
                row[x] = UInt8(truncatingIfNeeded: s)
            } else {
                row[x] = ((x ^ y) & 1) == 0 ? 16 : 235    // text-like elsewhere
            }
        }
    }
}
paint(seed: 0)

// --- Full-frame analysis (worst case: every tile hashed) ---
let gridFull = TileGrid(width: width, height: height)
let full = LatencyRecorder(capacity: iters + 4)
for i in 0..<iters {
    if i % 4 == 0 { paint(seed: i) }              // change some content periodically
    let t0 = MonotonicClock.nowNanos()
    gridFull.update(luma: UnsafePointer(buf), bytesPerRow: bpr, frameIndex: UInt32(i), fps: 60)
    full.record(MonotonicClock.millis(from: t0, to: MonotonicClock.nowNanos()))
}
print("[full-frame — every tile hashed]")
print("  \(full.summarize())")

// --- Dirty-rect fast path (typical: only changed tiles hashed) ---
let gridDirty = TileGrid(width: width, height: height)
let nDirty = max(1, cols * rows * dirtyPct / 100)
let dirty = Set((0..<nDirty).map { ($0 &* 97) % (cols * rows) })
let dirtyRec = LatencyRecorder(capacity: iters + 4)
for i in 0..<iters {
    let t0 = MonotonicClock.nowNanos()
    gridDirty.update(luma: UnsafePointer(buf), bytesPerRow: bpr,
                     frameIndex: UInt32(i), fps: 60, dirtyTiles: dirty)
    dirtyRec.record(MonotonicClock.millis(from: t0, to: MonotonicClock.nowNanos()))
}
print("\n[dirty-rect fast path — \(dirtyPct)% of tiles (\(nDirty)) hashed]")
print("  \(dirtyRec.summarize())")

let budget = 1000.0 / 60.0
let fullP50 = full.summarize().p50
let dirtyP50 = dirtyRec.summarize().p50
print("\n[verdict] frame budget @60fps = \(String(format: "%.1f", budget)) ms")
print(String(format: "  full-frame p50 %.2f ms → %@", fullP50,
             fullP50 < budget ? "CPU viable even worst-case" : "GPU hashing needed for full-frame (§2.1)"))
print(String(format: "  dirty-path p50 %.2f ms → %@", dirtyP50,
             dirtyP50 < budget ? "comfortably fine — the common case is cheap" : "still heavy"))
