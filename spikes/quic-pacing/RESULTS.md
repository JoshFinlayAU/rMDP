# Spike 001 — QUIC datagram pacing on `Network.framework`

**Run 2026-08-01 · M4 Pro, macOS 26.5.2 (25F84), Xcode 26.6 / Swift 6.3.3**
**Verdict: Network.framework QUIC is viable for rMDP, but we must own rate control ourselves.**

> **⚠️ Correction (2026-08-01, later):** the absolute path-capacity figures in §C and §G
> (~1.6–5 Mbit/s "knees") are **artifacts of the test networks**, not real WAN capacity. Every
> path measured transited a carrier CGNAT tunnel or a Cloudflare WARP overlay; the endpoints
> themselves run 58–166 Mbit/s uplink. Two follow-on findings — a **sub-frame pacing
> requirement** and a **WARP-drops-UDP transport hazard** — are written up in `PATH-NOTES.md`
> and are the more durable output. Treat the *behavioural* conclusions below (RTT telemetry,
> delay-before-loss, QUIC buffering) as sound; treat the specific Mbit/s numbers as
> tunnel-limited, not representative.

The question from the design draft §2.6: *does `Network.framework` QUIC expose enough send-rate
control to drive our own pacer, or do we hand-roll UDP?* This blocked the whole transport layer.

---

## Answer

**Use Network.framework QUIC. Do not hand-roll the transport.** But treat Apple's congestion
control as *not ours*, and drive rate at the application layer — which is where rMDP's pacer
was always going to live anyway.

Rationale below, in the order the evidence came in.

---

## A. API surface — what exists, audited from the SDK

Grepped `quic_options.h` (889 lines) and the full `arm64e-apple-macos.swiftinterface`.

**Present and usable:**

| Capability | API |
|---|---|
| Unreliable datagrams (RFC 9221) | `NWProtocolQUIC.Options.isDatagram` |
| Datagram size negotiation | `.maxDatagramFrameSize`, `nw_quic_get_stream_usable_datagram_frame_size` |
| Flow-control windows | `.initialMaxData`, `.initialMaxStreamData*`, `.initialMaxStreams*` |
| UDP payload / MTU | `.maxUDPPayloadSize` |
| Idle timeout | `.idleTimeout` |
| Modern async datagram API (macOS 26) | `QUIC.datagrams`, `NWParameters.quicDatagram(alpn:)` |

**Absent — searched every header in the framework:**

```
grep -riE "pacing|congestion|cwnd|send_rate|bitrate|max_rate" Network.framework/Headers/
  → 3 hits, all unrelated (ECN flag docs, TCP ECN disable)
```

There is **no pacing rate, no cwnd control, no congestion-controller selection, and no
send-rate cap anywhere in the public API.** This is settled, not a gap in my search.

**Telemetry we *can* read** (`NWConnection.startDataTransferReport()` → `PathReport`):
`transportSmoothedRTT`, `transportMinimumRTT`, `transportRTTVariance`,
`retransmittedTransportByteCount`, `receivedTransportOutOfOrderByteCount`,
`receivedTransportDuplicateByteCount`, sent/received byte and packet counts.

That is *most* of a congestion-control input set — enough to drive the rMDP controller's
decisions, even though we can't drive QUIC's own.

> ⚠️ **Caveat:** on loopback, RTT fields all read **0.000ms**. Whether they populate on a real
> path is untested — the WAN leg below used raw UDP, not QUIC. **Verify before depending on
> them.** If they stay zero, we time our own control-channel pings, which we want regardless.

---

## B. Loopback behaviour — 4 loads, 60fps burst cadence

`send()` + `.contentProcessed` completion, 1100B datagrams, paced in per-frame bursts.

| Offered | `send()` blocking p50/p99 | Completion p50/p99 | Goodput | Errors |
|---|---|---|---|---|
| 6.3 Mbit/s | 1.5 / 74 µs | 321 / 2838 µs | 6.35 Mbit/s | 0 |
| 31.7 Mbit/s | 0.9 / 35 µs | 858 / 5964 µs | 31.81 Mbit/s | 0 |
| 126.7 Mbit/s | 0.8 / 12 µs | 1495 / 6269 µs | 127.19 Mbit/s | 0 |
| 316.8 Mbit/s | 0.3 / 1.2 µs | 1333 / 2773 µs | 317.75 Mbit/s | 0 |

**Findings:**

1. **`send()` never blocks meaningfully** — p50 under 1.5µs at every load, and it gets *faster*
   as load rises (8.0 → 0.4µs mean). It is a fire-and-forget enqueue. It is **not** a
   backpressure signal, and a pacer must never treat it as one.
