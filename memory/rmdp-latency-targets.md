---
name: rmdp-latency-targets
description: rMDP's latency/quality targets and the third-party measurements they're calibrated against
metadata:
  type: project
---

rMDP targets, WAN conditions (150ms RTT, 25 Mbit):

- **Motion-to-photon p95 ≤ 120ms over RTT/2.** Below ~150ms total, pointing feels attached to
  your hand; above ~250ms it feels like a video call of a computer.
- **Text pixel-exact within 400ms of a region going idle.**
- **2–8 Mbit for typical desktop work** (bandwidth is a constraint, not a goal).

Calibration points from published measurement — these are what "good" currently looks like, so
matching ~100ms is par, not a win. The win we're chasing is *quality at that latency*:

- Light-sensor measurement of a well-built H.264 4K desktop stream over 16ms RTT: **~99ms
  typing, ~113ms scrolling**. Crucially, encode/decode dominated — the 16ms network round trip
  was a small fraction of the ~70ms overhead. (Tristan Hume, 2022)
- Tuned WebRTC remote control at 1080p: **98ms mean on a good link, 159ms constrained**;
  breakdown showed 51ms processing + 46ms jitter buffer. Zeroing the jitter buffer was worth
  ~90ms at p50. (Hopp)
- Parsec claims **~7ms added on LAN**.

**Implication for the design:** the jitter buffer and the encoder — not the network — are where
latency is won or lost. Hence render-on-arrival by default, and bounded-region encode rather
than full-frame. See [[halo-algorithm-v0.1]].

Every hot-path change gets a before/after p50/p95/p99. Build the latency harness before the
optimisations — capture timestamp carried through to render, in-band watermark for true
end-to-end.
