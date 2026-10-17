import Foundation

/// Confidence-gated speculative scrolling — the Mosh idea applied to rMDP's pixels.
///
/// When the user scrolls, the delta is known *locally at the client*. Rather than wait a
/// round trip for the host's next frame, the client shifts the pixels it already has by that
/// delta and shows the result immediately; the host's authoritative frame arrives ~1 RTT later
/// and reconciles. The interior of a true scroll is exactly correct; only the newly-revealed
/// leading edge is unknown until the host frame lands.
///
/// Borrowed from Mosh verbatim: predictions are grouped in **epochs** (a run that's all-correct
/// or all-wrong); speculation is displayed only when **confident** (a prior prediction in the
/// epoch was confirmed); a wrong prediction **rolls back** to the authoritative frame within one
/// RTT and **increments the epoch** (drop confidence, re-confirm before showing again). We never
/// predict *content* — only the geometry (scroll offset) we already know.
public struct SpeculativeScroller {
    public let width: Int
    public let height: Int
    /// Fraction of interior pixels that must match for a prediction to count as "a scroll".
    public let confirmThreshold: Double

    public private(set) var confident: Bool = false
    public private(set) var epoch: Int = 0

    public init(width: Int, height: Int, confirmThreshold: Double = 0.999) {
        self.width = width
        self.height = height
        self.confirmThreshold = confirmThreshold
    }

    public struct Shifted {
        public let frame: [UInt8]          // W*H luma, row-major
        public let unknownRows: Range<Int> // rows the client couldn't fill (the revealed edge)
    }

    public struct Reconciliation {
        public let interiorMatch: Double   // fraction of shifted interior that matched host truth
        public let correct: Bool           // was it really a scroll?
        public let epoch: Int
        public let confident: Bool
    }

    /// Shift `frame` by `dy` rows (dy>0 = scroll down, content moves up). Pure; returns the
    /// speculative frame plus the row range the client had to leave unknown (the revealed edge).
    public func shift(_ frame: [UInt8], dy: Int) -> Shifted {
        precondition(frame.count == width * height)
        var out = [UInt8](repeating: 0, count: width * height)
        out.withUnsafeMutableBufferPointer { dst in
            frame.withUnsafeBufferPointer { src in
                for r in 0..<height {
                    let s = r + dy
                    if s >= 0 && s < height {
                        let d0 = r * width, s0 = s * width
                        for x in 0..<width { dst[d0 + x] = src[s0 + x] }
                    }
                    // else: row r is newly revealed → left as 0 (unknown)
                }
            }
        }
        let unknown: Range<Int>
        if dy > 0 { unknown = max(0, height - dy)..<height }        // revealed at bottom
        else if dy < 0 { unknown = 0..<min(height, -dy) }          // revealed at top
        else { unknown = 0..<0 }
        return Shifted(frame: out, unknownRows: unknown)
    }

    /// Reconcile a speculative frame against the host's authoritative frame for the same scroll
    /// position. Compares the interior (everything outside `unknownRows`). Updates confidence and
    /// epoch. Returns the outcome; on a misprediction the caller should adopt `authoritative`.
    public mutating func reconcile(speculative: [UInt8],
                                   authoritative: [UInt8],
                                   unknownRows: Range<Int>) -> Reconciliation {
        precondition(speculative.count == width * height)
        precondition(authoritative.count == width * height)
        var matched = 0, total = 0
        speculative.withUnsafeBufferPointer { spec in
            authoritative.withUnsafeBufferPointer { auth in
                for r in 0..<height {
                    if unknownRows.contains(r) { continue }
                    let base = r * width
                    for x in 0..<width {
                        total += 1
                        if spec[base + x] == auth[base + x] { matched += 1 }
                    }
                }
            }
        }
        let ratio = total > 0 ? Double(matched) / Double(total) : 1.0
        let correct = ratio >= confirmThreshold
        if correct {
            confident = true            // a confirmation in this epoch → show speculation live
        } else {
            confident = false           // misprediction → stop showing, re-confirm first
            epoch += 1
        }
        return Reconciliation(interiorMatch: ratio, correct: correct, epoch: epoch, confident: confident)
    }
}

/// Test/simulation oracle: an infinitely tall document the host renders viewports from. Content
/// varies per (x, y) so a shift's interior can be verified exactly and a content-change can't
/// masquerade as a scroll.
public struct ScrollDoc {
    public let width: Int
    public init(width: Int) { self.width = width }

    @inline(__always) public func value(x: Int, y: Int) -> UInt8 {
        // Distinct per row and per column; cheap hash.
        let h = UInt64(bitPattern: Int64(y &* 2_654_435_761 &+ x &* 40_503))
        return UInt8(truncatingIfNeeded: h ^ (h >> 11))
    }

    /// The authoritative viewport the host would send for a given scroll offset.
    public func viewport(offsetY: Int, height: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height)
        buf.withUnsafeMutableBufferPointer { p in
            for r in 0..<height {
                let base = r * width
                for x in 0..<width { p[base + x] = value(x: x, y: offsetY + r) }
            }
        }
        return buf
    }

    /// A frame that is NOT a scroll of the previous one (content changed) — to test rollback.
    public func scrambled(seed: Int, height: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height)
        for i in 0..<buf.count {
            let h = UInt64(bitPattern: Int64((i &+ seed) &* 2_246_822_519))
            buf[i] = UInt8(truncatingIfNeeded: h ^ (h >> 15))
        }
        return buf
    }
}