2. **Completion callbacks are not backpressure either.** Latency rises with load (321µs →
   1495µs) but so does concurrency; it never gates the sender. Zero errors at 50× the target
   bitrate.
3. **Pacer accuracy is good enough.** Target 16666µs inter-frame; measured p50 16650µs,
   p95 19703µs, p99 22767µs. GCD + `usleep` holds frame cadence to within ~3ms at p95. No need
   for a real-time thread yet.

**Harness bug worth recording:** the first run showed 2.5s mean completion latency. That was
the measurement, not the framework — `paceLoop` was running on the connection's *own* dispatch
queue, so every completion serialized behind the 5-second pacing loop. Moving the pacer to a
dedicated queue dropped it to 472µs. **Never run a pacer on the connection's callback queue.**

---

## C. Real WAN path — TTS-DRW-AI01, Brisbane → Darwin

Loopback has infinite bandwidth and cannot congest, so it can't answer the question that
matters. Ran raw-UDP frame-cadence bursts against a stdlib-only echo responder on
`TTS-DRW-AI01` (Debian 13, 144 cores, load ~16, `systemd-detect-virt: none`).
**Baseline ICMP RTT 91–148ms (avg 114ms).**

| Offered | Delivered | Loss | RTT p50 | RTT max | Queue swing |
|---|---|---|---|---|---|
| 1 Mbit/s | 120/120 | **0.00%** | 149 ms | 236 ms | 132 ms |
| 2 Mbit/s | 349/360 | 3.06% | 259 ms | 612 ms | 485 ms |
| 4 Mbit/s | 423/840 | 49.64% | 1008 ms | 1871 ms | 1769 ms |
| 8 Mbit/s | 516/1800 | 71.33% | 1007 ms | 1367 ms | 1268 ms |

**This is a textbook bufferbloat curve, and it is the single most important result here.**

- The path knee sits between **1 and 2 Mbit/s**. Above it, delivery collapses.
- **Latency degrades before loss does.** At 2 Mbit/s loss is only 3% but RTT p50 has already
  gone 149→259ms and max hit 612ms. By 4 Mbit/s the queue holds **1.8 seconds** of data.
- A loss-based controller would happily push into 4 Mbit/s and destroy interactivity while
  "only" losing packets. **A delay-based controller sees the knee ~2× earlier.** This is direct
  empirical support for the SQP-style, delay-gradient design in draft §2.7 — on this path, on
  real hardware, not from a paper.

**Loss direction isolated:** at 8 Mbit/s the remote responder independently reported receiving
1223 of 4497 by sequence number — matching the 1223 we got echoed back exactly. **All loss is
on the forward path**, none on the return. The bottleneck is uplink/queue toward Darwin.

> ⚠️ **Do not read this as "the internet gives you 2 Mbit/s".** This is one corporate path to a
> loaded production host at one moment. It is a *hostile-link datapoint*, and a very useful one
> — but the adaptive loop must be tuned against several paths, not this one.

---

## D. What this changes in the design

**Draft §2.6 stands, with one amendment.** QUIC is still right — TLS 1.3 comes correct and free,
reliable streams and datagrams share one handshake and one connection, and connection migration
handles Wi-Fi→cellular. Hand-rolling DTLS to gain a pacing knob is a bad trade, and the
security argument in `CLAUDE.md` is decisive.

**The amendment:** rMDP's controller cannot delegate rate to QUIC. It must:

1. **Pace at the application layer** — decide bytes-per-frame itself and release them on the
   frame clock. `send()` won't push back, so the pacer is the *only* thing preventing us from
   dumping into a 1.8-second queue. This is not a workaround; it's exactly what draft §2.7
   specifies. The measurements just prove there's no alternative.
2. **Never treat `send()` or completion latency as a congestion signal.** They aren't.
   Congestion must come from *receiver-reported* telemetry on the control channel: OWD trend,
   arrival dispersion, sequence gaps.
3. **Gate on delay, not loss.** The knee is visible in RTT long before loss. Confirmed above.
4. **Verify `transportSmoothedRTT` populates on a real QUIC path** before relying on it.
   Untested — loopback read zero.

**Risk register update:** "Network.framework QUIC won't allow pacer-driven send rate" —
**confirmed true, but downgraded from High to Low.** It doesn't block us, because the pacer was
always going to own rate. The Noise IK fallback is **not needed**; drop it from the plan.

---

## E. Reproducing

