# POC — confidence-gated speculative scroll

**Built & verified 2026-08-02, headless.** `RMDPSpeculate` (library, 4 tests) + `rmdp-scrollpoc`
(executable). Proves out the Mosh-derived idea from `mosh-comparison.md` §2 and upgrades §2.8 of
the main draft from "designed" to "measured."

## The idea

When the user scrolls, the delta is known *at the client*. Instead of waiting a round trip for the
host's next frame, the client shifts the pixels it already has by that delta and shows them
instantly. The host's authoritative frame arrives ~1 RTT later and reconciles. A true scroll's
interior is pixel-exact; only the newly-revealed leading edge is unknown until the host frame
lands. Confidence/epoch machinery (from Mosh) gates display and handles mispredictions.

## What the POC proves (all verified against a document oracle, exactly)

- **Interior of every shifted frame is pixel-exact** — verified over a full 500ms flick, including
  compounded shifts (many deltas in flight before the first host frame returns). Unit tests assert
  `interiorMatch == 1.0`.
- **Perceived latency: RTT → 0.** Baseline (wait for host) reflects each scroll step after a full
  RTT; speculative reflects it the instant you flick. Cold start costs one RTT once (to confirm
  the interaction is a scroll), then it's free until a misprediction.
- **Misprediction self-heals.** When content changes instead of scrolling, reconcile sees interior
  match collapse (0.4%), flags not-a-scroll, snaps to the host frame, drops confidence, increments
  the epoch. The user saw a wrong shift for ≤1 RTT, then it corrected — Mosh's exact guarantee.
- **Zero extra bandwidth.** Speculation only reorders *when* pixels are shown; it sends nothing.
- **Client cost is trivial:** one 1280×800 shift = **0.32 ms**, far under the 16.7 ms frame budget.

## The honest cost, and how it scales

The only cost is the **leading edge**: a band of newly-revealed rows the client can't fill until
the host frame arrives. Its size is **`scrollSpeed × RTT`**:

| Scenario | RTT | scroll speed | leading edge | verdict |
|---|---|---|---|---|
| Reading a page (real Darwin WAN) | 114 ms | 400 rows/s | **46 rows (6%, ~2 lines)** | negligible — clear win |
| Brisk flick (real WAN) | 114 ms | 1600 rows/s | 182 rows (23%, ~9 lines) | interior instant; edge noticeable |
| Fast flick, poor link | 250 ms | 3000 rows/s | 750 rows (94%) | edge dominates — speculation breaks down |
| Brisk flick on LAN | 10 ms | 1600 rows/s | 16 rows (2%) | essentially free |

**Design rules this hands us:**

1. **Reading-speed scrolling is a clean win at every realistic RTT** — the common case (reading a
   doc, a web page, code) reveals content slower than the host can deliver, so the edge is a couple
   of lines. Enable speculation here unconditionally once confident.
2. **The edge cost is `scrollSpeed × RTT`** — so on high-RTT links, **cap the speculative scroll
   rate** (or hold/blur the trailing edge rather than showing blank) so a fast flick doesn't
   expose most of the viewport as unknown. `maxSpeculativeScrollRows = k / max(1, smoothedRTT)` in
   `HALOConfig`.
3. **Above the cap, fall back to baseline** (wait for host) for the portion that outruns delivery —
   the interior still shifts instantly; only the runaway edge waits.

## API (in `RMDPSpeculate`)

`SpeculativeScroller`: `shift(_:dy:) -> (frame, unknownRows)` (pure), `reconcile(speculative:
authoritative:unknownRows:) -> Reconciliation`, with `confident`/`epoch` state. `ScrollDoc` is the
oracle for tests/sim. This is real, reusable code — the viewer's render layer will call `shift` on
its last decoded frame on each scroll event and `reconcile` when the matching host frame arrives.

## Run it

```bash
swift test --filter RMDPSpeculateTests
swift build -c release
./.build/release/rmdp-scrollpoc
# knobs: RMDP_RTT_MS RMDP_SCROLL_ROWS RMDP_EVENT_HZ RMDP_GESTURE_MS RMDP_W RMDP_H
RMDP_RTT_MS=114 RMDP_SCROLL_ROWS=400 ./.build/release/rmdp-scrollpoc   # reading speed on real WAN
```

## Next

Wire `SpeculativeScroller` into the real viewer render path (step 3, console) so the shift is
applied to actual decoded frames on real scroll input, and measure perceived vs actual latency
with the watermark harness. The same pattern extends to window-drag (translate a known region).
