---
name: scroll-poc
description: POC of confidence-gated speculative scroll (RMDPSpeculate) — works, quantified; leading-edge cost = scrollSpeed × RTT
metadata:
  type: project
---

Built 2026-08-02. Proves out the Mosh-derived speculative-scroll idea from [[mosh-ideas]] §2.8.
Code: `RMDPSpeculate` library (`SpeculativeScroller`, `ScrollDoc`) + `rmdp-scrollpoc` exe + 4
tests (all green). Full writeup: `design/scroll-poc.md`. Headless, exactly verifiable via oracle.

**Result: it works.** Client shifts already-decoded pixels by the locally-known scroll delta and
shows instantly; host frame reconciles ~1 RTT later.
- Interior of every shifted frame **pixel-exact** (verified incl. compounded flicks).
- Perceived latency **RTT → 0** (cold start costs one RTT once, then free until a misprediction).
- Misprediction (content changed, not scrolled) detected at reconcile (interior match collapses),
  snaps to host frame, drops confidence, epoch++ — self-heals in ≤1 RTT. Mosh's exact guarantee.
- **Zero added bandwidth**; a 1280×800 shift costs **0.32 ms** (« 16.7ms budget).

**The one cost — the leading edge — scales as `scrollSpeed × RTT` rows:**
- reading speed (400 rows/s) @ 114ms WAN: 46 rows (~2 lines) — negligible, clean win.
- brisk flick (1600) @ 114ms: 182 rows (23%) — interior instant, edge noticeable.
- fast flick (3000) @ 250ms: 750 rows (94%) — edge dominates, speculation breaks down.

**Design rules → main draft §2.8 + HALOConfig:** enable unconditionally for reading-speed scroll;
**cap speculative scroll rate on high-RTT links** (`maxSpeculativeScrollRows ≈ k / smoothedRTT`);
above the cap the interior still shifts instantly and only the runaway edge waits for the host.
Hold/blur the trailing edge rather than showing blank.

Next: wire `SpeculativeScroller` into the real viewer render path (needs the console/capture side,
[[latency-harness]] step 3) and measure perceived vs actual with the watermark. Same pattern
extends to window-drag. Related: [[halo-algorithm-v0.1]], [[mosh-ideas]].