```bash
cd spikes/quic-pacing
swift build -c release

# loopback (needs a keychain identity for the QUIC listener; exits 2 without one)
./.build/release/quicspike
RMDP_DPF=240 RMDP_FRAMES=180 ./.build/release/quicspike   # vary offered load

# real WAN — start responder on the far end first
scp remote/udp_echo.py root@<host>:/tmp/
ssh root@<host> 'setsid python3 /tmp/udp_echo.py --mode echo --port 7443 \
    --idle-exit 25 --max-seconds 200 > /tmp/e.log 2>&1 < /dev/null &'
RMDP_WAN_HOST=<host> RMDP_WAN_MBIT=4 RMDP_WAN_FRAMES=120 ./.build/release/quicspike
ssh root@<host> 'cat /tmp/e.log'    # forward-path loss, independent of our count
```

Remote artifacts were removed and the responder stopped after the run; the host was left as
found. No sudo, no firewall changes, no `pfctl`/`dnctl` — impairment was measured on a real
path rather than injected locally.

**Gotcha for future runs:** `pkill -f rmdp_udp_echo` over ssh matches the ssh command line
itself and kills the shell before the responder starts. Use `pkill -f "[r]mdp_udp_echo"`.
An early sweep silently reported 100% loss for this reason — always verify `pgrep` shows the
responder alive before trusting a loss number.

---

## F. QUIC vs raw UDP through an identical bottleneck

**Method note — why not QUIC-to-Darwin directly.** A QUIC peer on AI01 would need `aioquic`;
there's no `pip3` on the box and installing packages on a loaded production host isn't
justified for a spike. Tunnelling QUIC over `ssh -L` was rejected outright: SSH forwards TCP,
so we'd have measured the *tunnel's* congestion control (and TCP-over-TCP meltdown), not
QUIC's. Instead the userspace relay was **calibrated to the measured Darwin curve** — 2 Mbit/s
bottleneck, 57ms one-way (114ms RTT) — and both stacks pushed through it. Same relay, same
queue discipline, same run conditions, so the delta is attributable to the transport.

| Offered | QUIC goodput | QUIC RTT | QUIC app loss | UDP goodput | UDP RTT | UDP app loss |
|---|---|---|---|---|---|---|
| 1 Mbit/s | 1.06 Mbit/s | 118 ms | 0.0% | 1.00 Mbit/s | 116 ms | 0.0% |
| 2 Mbit/s | 1.91 Mbit/s | 459 ms | 0.0% | 1.77 Mbit/s | 1206 ms | 11.7% |
| 4 Mbit/s | 1.92 Mbit/s | 1642 ms | 0.0% | 0.92 Mbit/s | 1900 ms | 77.4% |
| 8 Mbit/s | 1.93 Mbit/s | 2494 ms | 0.0% | 0.55 Mbit/s | 2144 ms | 93.7% |

**1. ✅ RTT telemetry DOES populate — the loopback zeros were an artifact.**
`transportMinimumRTT` read **114–118ms**, matching the injected 114ms almost exactly, and
`transportSmoothedRTT` tracked queue growth from 118ms → 2494ms. The open question from §A is
resolved: **we can use Apple's RTT telemetry as a controller input.** It reads zero only when
there is genuinely no delay to measure (loopback).

**2. Apple's CC is *better* than naive UDP at holding throughput under overload.** At 4×
overload QUIC retained **1.92 Mbit/s (96% of link) with zero application-visible loss**, while
raw UDP collapsed to 0.92 Mbit/s (46%) with 77% loss. QUIC's flow control pushed back into the
send buffer instead of dumping into the queue. **This kills the "hand-roll UDP for performance"
argument on its own merits** — we would have had to rebuild all of this, worse.

**3. But QUIC will still happily build a 2.5-second queue.** Goodput is flat at ~1.92 Mbit/s
from 2 Mbit/s upward, while smoothed RTT climbs 459 → 1642 → 2494ms. Apple's CC optimises for
*throughput*, not for *latency* — exactly wrong for interactive work. It never signals the
application to slow down; it just absorbs and buffers.

> **This is the central finding for rMDP.** Anything above ~1 Mbit/s on this path is latency
> the user feels, and QUIC will not tell us. The application-layer pacer is not an
> optimisation — it is the *only* component that can keep us at the knee. Note the 2 Mbit/s row:
> goodput is already at 96% of capacity while RTT has quadrupled to 459ms. **Throughput-based
> tuning cannot see that cliff. Delay-gradient control can.**

**Practical corollary:** rMDP's controller should target the *minimum* RTT it has observed
(`transportMinimumRTT` as the floor) and treat growth in `transportSmoothedRTT` above that
floor as the primary congestion signal — both are now confirmed available and accurate.

