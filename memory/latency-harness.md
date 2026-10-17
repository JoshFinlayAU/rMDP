---
name: latency-harness
description: The rMDP latency harness (real SPM package) and the measured H.264 encode→decode latency floor on the M4 Pro
metadata:
  type: project
---

Draft step 2, built 2026-08-02. This is the first REAL rMDP code — an SPM package at the spoke
root (`Package.swift`, `Sources/`, `Tests/`), not a spike. Full writeup: `design/latency-harness.md`.

**Package (Swift 5 language mode — deliberate, for VideoToolbox/CoreVideo C-interop):**
- `RMDPMeasure` — `MonotonicClock`, `LatencyRecorder` (fixed-cap single-producer ring, lock-free
  record, p50/p95/p99), `WatermarkCodec` (64-bit value in luma blocks, preamble-validated).
  Pure + unit-tested (9 tests green, incl. watermark surviving ±20 simulated quantisation).
- `RMDPCodec` — low-latency `H264Encoder`/`H264Decoder` (VideoToolbox block API), IOSurface NV12
  `PixelBufferPool`. Config: low-latency RC, no frame reordering, RealTime, no periodic IDRs.
- `rmdp-latencybench` — stamps monotonic ts into each frame's luma, runs real HW encode→decode,
  reads it back, records now−stamp. Synthetic frames = **no TCC/Screen Recording grant needed**.

**Watermark technique validated end-to-end: 100% recovery through a real H.264 round-trip.** This
is the black-box latency method (like Hopp's) that will later capture capture+scanout too.

**Measured H.264 encode→decode floor, M4 Pro (300 frames, 30 warmup excluded):**
- 1080p realistic desktop content: **p50 8.1ms, p99 11.2ms**
- 4K realistic: **p50 19.5ms, p99 21.5ms** (roughly 2× 1080p — supports adaptive-res + region encode)
- High-entropy (full-motion) fattens the tail (1080p p99 28ms) — the video plane's worst case.

This is encode+decode+queue only, NOT motion-to-photon (no capture, no scanout yet — those add
when draft step 3's real pipeline plugs into the same harness).

**Finding worth keeping:** apparent "47% frame drops" at 1080p high-entropy was the 20 Mbit
bitrate cap, not a bug (poolFail=0; 30fps dropped *more* than 60fps, ruling out timing; raising to
100 Mbit → 0 drops). VideoToolbox RealTime rate control **sheds frames to hold bitrate and keep
latency, rather than queuing** — the encoder-level version of HALO's degradation ladder, available
for free. Frames that do encode keep ~8ms latency.

**Step 3 render half done (2026-08-02).** Added `RMDPRender` (Metal NV12→RGB, zero-copy
CVMetalTextureCache, offscreen target) and `rmdp-pipeline`. Measured stamp→render-complete:
**1080p ~6.9ms, 4K ~21.6ms** — i.e. the Metal render adds ≈nothing at 1080p, ~2ms at 4K; render
is NOT where latency lives, encode/decode is. Watermark survived encode→decode→render→readback
200/200 at both resolutions (whole pixel path incl. YCbCr→RGB validated). Offscreen Metal works
headless (no TCC needed for the render half).

**Capture half built but NOT runnable headless.** `RMDPCapture` (real SCStream: NV12 + status
flags + dirtyRects) + `rmdp-capturetest`. This agent session has `CGPreflightScreenCaptureAccess
== true` but **0 displays**, so SCStream capture times out (CLAUDE.md caveat confirmed).
capturetest fails cleanly with `.noDisplay`. **Josh must run `rmdp-capturetest` on a console
session** to get capture-delivery latency / status mix / dirty-rect coverage. Display scanout (~½
refresh) still needs a light-sensor rig — the watermark can't see it.

Full motion-to-photon budget = capture-delivery (needs console run) + render (~7ms@1080p) +
transport RTT (spike 001) + scanout (light sensor). See [[spike-001-quic-pacing]],
[[path-testing-findings]], [[halo-algorithm-v0.1]].

**Console capture run 2026-10-17 (Josh, MacBook display, 5s @ 60fps request):** SCK works from a
`.build/` binary (TCC preflight true). 128 frames = 25.6 fps effective, all `.complete`, avg
dirty coverage 8.6%. Inter-arrival p50 17.5ms (≈60Hz) but p95 158 / p99 540ms — that tail is
**content idleness** (SCK only delivers on change), NOT capture jitter. **Gap:** capturetest
measures inter-arrival only — it does NOT measure capture-delivery latency, so the motion-to-photon
capture term is still unknown. Fix: diff `SCStreamFrameInfo.displayTime` (mach time) against
arrival time. Also: stream is configured at POINT size (1512×982), i.e. 2× downscaled, not native.

**Capture-delivery MEASURED 2026-10-17 (`feat/capture-latency`, M4 Pro MacBook, display active):**
`SCStreamFrameInfo.displayTime` is mach_absolute_time ticks (same domain as MonotonicClock — verified)
and is the frame's **scheduled scanout**, not a past event. SCK delivers frames **~2ms BEFORE
scanout**: callback − displayTime p50 −1.9ms, p95 +0.6, p99 +1.4 (point size 1512×982); native
3024×1964 is the same (p50 −2.2, p99 +1.0) — **native resolution costs nothing on the capture side**.
Steady 58 fps, gaps p99 ~21ms when the screen is busy. → The capture term of motion-to-photon is
≈0 relative to scanout; what it does NOT see is app-draw→composite (upstream of SCK), which only a
light-sensor/watermark-on-screen rig can measure. `RMDP_NATIVE=1` enables backing-pixel capture.
Also: capture now works from Claude sessions when the Mac has an active display (earlier 0-display
result was the session context at the time, not a permanent limit).
