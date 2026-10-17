# Latency harness — draft step 2

**Built 2026-08-02 · M4 Pro, macOS 26.5.2, Swift 6.3.3 (package in Swift 5 language mode)**

The measurement backbone every later optimisation is argued against. Lives in the real rMDP
SPM package, not a spike — it's permanent infrastructure.

## What it is

Three pieces:

- **`RMDPMeasure`** (pure, unit-tested, no framework deps)
  - `MonotonicClock` — one ns time source (`DispatchTime.uptimeNanoseconds`) carried through the
    pipeline so latency is measured, not guessed.
  - `LatencyRecorder` — fixed-capacity, single-producer, allocation/lock-free-on-record ring
    buffer; `summarize()` gives mean/p50/p95/p99/min/max off-thread. Honours the hot-path rules.
  - `WatermarkCodec` — encodes a 64-bit value (a capture-time monotonic timestamp) into the luma
    plane as a strip of high-contrast blocks, and reads it back after the frame has been through
    the codec. Preamble-validated so blank/garbage frames return nil rather than a wrong number.
- **`RMDPCodec`** — low-latency `H264Encoder` / `H264Decoder` (VideoToolbox, block-based API) and
  an IOSurface-backed NV12 `PixelBufferPool`. Encoder config is the research spec: low-latency
  rate control, no frame reordering, real-time, effectively no periodic IDRs.
- **`rmdp-latencybench`** — stamps a timestamp into each synthetic frame, runs it through the real
  hardware encoder+decoder, reads the timestamp back, records `now − stamp`. **No screen capture,
  so no TCC grant** — runs anywhere.

## Why this method

- The research was blunt that **encode/decode, not network, dominates** desktop-stream latency
  (Hume measured it as the bulk of ~70ms at 4K). So the first thing worth measuring, before any
  capture or transport, is the codec floor on *this* hardware.
- **In-band watermark** = the black-box technique (Hopp used it): it captures real encode+decode
  time, and when later detected off an actual display it will also capture capture+scanout
  latency that a timestamp merely attached to a buffer would miss. It survives H.264 because luma
  is full-resolution even in 4:2:0 and the blocks dwarf a macroblock. **Validated: 100% watermark
  recovery through a real H.264 round-trip, including a ±20 simulated-quantisation unit test.**

## What it measures (and doesn't)

The number is **embed → encode-queue → encode → decode-queue → decode**. It is **not** full
motion-to-photon — there's no capture and no display scanout yet. Those stages get added when the
real pipeline (draft step 3) plugs into this same harness. This is the codec floor.

## Baseline — H.264 encode→decode latency, M4 Pro (300 frames, 30 warmup excluded)

| Resolution | Content | Latency p50 / p95 / p99 | Bitstream |
|---|---|---|---|
| 1080p | low-entropy (realistic desktop) | **8.1 / 9.2 / 11.2 ms** | 0.3 Mbit/s |
| 1080p | high-entropy (full-motion) | 10.4 / 14.5 / 28.1 ms | 18 Mbit/s |
| 4K (Retina) | low-entropy (realistic desktop) | **19.5 / 20.6 / 21.5 ms** | 0.4 Mbit/s |
| 4K (Retina) | high-entropy (full-motion) | 21.7 / 31.8 / 32.0 ms | 72 Mbit/s |

**Takeaways for the design:**

