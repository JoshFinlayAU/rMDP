---
name: crisp-plane
description: CRISP plane (RMDPCrisp) built & measured — lossless text desktop at 0.035–0.2 Mbit/s; scroll detection must feed the classifier
metadata:
  type: project
---

Built 2026-08-03. Draft §2.3 — lossless encoding of the classifier's `.crisp` tiles. `RMDPCrisp`
library (`CrispEncoder`/`CrispDecoder`/`CrispCache`/`ScrollDetector` + Palette/LZFSE primitives) +
`rmdp-crispbench` + 8 tests (all green). Headless, exactly verifiable. Full writeup:
`design/crisp-plane.md`.

**Encodings per changed crisp tile (cheapest exact):** REF (cache slot, ~5B) / PAL (≤16 luma
values → palette+packed indices) / RAW (LZFSE, or stored if incompressible). Plus frame-level
scroll: `ScrollDetector` (tile-row hashing) finds vertical offset; decoder shifts recon, only
revealed tile-rows sent. Uses Apple `Compression` framework (LZFSE) — **no external dependency**
(design's zstd → OS-native LZFSE).

**Measured bandwidth, lossless every frame (M4 Pro):**
- typing desktop: **73 B/frame = 0.035 Mbit/s** (28,000× under naive raw luma)
- reading-speed scroll (1 tile-row/frame): **411 B/frame = 0.198 Mbit/s** (5,000×)
- encode cost ~0.0ms typing, ~0.2ms/frame scroll @1080p (0.28ms @4K)

vs naive full-frame H.264 desktop = 15–25 Mbit/s regardless of content. This is the concrete proof
of the draft's "10–50× cheaper for real desktop work, better text everywhere."

**Two findings from building it:**
1. **Scroll detection must FEED the classifier (new §2.1↔§2.3 integration point).** Fast scroll
   through the raw classifier routed every tile to the VIDEO plane — shifting content spikes
   change-rate. A tile whose new content is an *old tile shifted* isn't motion. So scroll detection
   must run before change-rate classification and suppress the change signal for scroll-explained
   tiles, else reading-speed scroll gets wrongly sent as lossy video. Next refinement: wire
   `ScrollDetector` into `TileGrid.update`.
2. **Cache desync risk SOLVED by design:** the encoder dictates cache slots (sent with every
   record); decoder is a pure follower — can't desync. Simpler/stronger than the "deterministic
   LRU both ends + epoch byte" originally planned. Risk register downgraded High→Low.

Also: in-bench live `recon == truth` verify caught a real bug (64px scroll on non-multiple-of-64
height crossed a tile-row boundary) immediately — keep verifies in benches.

Scope: luma only (chroma reuses the machinery — follow-up); no trained LZFSE dictionary yet.
Next: wire scroll→classifier; then chroma; then integrate video plane + crisp plane end-to-end.
Related: [[classify-layer]], [[scroll-poc]], [[halo-algorithm-v0.1]].
