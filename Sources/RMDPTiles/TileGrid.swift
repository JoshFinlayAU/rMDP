import Foundation

/// The CLASSIFY layer (draft §2.1) — the heart of HALO's data plane.
///
/// The screen is divided into fixed tiles. Each frame, tiles that changed are hashed, their
/// distinct-colour count and change-rate are updated, and each is routed to a **plane**:
///   - `.video`  — high motion → hardware H.264/HEVC
///   - `.crisp`  — low colour count or low motion → lossless tile cache / palette / zstd
///   - `.clean`  — unchanged and already delivered losslessly (nothing to send)
///
/// A spatial-coherence pass then grows `.video` tiles into clusters and demotes isolated ones,
/// so a single blinking cursor can't drag a text region onto the lossy video plane.
///
/// Every threshold is a named field on `TileConfig` — no magic numbers, per the design rules.
public enum Plane: UInt8, Sendable, CustomStringConvertible {
    case clean = 0, crisp = 1, video = 2
    public var description: String { self == .clean ? "clean" : self == .crisp ? "crisp" : "video" }
}

public struct TileConfig: Sendable {
    public var tileSize: Int = 64
    public var highMotion: Float = 8.0      // changes/sec → straight to video
    public var lowMotion: Float = 1.5       // above this + not palette-like → video
    public var paletteMax: Int = 32         // ≤ this many distinct luma values → crisp candidate
    public var changeRateAlpha: Float = 0.15
    public var minClusterTiles: Int = 4     // video clusters smaller than this are demoted
    public init() {}
}

public struct TileState: Sendable {
    public var hash: UInt64 = 0
    public var lastChangedFrame: UInt32 = 0
    public var changeRate: Float = 0        // EWMA, changes/sec
    public var colorCount: UInt8 = 0
    public var plane: Plane = .clean
    public var seen: Bool = false           // has this tile ever been hashed?
}

public struct ClassifyResult: Sendable {
    public var changed: Int = 0
    public var video: Int = 0
    public var crisp: Int = 0
    public var clean: Int = 0
    public var analyzed: Int = 0            // tiles actually hashed this frame
}

public final class TileGrid {
    public let cols: Int
    public let rows: Int
    public let width: Int
    public let height: Int
    public let config: TileConfig
    public private(set) var states: [TileState]

    public init(width: Int, height: Int, config: TileConfig = TileConfig()) {
        self.width = width
        self.height = height
        self.config = config
        let ts = config.tileSize
        self.cols = (width + ts - 1) / ts
        self.rows = (height + ts - 1) / ts
        self.states = [TileState](repeating: TileState(), count: cols * rows)
    }

    @inline(__always) public func index(col: Int, row: Int) -> Int { row * cols + col }

    /// Analyse a frame and classify its tiles.
    ///
    /// - `luma`: plane-0 pointer (row 0), rows `bytesPerRow` apart.
    /// - `dirtyTiles`: if non-nil, only these tile indices are re-hashed (the rest keep their
    ///   state but have their change-rate decayed). This is the dirty-rect fast path — pass the
    ///   tiles intersecting `SCStreamFrameInfo.dirtyRects`. nil = analyse every tile.
    @discardableResult
    public func update(luma: UnsafePointer<UInt8>, bytesPerRow: Int,
                       frameIndex: UInt32, fps: Int,
                       dirtyTiles: Set<Int>? = nil) -> ClassifyResult {
        let a = config.changeRateAlpha
        let fpsF = Float(fps)
        var result = ClassifyResult()

        for r in 0..<rows {
            for c in 0..<cols {
                let i = index(col: c, row: r)
                let isCandidate = dirtyTiles?.contains(i) ?? true

                if !isCandidate {
                    // Not in a dirty rect: assume unchanged, decay its change-rate.
                    states[i].changeRate *= (1 - a)
                    reclassify(i)
                    tally(i, into: &result)
                    continue
                }

                result.analyzed += 1
                let (h, colors) = analyze(col: c, row: r, luma: luma, bytesPerRow: bytesPerRow)
                var s = states[i]
                let changed = !s.seen || h != s.hash
                s.hash = h
                s.colorCount = colors
                s.seen = true
                if changed {
                    s.lastChangedFrame = frameIndex
                    result.changed += 1
                }
                // EWMA change-rate in changes/sec.
                s.changeRate = (1 - a) * s.changeRate + a * (changed ? fpsF : 0)
                states[i] = s
                reclassify(i)
                tally(i, into: &result)
            }
        }

        coherencePass(&result)
        return result
    }