1. **The codec floor is small and tight for realistic content** — ~8ms at 1080p, ~19ms at 4K,
   p99 within ~3ms of p50. Against a ~150ms WAN latency budget, encode+decode is a small fixed
   tax at 1080p; at 4K it's ~40ms round-trip (encode+decode both ends), which is why the design's
   bounded-region encode (don't encode 4K every frame to move a mouse) matters.
2. **4K roughly doubles 1080p latency** (~19 vs ~8ms) — direct support for adaptive resolution and
   for encoding only the changed region rather than the full 4K frame.
3. **High-entropy content adds latency and fattens the tail** (p99 28ms vs 11ms at 1080p) — the
   video plane's worst case. The crisp-plane/tile design exists precisely so the whole screen
   isn't treated as full-motion video.
4. **Warmup matters**: the first frames run 90–130ms (IDR + media-engine ramp). Steady-state is
   what's above. rMDP should treat the first post-connect frames as warmup and not report them as
   representative latency.

## A finding worth keeping: RealTime rate control sheds frames, doesn't queue

Investigating apparent "47% frame drops" at 1080p high-entropy: it was **not** a harness bug
(`poolFail=0`) and **not** submission timing (30fps had *more* drops than 60fps). It was the
**20 Mbit/s bitrate cap** — near-incompressible noise can't fit, so the RealTime rate controller
**drops frames to hold the average bitrate**. Raising the cap to 100 Mbit → 300/300, zero drops.

This is exactly the behaviour rMDP's adaptive loop wants and confirms it's available for free from
VideoToolbox: **under load the encoder trades framerate for latency — it sheds frames rather than
building a queue, and the frames that do encode keep their ~8ms latency.** It's the encoder-level
version of the design's "drop temporal L1 before raising QP before queuing" ladder.

## Run it

```bash
swift test                        # pure-core unit tests (watermark, stats)
swift build -c release
./.build/release/rmdp-latencybench                     # 1080p60, low-entropy, 20 Mbit
RMDP_W=3840 RMDP_H=2160 RMDP_BITRATE=40000000 ./.build/release/rmdp-latencybench
RMDP_NOISE=1 RMDP_BITRATE=100000000 ./.build/release/rmdp-latencybench   # worst-case content
# knobs: RMDP_W RMDP_H RMDP_FPS RMDP_FRAMES RMDP_BITRATE RMDP_WARMUP RMDP_NOISE
```

## Step 3 (partial) — render stage added, 2026-08-02

`RMDPRender` (Metal NV12→RGB, zero-copy via `CVMetalTextureCache`, offscreen target) and
`rmdp-pipeline` extend the harness with the real GPU render stage:
**synthetic frame → watermark → H.264 encode → decode → Metal render → GPU-complete → readback.**

| Resolution | stamp → render-complete (p50 / p95 / p99) | vs codec-only floor |
|---|---|---|
| 1080p | **6.9 / 7.4 / 7.6 ms** | ~= 8ms (render adds ≈ nothing) |
| 4K | **21.6 / 23.1 / 24.0 ms** | ~= 19.5ms (render adds ~2ms) |

- **The Metal NV12→RGB render is effectively free** on the M4 (unified memory, trivial fragment
  shader) — within codec run-to-run variance at 1080p, ~2ms at 4K. Render is not where latency
  is spent; encode/decode is, as the research predicted.
- **Watermark survived encode→decode→render→readback in 200/200 frames at both resolutions** —
  the whole pixel path (including YCbCr→RGB→luma reconstruction) is validated, not just the codec.
- Verified headless: offscreen Metal works without a display, so this needs no TCC.

### What's still missing for true motion-to-photon: capture + scanout

- **Capture (`RMDPCapture`, `rmdp-capturetest`)** is built — real `SCStream` wrapper delivering
  NV12 + status flags + dirtyRects — but **cannot run in this headless agent session**:
  `CGPreflightScreenCaptureAccess` is true, yet `SCShareableContent` reports **0 displays**, so
  capture times out with no frames (the CLAUDE.md caveat, confirmed). `rmdp-capturetest` fails
  cleanly with `noDisplay`. **Run it on a console session** to get capture-delivery latency,
  status-flag mix, and dirty-rect coverage:
  ```bash
  swift build -c release
  ./.build/release/rmdp-capturetest        # RMDP_SECONDS, RMDP_FPS
  ```
- **Display scanout** (final ~½ refresh from present to photons) needs an external light-sensor
  rig; the in-band watermark can't see it. Everything up to "frame ready on GPU" is now measured.

Once capture-delivery latency is known from a console run, capture + these render numbers +
the transport RTT from spike 001 compose the full motion-to-photon budget.
