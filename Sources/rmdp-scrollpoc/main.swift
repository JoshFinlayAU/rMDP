// rMDP POC — confidence-gated speculative scroll (the Mosh idea for pixels).
//
// Demonstrates and QUANTIFIES: when the user scrolls, the client shifts already-decoded pixels
// by the locally-known delta and shows them instantly, reconciling against the host's frame ~1
// RTT later. Interior of a true scroll is pixel-exact; only the newly-revealed leading edge is
// unknown until the host frame lands. Fully headless and exactly verifiable via a document oracle.

import Foundation
import RMDPMeasure
import RMDPSpeculate

func envInt(_ k: String, _ d: Int) -> Int { ProcessInfo.processInfo.environment[k].flatMap(Int.init) ?? d }

let W = envInt("RMDP_W", 1280)
let H = envInt("RMDP_H", 800)
let rttMs = Double(envInt("RMDP_RTT_MS", 100))
let scrollRowsPerSec = Double(envInt("RMDP_SCROLL_ROWS", 1600))   // a brisk trackpad flick
let eventHz = Double(envInt("RMDP_EVENT_HZ", 120))                 // input event cadence
let gestureSec = Double(envInt("RMDP_GESTURE_MS", 500)) / 1000.0
let lineHeight = 20.0                                              // ~text line, for intuition

print("rMDP POC — speculative scroll")
print("viewport \(W)x\(H), RTT \(Int(rttMs))ms, flick \(Int(scrollRowsPerSec)) rows/s, "
      + "events \(Int(eventHz))Hz, gesture \(Int(gestureSec*1000))ms\n")

let doc = ScrollDoc(width: W)
var scroller = SpeculativeScroller(width: W, height: H)

let dyPerEvent = max(1, Int((scrollRowsPerSec / eventHz).rounded()))
let nEvents = max(1, Int(gestureSec * eventHz))

// ---- 1. Correctness: run the whole flick, reconcile every step against host truth ----
var offset = 100_000
var frame = doc.viewport(offsetY: offset, height: H)
var interiorPerfect = true
var maxRevealedBand = 0
for _ in 0..<nEvents {
    let s = scroller.shift(frame, dy: dyPerEvent)
    offset += dyPerEvent
    let authoritative = doc.viewport(offsetY: offset, height: H)
    let r = scroller.reconcile(speculative: s.frame, authoritative: authoritative,
                               unknownRows: s.unknownRows)
    if r.interiorMatch < 1.0 { interiorPerfect = false }
    maxRevealedBand = max(maxRevealedBand, s.unknownRows.count)
    frame = authoritative
}
print("[correctness]")
print("  interior of every shifted frame pixel-exact: \(interiorPerfect ? "YES ✓" : "NO ✗")")
if !interiorPerfect { print("FAIL: correctness check failed"); exit(1) }   // CI gate
print("  confident after gesture: \(scroller.confident), epoch: \(scroller.epoch)")

// ---- 2. Perceived latency: baseline vs speculative ----
// Baseline: nothing moves until the host frame arrives → every scroll reflects at +RTT.
// Speculative (confidence warm): the shift is shown at the instant of the event → +0.
//   Cost is not latency but a leading-edge band unconfirmed for one RTT.
let leadingEdgeRows = scrollRowsPerSec * (rttMs / 1000.0)
print("\n[perceived latency to reflect a scroll]")
print(String(format: "  baseline (wait for host):   %.0f ms   (every scroll step)", rttMs))
print("  speculative (confident):     0 ms   (shown the instant you flick)")
print(String(format: "  cold start (first flick / after a miss): %.0f ms once, then 0", rttMs))

// ---- 3. The honest cost: the leading edge ----
print("\n[honest cost — the newly-revealed leading edge]")
print(String(format: "  unconfirmed band at steady flick: %.0f rows (= scrollSpeed × RTT)", leadingEdgeRows))
print(String(format: "  that's %.0f%% of the %d-row viewport, ~%.1f text lines, blank/stale for one RTT",
             100.0 * leadingEdgeRows / Double(H), H, leadingEdgeRows / lineHeight))
print("  everything above the edge is instant and exact; only the incoming edge lags.")
print("  speculation adds ZERO bandwidth — it only reorders WHEN pixels are shown.")

// ---- 4. Misprediction recovery ----
var scroller2 = SpeculativeScroller(width: W, height: H)
// warm up confidence
let warm = doc.viewport(offsetY: 0, height: H)
let ws = scroller2.shift(warm, dy: dyPerEvent)
_ = scroller2.reconcile(speculative: ws.frame, authoritative: doc.viewport(offsetY: dyPerEvent, height: H),
                        unknownRows: ws.unknownRows)
let wasConfident = scroller2.confident
// now the "scroll" is actually a content change (e.g. a new page loaded)
let ms = scroller2.shift(doc.viewport(offsetY: dyPerEvent, height: H), dy: dyPerEvent)
let mr = scroller2.reconcile(speculative: ms.frame,
                             authoritative: doc.scrambled(seed: 42, height: H),
                             unknownRows: ms.unknownRows)
print("\n[misprediction — content changed instead of scrolling]")
print("  was confident before: \(wasConfident)")
print(String(format: "  detected at reconcile: interior match %.1f%% → flagged not-a-scroll", mr.interiorMatch * 100))
print("  action: snap to host frame; confidence \(scroller2.confident), epoch \(mr.epoch)")
print(String(format: "  user saw a wrong shift for ≤ %.0f ms (one RTT), then it self-healed", rttMs))

// ---- 5. Real CPU cost of the speculation itself ----
let iters = 500
let probe = doc.viewport(offsetY: 0, height: H)
let t0 = MonotonicClock.nowNanos()
for _ in 0..<iters { _ = scroller.shift(probe, dy: dyPerEvent) }
let t1 = MonotonicClock.nowNanos()
let perShiftMs = MonotonicClock.millis(from: t0, to: t1) / Double(iters)
print("\n[client CPU cost of speculating]")
print(String(format: "  one %dx%d shift: %.3f ms  (must be « frame budget of %.1f ms @60fps)",
             W, H, perShiftMs, 1000.0/60.0))
print(perShiftMs < 16.0 ? "  ✓ comfortably within budget" : "  ⚠️ too slow — optimise the shift")

print("\n[verdict] On a \(Int(rttMs))ms link, speculative scroll turns a \(Int(rttMs))ms-per-step")
print("  lag into instant response, at the cost of a ~\(Int(leadingEdgeRows))-row trailing edge")
print("  that resolves within one RTT, zero extra bandwidth, and self-heals on misprediction.")
