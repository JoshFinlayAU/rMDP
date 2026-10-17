# CRISP plane — built & measured (2026-08-03)

Draft §2.3. The other half of "text stays sharp": lossless encoding of the classifier's `.crisp`
tiles. `RMDPCrisp` (library, 8 tests) + `rmdp-crispbench`. Headless, exactly verifiable
(encode → decode → assert pixel-identical). Uses Apple's `Compression` framework (LZFSE) — **no
external dependency**, so the design's "zstd" becomes OS-native LZFSE here.

## What it does

Per changed `.crisp` tile, the encoder picks the cheapest **exact** encoding:

| Method | When | Cost |
|---|---|---|
| **REF** | tile's pixels already in the shared cache | slot index only (~5 B) |
| **PAL** | ≤16 distinct luma values (text, UI chrome) | palette + packed indices |
| **RAW** | anything else | LZFSE, or stored raw if incompressible |

Plus a **frame-level scroll**: `ScrollDetector` (tile-row hashing, Hume's technique) finds a
vertical offset; the decoder shifts its reconstruction first and only the newly-revealed tile-rows
are sent.

**Cache can't desync:** the encoder owns slot allocation and sends the slot with every record;
the decoder is a pure follower. On a hash hit the encoder verifies the cached pixels actually
match before emitting a REF (guards the rare FNV collision). Verified over 30 frames with forced
eviction (tiny cache) — reconstruction stayed pixel-exact every frame.

## Verified (8 tests, all green)

- **Pixel-exact reconstruction across all three methods** (the losslessness guarantee).
- Palette round-trips exactly and rejects >16-colour tiles; LZFSE round-trips exactly.
- A repeated tile becomes a **REF** — second frame is <¼ the first, ~5 B/tile.
- **Cache stays in sync** over many frames with eviction.
- Scroll detector finds the vertical offset; scroll shift + revealed-row records reconstruct exact.

## Bandwidth — the headline claim, measured

`rmdp-crispbench`, realistic synthetic desktop, **lossless every frame**:

| Scenario | bytes/frame | bitrate | vs naive raw luma |
|---|---|---|---|
| Typing desktop (caret blink, static page) | 73 B | **0.035 Mbit/s** | 28,000× cheaper |
| Reading-speed scroll (1 tile-row/frame) | 411 B | **0.198 Mbit/s** | 5,000× cheaper |

Encode cost is trivial: **~0.0 ms typing, ~0.2 ms/frame scrolling** at 1080p (0.28 ms at 4K). For
context: a naive full-frame H.264 desktop stream sits at 15–25 Mbit/s regardless of content. **A
text desktop through the crisp plane is ~0.04–0.2 Mbit/s and pixel-perfect** — this is exactly the
"10–50× cheaper for real desktop work, with better text everywhere" the draft predicted, now
measured, and it's the concrete reason rMDP beats a game-streamer on a desktop.

## Two findings from building it

1. **Scroll detection must FEED the classifier (new integration point, §2.1 ↔ §2.3).** The bench
   first tried fast scroll through the raw classifier — and every tile got routed to the **video
   plane**, because shifting content spikes each tile's change-rate. That's wrong: a tile whose
   new content is just an *old tile shifted* isn't "motion." So scroll detection must run **before**
   change-rate classification and suppress the change signal for tiles explained by the scroll,
   or reading-speed scrolling would be needlessly sent as lossy video. This is the next refinement
   — wire `ScrollDetector` output into `TileGrid.update`.
2. **The in-bench live verify earned its keep.** A first cut sent only the bottom tile-row on a
   64 px scroll; because 1080 isn't a multiple of 64, the revealed band crossed into the
   second-to-last tile-row and reconstruction broke — caught immediately by the frame-by-frame
   `recon == truth` check, not weeks later. Fix: resend every tile-row the revealed band touches.

## Scope / follow-ups

- **Luma only.** The identical machinery applies to the CbCr plane for full colour — a follow-up,
  not a design change (text on coloured backgrounds needs it eventually).
- **LZFSE, no trained dictionary yet.** The draft's zstd-with-macOS-UI-dictionary would shrink RAW
  tiles further; LZFSE-native is the dependency-free baseline. Measure a dictionary later.
- Wire scroll-into-classifier (finding 1); integrate with the real classifier so plane routing +
  crisp encoding compose in one pass over `TileGrid.states`.

## Run it

```bash
swift test --filter RMDPCrispTests
swift build -c release
./.build/release/rmdp-crispbench                    # 1080p typing + scroll
RMDP_W=3840 RMDP_H=2160 ./.build/release/rmdp-crispbench
```
