# CLASSIFY layer — built & measured (2026-08-03)

Draft §2.1, the heart of HALO's data plane. `RMDPTiles` (library, 7 tests) + `rmdp-classifybench`.
Headless, fully verifiable (operates on luma buffers — no capture needed).

## What it does

Divides the frame into 64×64 tiles with persistent `TileState` (hash, change-rate EWMA, distinct-
luma count, plane). Each frame, dirty tiles are analysed in **one pass** (FNV-1a hash + 256-bit
luma-presence bitmap → distinct-colour count), then classified:

```
changeRate > highMotion(8/s)        → .video
else colorCount ≤ paletteMax(32)    → .crisp
else changeRate > lowMotion(1.5/s)  → .video
else                                → .crisp     (unseen → .clean)
```

Then a **4-connected coherence pass** grows `.video` clusters and demotes any smaller than
`minClusterTiles`(4) back to `.crisp` — so a blinking cursor or a lone flickering tile can't drag
a text region onto the lossy video plane. Every threshold is a named `TileConfig` field.

## Verified (7 tests, all green)

- Static few-colour region → `.crisp`; sustained noisy motion → `.video`.
- A `.video` region **decays to `.crisp`** within ~25 static frames once motion stops.
- Isolated moving tile (cluster < 4) **demoted** to `.crisp`; a 2×2 cluster **stays** `.video`.
- Distinct-colour count is exact (a 2-colour tile reports 2).
- Dirty-rect narrowing analyses **only** the dirty tiles.
- Non-multiple-of-64 frames (partial edge tiles) handled without crashing.

## Cost — and it overturns a design assumption

`rmdp-classifybench`, M4 Pro, single-threaded CPU:

| Resolution | full-frame (every tile) | dirty-rect (5% of tiles) |
|---|---|---|
| 1080p | 2.07 ms p50 | 0.11 ms p50 |
| 4K | 8.41 ms p50 (p99 11.8) | 0.46 ms p50 |

**The draft §2.1 said "hash on the GPU so the CPU never walks 8M pixels." The measurement says
that's premature.** CPU classification is viable even at **4K full-frame** (8.4 ms, inside the
16.7 ms budget), and the realistic **dirty-rect path is 0.46 ms at 4K / 0.11 ms at 1080p** —
essentially free.

**Revised guidance for §2.1:**
- Ship **CPU classification**. The dirty-rect path is the operating point and costs ~3% of one
  core at 4K; full-frame is only needed on scene cuts and still fits the budget.
- **GPU hashing is a deferred optimisation, not a prerequisite** — reach for it only if classify
  must share the frame with heavy CPU work, we go above 4K, or we want to free the core entirely.
  This removes a Metal-compute dependency from the initial data plane. Measure-before-optimise, as
  the design ethos demands.
- Caveat: running *full-frame every frame* would burn ~50% of a P-core continuously — don't; the
  dirty-rect fast path exists precisely so we don't.

## A tuning note surfaced by the model

With `changeRateAlpha = 0.15` and instantaneous rate = fps on change, a *single* change spikes the
EWMA to ~9/s — just over `highMotion`(8) — so a one-off change can read `.video` for a frame
before decaying. In practice the coherence pass demotes isolated ones and it decays within a frame
or two, and the refine queue restores quality; but it's a real tuning wart. Options when we tune:
lower α, require N consecutive changes to promote, or raise `highMotion`. Left as-is for now
(matches the design's stated constants; "this will be tuned a hundred times").

## API

`TileGrid(width:height:config:)` → `update(luma:bytesPerRow:frameIndex:fps:dirtyTiles:) ->
ClassifyResult`; read `states[index(col:row:)].plane`. The crisp plane, scroll detection, and
refine queue all consume this. `dirtyTiles` takes the set of tiles intersecting
`SCStreamFrameInfo.dirtyRects`.

## Run it

```bash
swift test --filter RMDPTilesTests
swift build -c release
./.build/release/rmdp-classifybench                    # 4K
RMDP_W=1920 RMDP_H=1080 ./.build/release/rmdp-classifybench
# knobs: RMDP_W RMDP_H RMDP_ITERS RMDP_DIRTY_PCT
```

## Next

The **crisp plane** (§2.3) consumes this directly: for `.crisp` tiles, encode via tile-cache
`REF` / scroll `SCROLL` / `PAL` / zstd `RAW`. Scroll detection (tile-row hashing) also lives here
and feeds both the crisp plane and the speculative-scroll POC. `.video` clusters' bounding boxes
feed the bounded-region encoder (§2.2).
