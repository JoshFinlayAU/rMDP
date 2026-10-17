---
name: classify-layer
description: CLASSIFY layer (RMDPTiles) built & measured — CPU tile classification is viable at 4K, overturning the design's GPU-hashing assumption
metadata:
  type: project
---

Built 2026-08-03. Draft §2.1, the heart of HALO's data plane. `RMDPTiles` library
(`TileGrid`/`TileState`/`TileConfig`/`Plane`) + `rmdp-classifybench` + 7 tests (all green).
Headless-verifiable (operates on luma buffers). Full writeup: `design/classify-layer.md`.

**What it does:** 64×64 tile ledger; per dirty tile, one CPU pass computes FNV-1a hash +
distinct-luma count (256-bit presence bitmap); classifies by change-rate EWMA + colour count into
.video / .crisp / .clean; then a 4-connected coherence pass demotes video clusters < 4 tiles
(kills isolated flicker dragging text onto the lossy plane). All thresholds are named TileConfig
fields.

**Key finding — overturns a design assumption.** Draft §2.1 said "hash on the GPU so the CPU never
walks 8M pixels." Measured on M4 Pro, single-thread CPU:
- dirty-rect path (typical): **0.46 ms @4K, 0.11 ms @1080p** — the operating point, ~free.
- full-frame worst case: **8.4 ms @4K** (p99 11.8), 2.07 ms @1080p — inside the 16.7 ms budget.

→ **Ship CPU classification. GPU hashing is a deferred optimisation, not a prerequisite** (removes
a Metal-compute dependency from the initial data plane). Reach for GPU only above 4K or if classify
must share the frame with heavy CPU work. Don't run full-frame every frame (~50% of a core); the
dirty-rect path exists for that. Draft §2.1 + risk register updated.

**Tuning wart noted:** with changeRateAlpha=0.15 and instantaneous rate = fps-on-change, a single
change spikes the EWMA to ~9/s (just over highMotion=8), so a one-off change can read .video for a
frame before decaying. Coherence demotes isolated ones and it self-corrects fast; revisit when
tuning (lower α, or require N consecutive changes to promote).

Verified: static few-colour→crisp, sustained noise→video, video→crisp decay (~25 frames), isolated
demote vs 2×2 cluster kept, exact colour count, dirty-rect narrowing, partial edge tiles.

Next: crisp plane (§2.3) consumes this — REF/SCROLL/PAL/RAW tile encodings; scroll detection
(tile-row hashing) lives here and feeds [[scroll-poc]]; .video bounding boxes feed the
bounded-region encoder. Related: [[halo-algorithm-v0.1]], [[latency-harness]].