    // MARK: - Per-tile analysis (single pass: FNV hash + distinct-luma count)

    private func analyze(col: Int, row: Int,
                         luma: UnsafePointer<UInt8>, bytesPerRow: Int) -> (UInt64, UInt8) {
        let ts = config.tileSize
        let x0 = col * ts, y0 = row * ts
        let x1 = min(x0 + ts, width), y1 = min(y0 + ts, height)
        var h: UInt64 = 0xcbf29ce484222325            // FNV-1a offset basis
        var present = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))   // 256-bit luma presence
        for y in y0..<y1 {
            let rowp = luma + y * bytesPerRow
            for x in x0..<x1 {
                let b = rowp[x]
                h = (h ^ UInt64(b)) &* 0x100000001b3
                let bit = UInt64(1) << UInt64(b & 63)
                switch b >> 6 {
                case 0: present.0 |= bit
                case 1: present.1 |= bit
                case 2: present.2 |= bit
                default: present.3 |= bit
                }
            }
        }
        let colors = present.0.nonzeroBitCount + present.1.nonzeroBitCount
                   + present.2.nonzeroBitCount + present.3.nonzeroBitCount
        return (h, UInt8(min(255, colors)))
    }

    // MARK: - Classification

    private func reclassify(_ i: Int) {
        var s = states[i]
        if !s.seen { s.plane = .clean; states[i] = s; return }
        let cr = s.changeRate
        let plane: Plane
        if cr > config.highMotion {
            plane = .video
        } else if Int(s.colorCount) <= config.paletteMax {
            plane = .crisp
        } else if cr > config.lowMotion {
            plane = .video
        } else {
            plane = .crisp
        }
        s.plane = plane
        states[i] = s
    }

    /// Grow `.video` tiles into clusters (4-connected) and demote clusters smaller than
    /// `minClusterTiles` back to `.crisp` — kills isolated video tiles inside text regions.
    private func coherencePass(_ result: inout ClassifyResult) {
        var visited = [Bool](repeating: false, count: cols * rows)
        var stack: [Int] = []
        for start in 0..<(cols * rows) where states[start].plane == .video && !visited[start] {
            // Flood-fill this video cluster.
            var cluster: [Int] = []
            stack.removeAll(keepingCapacity: true)
            stack.append(start); visited[start] = true
            while let n = stack.popLast() {
                cluster.append(n)
                let c = n % cols, r = n / cols
                for (dc, dr) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nc = c + dc, nr = r + dr
                    guard nc >= 0, nc < cols, nr >= 0, nr < rows else { continue }
                    let ni = nr * cols + nc
                    if !visited[ni] && states[ni].plane == .video {
                        visited[ni] = true; stack.append(ni)
                    }
                }
            }
            if cluster.count < config.minClusterTiles {
                for n in cluster { states[n].plane = .crisp }   // demote
            }
        }
        // Retally after coherence.
        result.video = 0; result.crisp = 0; result.clean = 0
        for s in states {
            switch s.plane { case .video: result.video += 1
                             case .crisp: result.crisp += 1
                             case .clean: result.clean += 1 }
        }
    }

    private func tally(_ i: Int, into result: inout ClassifyResult) {}   // planes counted in coherencePass
}