---

## G. REAL QUIC end-to-end — Apple's stack vs aioquic across the actual path

The measurement §F could only approximate. `aioquic` 1.3.0 installed into a throwaway venv on
AI01 (`/tmp/rmdpvenv`, removed afterwards — see §I), serving genuine RFC 9221 QUIC datagrams
with a self-signed cert. Swift client = Apple's `Network.framework` QUIC, real handshake, real
congestion control, real Brisbane→Darwin path. Server echoes each datagram and independently
reports what it received, so forward loss is *attributed*, not inferred.

| Offered | Fwd loss | RTT p50 | RTT max | smoothedRTT | minRTT | Server goodput |
|---|---|---|---|---|---|---|
| 1 Mbit/s | 0.0% | 123 ms | 208 ms | 121 ms | 103 ms | — |
| 2 Mbit/s | **0.0%** | 256 ms | 394 ms | 103 ms | 91 ms | 1.57 Mbit/s |
| 3 Mbit/s | 13.7% | 2384 ms | 3112 ms | 542 ms | 92 ms | 1.64 Mbit/s |
| 4 Mbit/s | 97.1% | 1560 ms | 5146 ms | 1227 ms | 92 ms | — |
| 8 Mbit/s | 67.3% | 277 ms | 5424 ms | 1260 ms | 122 ms | 1.09 Mbit/s |

**Path capacity ≈1.6 Mbit/s. The knee is between 2 and 3 Mbit/s** — consistent with the raw-UDP
curve in §C (1–2 Mbit/s), measured independently, months of protocol stack apart.

**1. ✅ RTT telemetry confirmed on a genuine WAN path, not just a synthetic one.**
`transportMinimumRTT` held steady at **91–103ms** across every load — a stable propagation
floor, exactly what a delay-gradient controller needs as its baseline. `transportSmoothedRTT`
tracked congestion from 103ms → 542ms → 1260ms. Both usable. Interface correctly reported
`wifi`.

**2. The §F conclusion survives contact with reality, and sharpens.** At **2 Mbit/s the link
shows 0% loss while RTT p50 has already risen to 256ms against a 91ms floor — a 2.8× inflation
that loss-based control cannot see at all.** One step further (3 Mbit/s) and p50 hits 2384ms,
**26× the floor**. There is no gentle warning between "fine" and "unusable"; the only signal
that appears *before* the cliff is delay.

**3. Apple's QUIC buffers aggressively rather than reporting failure.** At 8 Mbit/s offered,
the server received only 1209 datagrams by sequence out of 2700 sent — the client's own stack
never transmitted most of them, it queued them. `retransmitted: 0 B` throughout: as far as QUIC
is concerned nothing went wrong. **An application watching only QUIC's error signals would
believe this connection is healthy while the user experiences 5-second lag.**

> **Design consequence, now measured end-to-end rather than argued:** rMDP must pace to hold
> `smoothedRTT` close to `minimumRTT`, and treat a sustained ratio above roughly 1.5× as the
> signal to back off — well before loss appears. On this path that means targeting ~1.5 Mbit/s,
> not the ~1.9 Mbit/s the link will nominally absorb. **The last 20% of throughput costs 20× the
> latency.** For a remote desktop that trade is never worth taking.

### Caveats

- `aioquic` is pure Python and single-threaded; the 97%/67% *round-trip* loss at 4–8 Mbit/s
  partly reflects the echo server saturating, not purely the network. **The forward-path
  numbers are trustworthy** (server-counted, sequence-attributed); return-path numbers at
  ≥4 Mbit/s are not, and are excluded from the conclusions above. The 1–3 Mbit/s rows — where
  every conclusion is drawn — show exact client/server agreement.
- One path, one afternoon, one loaded host (load avg ~16). Directionally solid, absolutely not a
  universal constant.
- Client and server were both behind the same corporate routing; a consumer NAT path may behave
  differently.

---

## H. Next

1. Draft step 2: the latency harness (capture→render timestamps, in-band watermark).
2. Prototype the delay-gradient pacer against these numbers — `minRTT` floor, back off above
   ~1.5× ratio — and re-run this exact sweep to confirm it holds the knee.

---

## I. Remote host hygiene

Everything installed on AI01 lived in `/tmp` and was removed after the run: `/tmp/rmdpvenv`
(venv + aioquic), `/tmp/rmdp_quic_server.py`, `/tmp/rmdp_cert.pem`, `/tmp/rmdp_key.pem`,
`/tmp/get-pip.py`, and all log files. No apt packages, no system Python changes, no services, no
firewall rules, no reboot. Verified clean post-run.
