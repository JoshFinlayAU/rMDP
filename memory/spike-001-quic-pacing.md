---
name: spike-001-quic-pacing
description: Spike 001 result — Network.framework QUIC has no rate-control API; use it anyway and pace at the app layer
metadata:
  type: project
---

Run 2026-08-01 on M4 Pro / macOS 26.5.2 / Swift 6.3.3. Full writeup:
`spikes/quic-pacing/RESULTS.md`. This resolves the blocking question in
[[rmdp-open-questions]] #1.

**Decision: use `Network.framework` QUIC. Do NOT hand-roll UDP. The Noise IK fallback is
dropped from the plan.**

`NWProtocolQUIC.Options` gives us `isDatagram`, `maxDatagramFrameSize`, flow-control windows,
`maxUDPPayloadSize`, `idleTimeout`, and (macOS 26) the async `QUIC.datagrams` API. It gives us
**no pacing rate, no cwnd, no congestion-controller selection** — confirmed by grepping every
header in the framework, not just quic_options.h.

That's survivable because rMDP's pacer was always going to own rate itself. Losing TLS 1.3,
shared handshake for reliable+unreliable channels, and connection migration to gain a pacing
knob is a bad trade.

**Three facts the controller must be built around:**

1. **`send()` is fire-and-forget and is NOT backpressure.** p50 under 1.5µs at every load, and
   it gets *faster* as load rises (8.0→0.4µs mean from 6→317 Mbit/s). Completion-callback
   latency isn't backpressure either. Congestion signal must come from receiver-reported
   telemetry on the control channel, never from the send path.
2. **Gate on delay, not loss.** Measured Brisbane→Darwin (~114ms baseline): path knee sits
   between 1–2 Mbit/s. At 2 Mbit/s loss is only 3% but RTT p50 already went 149→259ms; at
   4 Mbit/s the queue held **1.8 seconds** and loss hit 50%. A loss-based controller would push
   straight into that. Direct empirical support for the SQP-style delay-gradient design.
3. **GCD + `usleep` holds frame cadence well enough** — target 16666µs, measured p50 16650 /
   p95 19703 / p99 22767µs. No real-time thread needed yet.

**Telemetry available** via `NWConnection.startDataTransferReport()`: smoothed/min RTT, RTT
variance, retransmitted bytes, out-of-order and duplicate byte counts. **RTT telemetry is
confirmed working** — the loopback 0.000ms readings were an artifact of there being no delay to
measure. Through a 114ms path, `transportMinimumRTT` read 114–118ms and `transportSmoothedRTT`
tracked queue growth to 2494ms. Controller should treat `transportMinimumRTT` as the floor and
growth in `transportSmoothedRTT` above it as the congestion signal.

**QUIC vs raw UDP through an identical calibrated bottleneck (2 Mbit/s, 114ms RTT):** at 4×
overload QUIC held **1.92 Mbit/s (96% of link) with 0% app-visible loss**; raw UDP collapsed to
0.92 Mbit/s with 77% loss. Apple's CC is genuinely better than anything we'd hand-roll — this
independently kills the hand-rolled-UDP option on performance grounds, not just security.

**But Apple's CC optimises throughput, not latency.** Goodput sits flat at ~1.92 Mbit/s from
2 Mbit/s offered upward while smoothed RTT climbs 459 → 1642 → 2494ms. It absorbs and buffers
rather than signalling the app to slow down. At the 2 Mbit/s point goodput is already 96% of
capacity while RTT has quadrupled — **throughput-based tuning cannot see that cliff; only
delay-gradient control can.** This is why the app-layer pacer is mandatory rather than an
optimisation.

**Two traps that cost time here, both of which produced convincing wrong numbers:**
- Running the pacer on the connection's own dispatch queue serializes every completion behind
  it — showed 2.5s mean completion latency, a pure artifact. Use a dedicated pacer queue.
- `pkill -f rmdp_udp_echo` over ssh matches the ssh command line itself and kills the shell
  before the responder launches. Use `pkill -f "[r]mdp_udp_echo"`, and always verify `pgrep`
  before trusting a loss figure — an early sweep reported a confident 100% loss this way.

**Confirmed end-to-end with REAL QUIC (part G).** Josh authorised installing on TTS-DRW-AI01, so
`aioquic` 1.3.0 went into a throwaway `/tmp` venv and served genuine RFC 9221 datagrams across
the real Brisbane→Darwin path against Apple's `Network.framework` QUIC client. Results confirm
the relay-calibrated numbers:

| Offered | Fwd loss | RTT p50 | smoothedRTT | minRTT |
|---|---|---|---|---|
| 2 Mbit/s | **0.0%** | 256 ms | 103 ms | 91 ms |
| 3 Mbit/s | 13.7% | 2384 ms | 542 ms | 92 ms |

Path capacity ≈1.6 Mbit/s; knee between 2–3 Mbit/s (independently consistent with the raw-UDP
curve of 1–2 Mbit/s). **`transportMinimumRTT` held a stable 91–103ms floor across every load** —
exactly the baseline a delay-gradient controller needs. `retransmitted: 0 B` throughout, even at
5-second RTT: **an app watching only QUIC's error signals sees a healthy connection while the
user experiences 5s lag.**

**The tuning rule this gives us:** pace to hold `smoothedRTT` near `minimumRTT`, back off above
~1.5× ratio. On this path that means targeting ~1.5 Mbit/s, not the ~1.9 the link will absorb —
**the last 20% of throughput costs 20× the latency**, never worth it for a desktop.

Caveat: aioquic is single-threaded Python, so round-trip loss at ≥4 Mbit/s partly reflects the
echo server saturating. Forward-path numbers are server-counted and sound; the 1–3 Mbit/s rows
(where all conclusions come from) show exact client/server agreement. Remote host was left
clean — venv and all artifacts removed, system Python untouched.

See [[halo-algorithm-v0.1]].
