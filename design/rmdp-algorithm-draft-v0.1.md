# rMDP — Adaptive Screen Transport Algorithm

**Draft v0.1 · 2026-08-01 · status: design proposal, nothing implemented**

The proprietary piece of rMDP. Codename **HALO** — *Hybrid Adaptive Latency-Optimised* encoding.
Everything below is a proposal to be argued with, not a decision. Where a claim comes from
measured third-party work it's cited; where it's a guess it says so.

---

## 0. What we're actually optimising

The brief says "close to a real desktop experience from anywhere in the world". That decomposes
into three numbers, in priority order:

| Rank | Metric | Target (WAN, 150ms RTT, 25Mbit) | Why it ranks here |
|---|---|---|---|
| 1 | **Motion-to-photon latency** p95 | ≤ 120 ms over RTT/2 | Below ~150ms total, pointing feels attached to your hand. Above ~250ms it feels like a video call of a computer. |
| 2 | **Text legibility at rest** | pixel-exact within 400 ms of idle | A desktop is 80% static text. Mushy text is the #1 "this isn't my Mac" tell. |
| 3 | **Bandwidth** | 2–8 Mbit typical desktop work | Only matters as a constraint on 1 and 2. |

Parsec's ordering is *latency → framerate → quality* ([Parsec](https://parsec.app/blog/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007)).
That's correct for gaming and **wrong for us**. For a desktop, quality-at-rest outranks
framerate — a 12fps stream that is pixel-sharp reads as a working Mac; a 60fps stream where
menu text shimmers does not. This single inversion is the reason we can't just ship Moonlight.

**Reference points to beat.** Independent light-sensor measurement of a well-built H.264 4K
desktop stream over a 16ms-RTT link: **~99ms typing, ~113ms scrolling**, with encode/decode —
not network — dominating ([Hume, 2022](https://thume.ca/2022/05/15/latency-testing-streaming/)).
A tuned WebRTC remote-control stack hits **98ms mean at 1080p on a good link, 159ms on a
constrained one** ([Hopp](https://www.gethopp.app/blog/latency-exploration)). Parsec claims
**~7ms added on LAN**. So: ~100ms WAN is the state of the art we're matching, and the win we're
chasing is *quality at that latency*, not a smaller number.

---

## 1. Why the obvious designs fail

**Pure video codec (Moonlight/Parsec model).** H.264/HEVC 4:2:0 destroys text. Chroma
subsampling alone smears coloured text on coloured backgrounds; the deadband in rate control
leaves permanent QP noise on static content. Also, encoding *the whole frame every frame*
means latency scales with resolution even when 2% of the screen changed — measured as the
dominant latency term at 4K ([Hume](https://thume.ca/2022/05/15/latency-testing-streaming/)).

**Pure damage-rect codec (VNC/RFB model).** Beautiful at rest, collapses under video playback
or window drags — CPU-bound at Retina resolutions, no hardware path.

**WebRTC.** Right congestion control, wrong defaults. The screen-share path in libwebrtc is a
pile of compromises: `contentHint="detail"` has been observed clamping VP9 to **5 fps**
([webrtc#42223195](https://issues.webrtc.org/issues/42223195)), and the single most impactful
fix teams report is overriding QP bounds — Multi went from the VP9 screenshare default of
**8/52 to 4/36** and called it *"the most significant factor in legibility"*
([Multi](https://multi.app/blog/making-illegible-slow-webrtc-screenshare-legible-and-fast)),
while Hopp additionally zeroed `max_playout_delay` for a **~90ms p50 win**. If the biggest
wins are all *fighting the framework*, own the framework.

**Conclusion:** the correct design is the one Citrix and Teradici converged on independently —
**classify the screen, then route each region to the codec that suits it, and refine to lossless
when the user stops moving.** Citrix Thinwire uses H.264 only on the moving parts and 2DRLE
losslessly on text regions; Intelligent Build to Lossless makes that split dynamic per-monitor
([Citrix](https://docs.citrix.com/en-us/citrix-virtual-apps-desktops/2407/graphics/thinwire.html)).
Teradici PCoIP progressively builds unchanged regions to lossless *regardless of quality setting*
([PCoIP](https://www.teradici.com/pcoip-technology/pcoip-ultra)). Neither ships on macOS. That's
the gap.

HALO is that architecture, rebuilt on Apple Silicon's media engine and a modern delay-based
congestion controller.

---

## 2. HALO architecture

```
SCStream ──► CLASSIFY ──┬─► VIDEO PLANE   (VideoToolbox HEVC/H.264, low-latency RC)
  + dirtyRects          ├─► CRISP PLANE   (tile cache + RLE/palette + zstd, lossless)
                        └─► REFINE QUEUE  (idle-triggered lossless top-up)
                                 │
                        PACER ──► TRANSPORT (QUIC datagrams + adaptive FEC)
                                 ▲
                        CONTROLLER ◄── telemetry (OWD, loss, encode/decode queue depth)
```

Five components. Each is separately testable; the controller is the only thing that knows
about all of them.

**Mental model (borrowed from Mosh — `mosh-comparison.md`):** rMDP is *not* "a stream of frames."
It is **keeping the viewer's tile-state synchronized to the host's current tile-state** — send the
idempotent diff from the viewer's last-acknowledged tiles to the latest tiles, drop stale
intermediate states, latest-wins, no retransmission. The crisp plane is literally Mosh's SSP
applied to pixels; the tile ledger is what makes a screen-sized "diff any two states" affordable.
Everything below — dropping stale frames, re-queuing lost tiles, the refine queue — falls out of
that framing.

---

### 2.1 CLASSIFY — the tile ledger

The screen is divided into **64×64 pixel tiles** (in *capture pixels*, not points — see the
Retina gotcha in `CLAUDE.md`). 4K = 2040 tiles. Every tile carries persistent state:

```
struct TileState {
    var hash: UInt64          // xxHash3 of tile pixels
    var lastChangedFrame: UInt32
    var changeRate: Float     // EWMA of changes/sec, α = 0.15
    var colorCount: UInt8     // saturating count of distinct colours, cap 255
    var plane: Plane          // .video | .crisp | .clean
    var refinedAtQP: UInt8    // 0 = lossless, else the QP it was last sent at
}
```

Per frame:

1. Take `SCStreamFrameInfo.dirtyRects` — ScreenCaptureKit gives us the union of redrawn and
   moved rectangles for free ([Apple](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects?language=objc)).
   **Only hash tiles intersecting a dirty rect.** This is the whole reason capture cost stays
   flat with resolution.
2. Check `SCStreamFrameInfo.status` — skip `.idle`, `.blank`, `.suspended` entirely. A frame
   is not always new pixels.
3. Hash the touched tiles. Unchanged-but-dirty tiles (very common — compositor over-reports)
   drop out here.
   > **✅ Built & measured (2026-08-03) — `design/classify-layer.md`, `RMDPTiles`. This step
   > overturns the original "hash on the GPU" plan.** CPU hashing (FNV-1a + distinct-luma count in
   > one pass) measured on M4 Pro: dirty-rect path **0.46 ms @4K / 0.11 ms @1080p** (the operating
   > point, ~free), and even **full-frame 4K is 8.4 ms** — inside the 16.7 ms budget. **Ship CPU
   > classification; GPU compute is a deferred optimisation, not a prerequisite** (removes a Metal
   > dependency from the initial data plane). Reach for GPU only above 4K or if classify must share
   > the frame with heavy CPU work.
4. Classify each genuinely-changed tile.

**Classifier.** Two cheap signals, computed in the same CPU pass as the hash (originally planned
for a Metal pass — see the measured note above, CPU is fine):

- `colorCount` — distinct colours in the tile, saturating at 255. Text and UI chrome are
  typically < 16. This is exactly the signal HEVC-SCC palette mode exploits
  ([MERL overview](https://www.merl.com/publications/docs/TR2015-126.pdf)).
- `changeRate` — EWMA of how often this tile changes.

```
if changeRate > HIGH_MOTION (default 8 chg/sec)      → .video
else if colorCount <= PALETTE_MAX (default 32)       → .crisp
else if changeRate > LOW_MOTION (default 1.5)        → .video
else                                                 → .crisp
```

Then **spatial coherence**: run a connected-component pass over `.video` tiles and grow each
cluster to a 16-aligned bounding box. Isolated `.video` tiles inside a `.crisp` region get
demoted (a single blinking cursor must not drag a text region into the video plane). Clusters
smaller than 4 tiles are demoted outright.

> **Every constant above lives in one `HALOConfig` struct.** Per `CLAUDE.md`: no magic numbers
> in the adaptive loop. These will be tuned a hundred times.

---

### 2.2 VIDEO PLANE — bounded-region hardware encode

One long-lived `VTCompressionSession`, HEVC where available and the link is tight, H.264 when
latency is king (measured ~10–15ms cheaper per frame at 4K —
[Hume](https://thume.ca/2022/05/15/latency-testing-streaming/)).

Non-negotiable session config:

- `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true`. On Apple Silicon this
  works for **both H.264 and HEVC** (Intel Macs were H.264-only)
  ([Apple](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablelowlatencyratecontrol)).
  This is the single most important flag in the project.
- `AllowFrameReordering = false`. B-frames are a latency bomb.
- `MaxKeyFrameInterval` = effectively infinite. We **never** send periodic IDRs. Recovery is
  LTR-based (§2.5).
- **Temporal layers (2)** via the low-latency SVC path from WWDC21. Enhancement-layer frames
  are droppable under congestion without breaking the reference chain
  ([WWDC21 s10158](https://developer.apple.com/videos/play/wwdc2021/10158/)).
- `MaxAllowedFrameQP` clamped hard. Every team who's tuned this reports the same thing: the
  default max QP is far too permissive for screen content. Multi's 4/36 on VP9 is the closest
  published analogue; our starting point is **QP 18–34** for H.264/HEVC, tuned empirically.

**The bounded-region trick.** Rather than encode the full frame, the session is sized to the
union bounding box of the video clusters, snapped to 16px and quantised to a small ladder of
sizes (to avoid reconfiguring every frame). When the box changes ladder rung, we reconfigure
and force an IDR — `VTCompressionSession` reconfiguration mid-stream can silently ignore a
property or force a keyframe anyway, so we make it explicit and tell the viewer.

Typical desktop work: video plane is 0% of the screen (nothing playing) or one window. Full-
frame encode only happens during a fullscreen video or a window drag. **This is where the
bandwidth and latency win lives** — we're not paying 4K encode cost to move a mouse.

**No ROI/QP-map dependency.** Per-block QP maps are the textbook approach
([NETINT survey](https://netint.com/research/blog/region-of-interest-encoding-for-cloud-gaming/))
but VideoToolbox does not expose a reliable per-macroblock QP map. Spatial region routing is
how we get the same effect without fighting the API. *Open question: verify against
`VTSessionCopySupportedPropertyDictionary` on current hardware before finalising.*

---

### 2.3 CRISP PLANE — lossless, and genuinely small

> **✅ Built & measured (2026-08-03) — `design/crisp-plane.md`, `RMDPCrisp` (8 tests).** Lossless
> reconstruction verified pixel-exact across REF/PAL/RAW; cache proven desync-proof over 30 frames
> with eviction. **Measured bandwidth, lossless: typing desktop 0.035 Mbit/s (73 B/frame),
> reading-speed scroll 0.198 Mbit/s (411 B/frame)** — ~5,000–28,000× under naive raw luma, encode
> ~0.0–0.3 ms/frame. `RAW` uses macOS-native **LZFSE** (no external dep) instead of zstd; a trained
> dictionary is a later shrink. **New integration point found: scroll detection must feed the
> classifier** — otherwise fast scroll spikes change-rate and gets misrouted to the lossy video
> plane (§2.1↔§2.3). Cache slots are **encoder-dictated** (sent with every record), which is
> simpler and stronger than the "deterministic LRU both ends" originally planned.

Everything not in the video plane. Four encodings, chosen per tile, cheapest that fits:

| Code | Encoding | When | Cost |
|---|---|---|---|
| `REF` | 16-bit index into tile cache | Tile hash seen before | 2 bytes |
| `SCROLL` | (dx,dy) reference to a tile in the previous frame | Vertical-offset match found | 4 bytes |
| `PAL` | Palette (≤16 colours) + packed indices | `colorCount ≤ 16` | ~200–600 B |
| `RAW` | zstd level 1, shared trained dictionary | Fallback | ~1–3 KB |

**Tile cache.** 4096-entry LRU keyed by tile hash, mirrored on both ends. Menus, the Dock,
window chrome, and repeated glyph runs hit this constantly. Cache state is part of the session
and survives quality changes. Eviction is deterministic (pure LRU, same policy both sides) so
the two caches cannot diverge; the tile ID space wraps with an epoch byte to catch desync.

**Scroll detection.** Hash each *tile row* of the screen, then search the previous frame's row
hashes for a consistent vertical offset. Hume implemented exactly this and measured **~2ms for
a full 4K screen on one core** — cheap enough to run every frame
([Hume](https://thume.ca/2022/05/15/latency-testing-streaming/)). A page scroll becomes a few
hundred bytes and near-zero encode latency instead of a full-frame keyframe. Scrolling is the
single worst case for a naive video-codec desktop stream, and this is the answer to it.

**zstd dictionary** trained offline on captured macOS UI tiles (Aqua chrome, common system
fonts at common sizes, light and dark). Ships with the binary, versioned in the handshake.
Dictionaries dramatically improve ratio on small inputs — and every tile is a small input
([zstd](https://github.com/facebook/zstd)).

The crisp plane is **always lossless**. It never negotiates quality. Under congestion we send
*fewer tiles per frame*, never *worse tiles* — degrade in time, not in fidelity. This is the
inversion of the video-codec model and it's what makes text stay sharp on a bad link.

---

### 2.4 REFINE — build to lossless

When a tile leaves the video plane (motion stopped), it's marked `refinedAtQP = <lastQP>` and
pushed to the refine queue. Once the controller sees **spare bandwidth *and* an idle input
channel**, the queue drains lowest-QP-first, re-sending those tiles losslessly via the crisp
plane. Tile becomes `.clean`, costs nothing further.

Priority = `f(staleness, QP, distance from cursor)` — refine what the user is looking at first.

This is Citrix Intelligent Build to Lossless and PCoIP progressive build, and it is *the*
feature that separates a desktop protocol from a game-streaming protocol. It's also the reason
we can afford to be aggressive with QP during motion: **the damage is temporary by
construction.** Target: any tile that stops moving is pixel-exact within 400ms of the last
change, on any link that isn't actively saturated.

---

### 2.5 Loss recovery — never send a keyframe

A full IDR at 4K on a 5Mbit link is a 500ms stall. We avoid them structurally.

- **Crisp plane** is idempotent per-tile. A lost tile is simply re-queued — it has no temporal
  dependency at all. Losing a `REF`/`SCROLL` tile requires the referenced state, which is why
  cache eviction is deterministic and epoch-tagged.
- **Video plane** uses **Long Term Reference frames**, exposed by VideoToolbox's low-latency
  mode specifically for error recovery ([WWDC21 s10158](https://developer.apple.com/videos/play/wwdc2021/10158/)).
  Viewer acknowledges decoded LTRs; on loss it NACKs, and the host encodes the next frame
  against the most recent *acknowledged* LTR. Cost: one slightly larger P-frame. Compare to an
  IDR: 10–20× cheaper. IDR only on resolution change, session start, or LTR-window exhaustion.
- **Temporal enhancement layer** is droppable by definition — under congestion the pacer just
  stops sending it. Halved framerate, zero corruption, no signalling round-trip.

---

### 2.6 TRANSPORT — QUIC datagrams

**QUIC over `Network.framework`**, using the unreliable DATAGRAM extension
([RFC 9221](https://www.rfc-editor.org/rfc/rfc9221.html)). `NWProtocolQUIC.Options` exposes
`isDatagram` and `maxDatagramFrameSize`, with `usableDatagramFrameSize` in the metadata — so
this is a supported path, not a hack. Retransmitting a stale frame "consumes bandwidth without
adding perceptual value" (RFC 9221), which is exactly our situation.

Why QUIC rather than rolling our own like Parsec's BUD:

- TLS 1.3 authentication and encryption come free and correct. `CLAUDE.md` says security is
  not optional; this streams a live desktop *and accepts remote input*. Hand-rolling DTLS is
  where this project would get itself owned.
- Reliable streams and unreliable datagrams share one connection, one handshake, one
  congestion state. Input events and control go on reliable streams; video and crisp tiles go
  on datagrams. That mapping falls out naturally.
- Connection migration handles Wi-Fi→cellular and IP changes without a reconnect.
- Parsec built BUD in ~2016 when QUIC wasn't an option. It isn't 2016.

> **✅ RESOLVED — spike 001, 2026-08-01.** See `spikes/quic-pacing/RESULTS.md`.
> `Network.framework` QUIC exposes **no** pacing/cwnd/congestion-controller API (confirmed by
> auditing every header in the framework). **We use QUIC anyway and pace at the application
> layer** — which is what §2.7 always specified. The Noise IK fallback is **dropped**.
> Three measured constraints now bind the controller:
> 1. `send()` is fire-and-forget — p50 <1.5µs at every load, and it gets *faster* as load
>    rises. It is **not** a backpressure signal, and neither is completion latency. Congestion
>    must come from receiver-reported telemetry on the control channel.
> 2. **Gate on delay, not loss** (measured, §2.7 below).
> 3. GCD + `usleep` holds 60fps cadence to p95 19.7ms — no real-time thread needed yet.
>
> **Follow-on now also answered (spike 001, part F):**
> - **RTT telemetry works.** The loopback zeros were an artifact. Through a 114ms path
>   `transportMinimumRTT` read 114–118ms and `transportSmoothedRTT` tracked queue growth to
>   2494ms. Use min-RTT as the floor, growth above it as the congestion signal.
> - **Apple's CC beats naive UDP on throughput.** Through an identical 2 Mbit/s bottleneck at 4×
>   overload: QUIC held 1.92 Mbit/s (96% of link) at **0% app-visible loss**; raw UDP collapsed
>   to 0.92 Mbit/s at 77% loss. Hand-rolling UDP would have been worse on performance as well as
>   security.
> - **But it optimises throughput, not latency** — goodput flat at ~1.92 Mbit/s while RTT climbed
>   459 → 1642 → 2494ms. It buffers instead of telling us to slow down. **Hence the app-layer
>   pacer is mandatory, not an optimisation.**

**⚠️ Over a mesh/overlay, connect to the peer's OVERLAY address, not its LAN address (spike 001,
PATH-NOTES.md).** Real QUIC over a WireGuard mesh failed to handshake when the client targeted the
host's LAN IP: the host received there but routed replies back via the mesh interface with a
*different* source IP, and QUIC (unlike connectionless UDP) drops replies from an unexpected
source. Targeting the mesh IP made forward and return symmetric and the handshake completed
instantly. **Peer discovery / the capability handshake must advertise and connect to the address
the peer will source replies from** — the overlay address — not a LAN address that merely happens
to be reachable. This is a "works in raw-UDP testing, fails in QUIC" trap; it needs an explicit
test case. (Apple's QUIC and its RTT telemetry were otherwise confirmed working correctly over
WireGuard.)

**⚠️ UDP reachability is not guaranteed — probe it, don't assume it (spike 001, PATH-NOTES.md).**
A Cloudflare WARP Connector on one test path passed TCP and ICMP perfectly (arbitrary ports,
source IP preserved) while **silently dropping 100% of UDP** — most likely a Gateway L4 policy.
`ping` and `ssh` work; QUIC datagrams vanish. This is common in exactly the SMB/MSP Zero-Trust
environments rMDP targets. Consequences baked into the design:

- The **capability handshake must actively probe UDP** — send N datagrams over the datagram
  channel, require echo within a deadline — and fail over to the **TCP fallback fast**. Never
  infer datagram reachability from the control channel (channel 0) connecting; the control
  channel may be riding a reliable QUIC stream or TCP that survives where datagrams don't.
- The TCP fallback is **not a degraded mode on these paths — it is the only mode.** Budget for
  it as a real operating point, not an emergency.
- The viewer UI must **surface "TCP fallback — UDP blocked upstream"** so worse latency reads as
  a network policy, not an rMDP bug.

**Channels:**

| Channel | Delivery | Content |
|---|---|---|
| 0 | reliable stream | control, handshake, resize, capability negotiation |
| 1 | reliable stream | input events (never lose a keystroke) |
| 2 | datagram | video plane, temporal L0 |
| 3 | datagram | video plane, temporal L1 (droppable) |
| 4 | datagram | crisp tiles, priority |
| 5 | datagram | refine queue (lowest priority, drops first) |

**Adaptive FEC.** Retransmission costs a full RTT — fatal at 150ms when the frame deadline is
16ms; FEC costs bandwidth up front. The right answer is neither, it's both, keyed on whether
the deadline permits ARQ ([Haivision](https://www.haivision.com/blog/broadcast-video/low-latency-video-packet-loss-arq-fec/)).

```
fecOverhead = clamp(baseFEC + k * measuredLoss, 0.0, 0.35)
useARQ      = (RTT * 1.5) < remainingFrameDeadline
```

Reed–Solomon across a frame's datagrams, overhead proportional to measured loss. Crisp tiles
get *more* FEC than video (a lost text tile is visible; a lost enhancement-layer frame is not).
On a clean link FEC is ~0% and we pay nothing.

---

### 2.7 CONTROLLER — the adaptive loop

**Congestion control: SQP-style.** GCC (what every browser ships) has "slow convergence in
dynamic links"; NADA suffers the late-comer effect; SCReAM under-utilises the link
([comparison](https://arxiv.org/pdf/1809.00304)). None were designed for this.

**SQP** was: frame-coupled paced packet trains to sample bandwidth, plus adaptive one-way-delay
measurement to keep queuing delay low and bounded. Google A/B-tested it against Copa on real AR
streaming and got **+27% of sessions at high-bitrate-and-low-frame-delay on LTE, +15% on Wi-Fi**,
and **2–3× the bandwidth of GoogCC/Sprout/PCC-Vivace when competing with Cubic/BBR flows**
([Ray et al., 2022](https://arxiv.org/abs/2207.11857)). It is the closest published algorithm
to our problem: high-bitrate compressed video, hard per-frame delay budget.

The key structural insight we adopt: **the frame itself is the probe.** We already emit a burst
of packets per frame; pace that burst and measure the receive-side dispersion, and you get a
bandwidth estimate for free with no probing overhead.

**But sub-frame pacing is mandatory, and it's the first thing to get right (spike 001,
PATH-NOTES.md).** Measured on a real tunnel: sending a frame's packets back-to-back at line rate
(then idling to the next frame) vs spreading them evenly across the 16ms interval, at the *same
average bitrate* —

| Offered (same rate) | Bursty (packets at frame start) | Smooth (spread across interval) |
|---|---|---|
| 2 Mbit/s | 1.58 Mbit delivered | 1.98 Mbit, 0% loss |
| 3 Mbit/s | 13.7% loss | 0.00% loss |
| 4 Mbit/s | 97% loss | 0.00% loss |

~20% less throughput and an order of magnitude more loss, purely from burst shape — a shallow
tunnel queue drops the microburst at the head of each frame regardless of the average. So the
pacer releases packets on a **sub-frame clock** (e.g. every `frameInterval / packetsThisFrame`),
never all at once. "The frame is the probe" measures dispersion of *that evenly-spaced train*,
which is also what makes the bandwidth estimate clean. This lives in `HALOConfig` as the pacing
granularity and must not regress — an early naive "send the frame, then sleep" implementation
will look fine on loopback and fall apart on the first real tunnel.

**Measured justification (spike 001, Brisbane→Darwin, ~114ms baseline RTT):**

| Offered | Loss | RTT p50 | RTT max | Queue swing |
|---|---|---|---|---|
| 1 Mbit/s | **0.00%** | 149 ms | 236 ms | 132 ms |
| 2 Mbit/s | 3.06% | 259 ms | 612 ms | 485 ms |
| 4 Mbit/s | 49.64% | 1008 ms | 1871 ms | 1769 ms |
| 8 Mbit/s | 71.33% | 1007 ms | 1367 ms | 1268 ms |

A textbook bufferbloat curve. **Latency degrades a full step before loss does** — at 2 Mbit/s
loss is a benign-looking 3% while RTT p50 has already gone 149→259ms; by 4 Mbit/s the queue is
holding 1.8 *seconds*. A loss-based controller pushes straight into that and destroys
interactivity. A delay-gradient controller sees the knee roughly 2× earlier. That's the whole
argument for SQP-style control, and it now rests on our own measurement rather than a paper.

(One corporate path to a loaded host at one moment — a hostile-link datapoint, not a universal
constant. Tune against several paths.)

**Inputs:** paced-burst bandwidth estimate, one-way delay trend (Kalman-filtered gradient),
loss rate, encode queue depth, decode queue depth, viewer render backlog.

**Confirmed-available transport telemetry** (spike 001F, `NWConnection.startDataTransferReport()`):
`transportMinimumRTT` as the propagation-delay floor, `transportSmoothedRTT` for queue growth
above it, plus `transportRTTVariance`, retransmitted bytes, and out-of-order/duplicate counts.
Measured accurate against a known 114ms injected path.

**A warning the measurements make concrete:** on this path, offered load of 2 Mbit/s already
yields 96% of link goodput *while RTT has quadrupled to 459ms*. Throughput is a useless control
signal here — it is saturated long before the link is comfortable. **The controller must target
the delay knee, never the throughput ceiling.** Above the knee, QUIC absorbs everything we give
it into a queue up to 2.5 seconds deep and reports no error at all.

**Confirmed end-to-end with real QUIC over the real path** (spike 001G — Apple's
`Network.framework` client against an `aioquic` server on the Darwin box):

| Offered | Fwd loss | RTT p50 | smoothedRTT | minRTT |
|---|---|---|---|---|
| 2 Mbit/s | **0.0%** | 256 ms | 103 ms | 91 ms |
| 3 Mbit/s | 13.7% | 2384 ms | 542 ms | 92 ms |

At 2 Mbit/s: **zero loss, but RTT p50 already 2.8× the floor.** One step further: 26× the floor.
There is no gentle warning between "fine" and "unusable" — the only signal that appears before
the cliff is delay. `retransmitted: 0 B` throughout, so QUIC itself reports perfect health at
5-second RTT.

**Concrete tuning rule for §2.7, derived from measurement rather than assumed:**

```
targetRTT   = minimumRTT * RTT_INFLATION_TARGET   // default 1.25
backoffAt   = minimumRTT * RTT_INFLATION_BACKOFF  // default 1.5
```

`transportMinimumRTT` is a stable propagation floor (91–103ms across every load tested) and is
the right baseline. On this path the rule targets ~1.5 Mbit/s rather than the ~1.9 the link will
nominally absorb — **the last 20% of throughput costs 20× the latency.** For a desktop that
trade is never worth taking. Both constants belong in `HALOConfig`.

**Outputs, in the order they're reached for:**

1. Drop the refine queue (free, invisible)
2. Drop temporal L1 (60→30fps, invisible on a desktop)
3. Reduce crisp tiles per frame (text updates slow, stays sharp)
4. Raise video-plane QP toward `MaxAllowedFrameQP`
5. Reduce video-plane framerate
6. Reduce video-plane resolution (scale + IDR + viewer notification)
7. Reduce capture resolution (last resort — hurts everything)

**Note that quality-of-text is never on this list.** That is the design.

**Self-clocking upper bound (from Mosh — see `mosh-comparison.md`).** Above the delay-gradient
controller, borrow Mosh's SSP pacing: don't emit the next crisp/control state update until the
previous is ~acknowledged, flooring the interval at half the smoothed RTT so ~one update is in
flight. `stateSyncMinInterval = 0.5 · smoothedRTT`. On a 150ms link this caps the *state-sync*
cadence at ~13Hz when the link is slow — ample for a mostly-static desktop and structurally
bufferbloat-proof. Applies to the crisp plane and control channel; the video plane keeps its own
higher cadence when there's motion and bandwidth. This is a self-clocking ceiling, not a
replacement for delay-gradient control — the two compose.

**Asymmetric hysteresis** — the classic mistake is symmetric thresholds, which oscillate:

```
downgrade: immediate on OWD gradient > threshold or loss > threshold
upgrade:   only after STABLE_WINDOW (default 3s) of clean telemetry,
           step size 1.15× (never jump), with an exponential backoff
           counter that lengthens STABLE_WINDOW after each oscillation
```

Fast down, slow up, and *remember* if a link has proven flaky. On a link that oscillates, the
window grows to tens of seconds and we stop thrashing.

**No jitter buffer by default.** Hopp measured **46ms of jitter buffer delay even on a good
link** and Multi zeroed `max_playout_delay` for a ~90ms p50 win. We render on arrival. An
adaptive buffer engages *only* when measured jitter exceeds a threshold, sized to measured
jitter (not a fixed constant), and decays back to zero. Frames are timestamped at capture and
that timestamp is carried to render, so we always know our real end-to-end number rather than
guessing.

---

### 2.8 INPUT — the perceived-latency half

Real motion-to-photon can't beat RTT. Perceived latency can, and this is where a desktop
protocol gets to cheat in ways a game stream can't.

- **Local cursor, always.** Cursor is metadata, never burned into the stream (also removes it
  as a source of constant tile churn). Client draws it at the local pointer position, zero
  latency. Host sends cursor image/hotspot changes as small control messages. `CLAUDE.md`
  already calls this the right answer — it is, and it's worth roughly a whole RTT of
  *perceived* pointer latency.
- **Input timestamping.** Every event carries a client monotonic timestamp. The host injects
  via `CGEventPost` preserving relative timing, so a fast drag arrives as a drag, not as a
  teleport. (Reference point: one published remote-input implementation measured **42.3ms
  median** input latency; that's the number to beat on our own path.)
- **Coalescing with intent.** Mouse *moves* coalesce to one per frame. Clicks, key events, and
  scroll deltas **never** coalesce and go on the reliable stream. Losing a keystroke is
  unforgivable in a way that losing a mouse-move sample is not.
- **Confidence-gated speculative rendering (from Mosh — `mosh-comparison.md`).** Mosh's real
  lesson isn't its terminal model, it's the *discipline*: predict tentatively, display only when
  confident, reconcile within one RTT, back off when wrong. Apply it only to geometry rMDP knows
  *locally*, never to content it would have to invent:
  - **Scroll** — a wheel/trackpad delta is known at the client and almost always shifts the
    content region by that delta. The client speculatively shifts already-decoded tiles and
    displays immediately, reconciling against the host's next frame (the host already models
    scroll via tile-row hashing → `SCROLL` refs, §2.3, so both ends agree). Biggest single
    perceived-latency prize after typing, and the worst case for a naive stream.
  - **Window drag** — dragging a title bar translates a known region with the cursor;
    speculatively move that region's last-decoded tiles locally, reconcile on arrival.
  - Mechanics borrowed verbatim: **epochs** (a batch of shifts all-right-or-all-wrong),
    **confidence gating** (only speculate once the host confirms the interaction mode), **cheap
    rollback** (snap to the host frame on mismatch — worst case ≤1 RTT of a slightly-wrong shift,
    Mosh's exact guarantee). Constants (`speculationEpochConfirmFrames`, etc.) in `HALOConfig`.
  - **✅ POC built & measured (2026-08-02) — `design/scroll-poc.md`, `RMDPSpeculate`.** Interior of
    a shifted frame is pixel-exact (verified, incl. compounded flicks); perceived latency RTT→0;
    misprediction self-heals in ≤1 RTT; zero added bandwidth; a 1280×800 shift costs 0.32ms.
    **The only cost is the leading edge = `scrollSpeed × RTT` rows.** So: reading-speed scrolling
    is a clean win at any realistic RTT (~2 lines edge on a 114ms WAN); **cap the speculative
    scroll rate on high-RTT links** (`maxSpeculativeScrollRows ≈ k / smoothedRTT`) so a fast flick
    doesn't expose most of the viewport as unknown — above the cap, the interior still shifts
    instantly and only the runaway edge waits for the host.
- **Speculative echo of typed *content* — still deferred, and Mosh confirms why.** Mosh can
  predict keystrokes only because it fully models the server (it *is* a terminal). rMDP can't
  model an arbitrary macOS app — we don't know what pixels a key produces in Photoshop or a
  browser. A wrong content prediction is worse than the latency; a wrong scroll-offset prediction
  self-heals in ≤1 RTT. Speculate on geometry, never on invented content. Revisit only if
  measurement says typing feel is the remaining bottleneck.

---

## 3. Wire format

Versioned from day one, one place, round-trip tested including truncated and malformed input.

```
┌─ rMDP datagram header (8 bytes, fixed) ─────────────────────┐
│ ver:4 │ chan:4 │ flags:8 │ seq:16 │ frameID:16 │ captureTS:16│
└─────────────────────────────────────────────────────────────┘
```

`captureTS` is milliseconds relative to a per-session epoch — enough range, and it's what makes
end-to-end latency measurable rather than guessed. Payload is a sequence of TLV records
(`TILE_REF`, `TILE_SCROLL`, `TILE_PAL`, `TILE_RAW`, `VIDEO_NAL`, `CURSOR`, `LTR_ACK`, `NACK`,
`CONFIG_CHANGE`, …).

Capability handshake negotiates: protocol version, codec support (HEVC / H.264 / AV1 encode is
Ultra-and-above-only, so it must be *negotiated*, never assumed — decode is available from M3
onward, encode only on higher-tier M4/M5 parts), zstd dictionary version, tile cache size, max
datagram size, display topology.

**Wire format changes are breaking changes** — bump the version, note it in `memory/`, state
compatibility impact in the commit body.

---

## 4. Bandwidth estimates (arithmetic, not measurement)

4K Retina, back-of-envelope. **These are predictions to be falsified, not results.**

| Scenario | Video plane | Crisp plane | Total |
|---|---|---|---|
| Idle desktop, cursor moving | 0 | ~0 | **< 50 kbit/s** |
| Typing in an editor | 0 | ~30 tiles/s × 400B | **~100 kbit/s** |
| Scrolling a web page | 0 | scroll refs + ~200 new tiles/s | **~1.5 Mbit/s** |
| Dragging a window | 1 cluster @ ~1MP | ~50 tiles/s | **~4 Mbit/s** |
| Fullscreen 1080p video | full plane | 0 | **~8 Mbit/s** |
| Xcode build, log scrolling | 0 | ~400 tiles/s | **~3 Mbit/s** |

The comparison that matters: a naive full-frame H.264 stream at 4K/60 sits at 15–25 Mbit
*regardless of what's on screen*. If these numbers survive contact with a real implementation,
HALO is 10–50× cheaper for actual desktop work and roughly equal for video playback — with
better text everywhere.

---

## 5. Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| ~~`Network.framework` QUIC won't allow pacer-driven send rate~~ | ~~High~~ → **Low** | **Confirmed true, but not blocking** (spike 001). No rate API exists; the pacer owns rate at the app layer, as designed. Noise IK fallback dropped. |
| Tile classification flaps (text↔video), causing visible churn | High | Hysteresis on plane transitions; require N consecutive frames to promote. |
| ~~Tile cache desync between ends~~ | ~~High~~ → **Low** | **Solved (2026-08-03): encoder dictates cache slots**, sent with every record; decoder is a pure follower — can't desync by construction. Verified over 30 frames with forced eviction (`RMDPCrisp`). |
| ~~Crisp plane CPU cost at 4K exceeds budget~~ | ~~Medium~~ → **Low** | **Measured (2026-08-03): classify is CPU-viable at 4K** — dirty-rect 0.46 ms, full-frame 8.4 ms (`design/classify-layer.md`). GPU hashing deferred. Crisp-plane *encode* cost (zstd/palette) still to measure. |
| VideoToolbox mid-stream reconfiguration silently ignored | Medium | Explicit IDR + viewer ack on every ladder change; never trust a property set. |
| `SCStream` dirtyRects over-report (whole screen dirty) | Medium | Hashing is the ground truth; dirtyRects is only a hint that narrows the hash set. |
| Mixed-DPI multi-monitor coordinate bugs | Medium | One tested transform function, early, never inlined again. |
| NAT traversal past LAN | Medium | LAN/Bonjour first. Ship relay before claiming "anywhere in the world" — UDP hole punching is only ~82–95% and symmetric NAT/CGNAT is common. |
| **UDP blocked entirely by a Zero-Trust/WARP overlay** | **High** | **Observed (spike 001): Cloudflare WARP passed TCP+ICMP, dropped 100% of UDP.** Handshake must probe datagram reachability and fail to TCP fast; TCP fallback is a real operating point, not an emergency; UI surfaces it. See §2.6. |
| **Bursty per-frame sending collapses on shallow-queue tunnels** | **High** | **Observed (spike 001): same bitrate, 0% loss smooth vs 97% bursty at 4 Mbit.** Sub-frame pacing is mandatory in the pacer (§2.7); don't ship "send frame then sleep". |
| Path-capacity numbers in spike 001 are tunnel-limited, not real WAN | Low (doc) | Every test path transited CGNAT or WARP; endpoints were 58–166 Mbit. Re-measure over a non-overlay/WireGuard path before quoting a field bitrate. |
| Over-engineering before a single frame moves | **High** | §6. |

---

## 6. Build order

The whole design above is worthless if it isn't validated incrementally. Suggested sequence —
each step produces a number:

1. ~~**Spike: QUIC datagram pacing on `Network.framework`.**~~ ✅ **Done 2026-08-01** —
   `spikes/quic-pacing/RESULTS.md`. §2.6 survives; pace at the app layer. Next transport task
   is QUIC-to-QUIC over a real path to see what Apple's CC costs.
2. ~~**Latency harness first.**~~ ✅ **Done 2026-08-02** — `design/latency-harness.md`. Built as
   the real SPM package (`RMDPMeasure` + `RMDPCodec` + `rmdp-latencybench`). In-band luma
   watermark validated (100% recovery through real H.264). **Measured encode→decode floor on M4
   Pro: p50 ~8ms @1080p, ~19ms @4K** (realistic content), p99 within ~3ms of p50. Confirmed
   VideoToolbox RealTime RC sheds frames rather than queuing under load. Not yet motion-to-photon
   (no capture/scanout) — that arrives with step 3.
3. **Dumbest possible pipeline:** SCStream → full-frame H.264 low-latency → QUIC → decode →
   Metal. Measure. This is the baseline every later claim is argued against.
   - 🟡 **Partial (2026-08-02)** — `design/latency-harness.md`. **Encode→decode→Metal render**
     measured & validated (render is ≈free: ~7ms@1080p / ~21.6ms@4K; watermark 200/200 through
     the full pixel path). **Capture (`RMDPCapture`) built but needs a console session** — this
     env has 0 displays; run `rmdp-capturetest` at the console for capture-delivery latency.
     Transport RTT already characterised (spike 001). Remaining to fully close: wire the real
     SCStream capture in on a console + display scanout via light sensor.
4. **Tile ledger + crisp plane, lossless only, no video plane.** Measure text quality and
   bandwidth on a static desktop.
5. **Both planes + classifier.** Measure the handoff. Expect this to be where the bugs are.
6. **LTR recovery + FEC.** Measure under `dnctl` impairment (5Mbit / 120ms / 2% loss).
7. **SQP-style controller.** Measure convergence time and oscillation under changing link
   conditions.
8. **Refine queue.** Measure time-to-lossless after motion stops.

Steps 1–3 are a working remote desktop. Everything after is the proprietary part.

---

## 7. Open questions

1. ~~Does `Network.framework` QUIC expose enough send-rate control, or do we hand-roll?~~
   **Fully answered — spike 001 (A–F).** No rate API; use QUIC, pace at the app layer. RTT
   telemetry confirmed accurate. Apple's CC beats naive UDP on throughput but buffers to 2.5s,
   so delay-gradient control at the app layer is mandatory. Remaining nice-to-have: repeat
   QUIC-to-QUIC end-to-end when a second macOS box is available.
2. HEVC 4:2:2 hardware encode is confirmed on Apple Silicon; **4:4:4 encode is not confirmed**.
   Query `VTSessionCopySupportedPropertyDictionary` on target hardware. If 4:4:4 exists, does
   it make the crisp plane unnecessary for *some* content? (Suspect not — subsampling isn't the
   only thing hurting text, QP noise is — but it's worth knowing.)
4. Is 64×64 the right tile size? 32×32 tracks text better and costs 4× the ledger. Measure both.
5. Multi-display: one stream per display, or one composited surface? Separate streams are
   cleaner for independent adaptation; composited is simpler. Lean separate.
6. Audio: separate stream, own pacing, Opus. Deliberately out of scope for v1 — but the
   protocol should reserve channel IDs for it now so adding it isn't a version bump.
7. AV1 encode on M4 Ultra / M5 Pro+ — worth a codec path, or too narrow an install base for v1?

---

## Sources

- [Parsec — A Networking Protocol Built For Low Latency Interactive Game Streaming](https://parsec.app/blog/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007)
- [Tristan Hume — Latency testing remote browsing: Why display streaming is hard](https://thume.ca/2022/05/15/latency-testing-streaming/)
- [Hopp — Achieving <100ms Latency for Remote Control with WebRTC](https://www.gethopp.app/blog/latency-exploration)
- [Multi — Making Illegible, Slow WebRTC Screenshare Legible and Fast](https://multi.app/blog/making-illegible-slow-webrtc-screenshare-legible-and-fast)
- [Ray et al. — SQP: Congestion Control for Low-Latency Interactive Video Streaming](https://arxiv.org/abs/2207.11857)
- [Zhang et al. — Congestion Control for RTP Media: A Comparison on Simulated Environment](https://arxiv.org/pdf/1809.00304)
- [Citrix — Thinwire](https://docs.citrix.com/en-us/citrix-virtual-apps-desktops/2407/graphics/thinwire.html) · [Intelligent Build to Lossless](https://docs.citrix.com/en-us/citrix-virtual-apps-desktops/graphics/thinwire/intelligent-build-to-lossless.html)
- [Teradici — PCoIP Ultra](https://www.teradici.com/pcoip-technology/pcoip-ultra) · [Build-to-Lossless](https://docs.vmware.com/en/VMware-Horizon-7/7.13/horizon-remote-desktop-features/GUID-FB9598F4-EBBD-4CFF-B24E-CF9D18E729CD.html)
- [MERL — Overview of the Emerging HEVC Screen Content Coding Extension](https://www.merl.com/publications/docs/TR2015-126.pdf)
- [Apple — Explore low-latency video encoding with VideoToolbox (WWDC21 s10158)](https://developer.apple.com/videos/play/wwdc2021/10158/)
- [Apple — kVTVideoEncoderSpecification_EnableLowLatencyRateControl](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablelowlatencyratecontrol)
- [Apple — SCStreamFrameInfo.dirtyRects](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects?language=objc)
- [RFC 9221 — An Unreliable Datagram Extension to QUIC](https://www.rfc-editor.org/rfc/rfc9221.html)
- [Haivision — Protecting Low Latency Video from Packet Loss: ARQ vs FEC](https://www.haivision.com/blog/broadcast-video/low-latency-video-packet-loss-arq-fec/)
- [Microsoft — Graphics encoding over RDP (AVC444)](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/844018a5-d717-4bc9-bddb-8b4d6be5dd3f)
- [NETINT — Region of Interest Encoding for Cloud Gaming](https://netint.com/research/blog/region-of-interest-encoding-for-cloud-gaming/)
- [webrtc issue 42223195 — contentHint="detail" limits frameRate to 5 with VP9](https://issues.webrtc.org/issues/42223195)
- [Noise Protocol Framework](https://noiseprotocol.org/noise.html)
- [Zstandard](https://github.com/facebook/zstd)
