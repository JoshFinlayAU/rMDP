# Path characterisation notes — measuring rMDP's transport over real links

Companion to `RESULTS.md`. Records what the *test paths themselves* turned out to be, because
several "path capacity" numbers turned out to be artifacts of the intermediate network, not the
endpoints. Written 2026-08-01.

## Summary — most test paths were overlays; the WireGuard mesh is the representative one

| Path | Route signature | RTT | TCP thru | UDP | Real limiter |
|---|---|---|---|---|---|
| Brisbane → Darwin (AI01) | `100.128.2.2` (CGNAT) | ~114 ms | — | passes, ~5 Mbit clean | carrier tunnel uplink |
| Brisbane → 10.16.69.2 (v1) | `100.128.2.2` (CGNAT) | ~94 ms | ~2.6 Mbit | passes, ~2.5 Mbit clean | carrier tunnel uplink |
| Brisbane → 10.16.69.2 (v2) | `162.158.x` (Cloudflare WARP) | ~78 ms | ~7.1 Mbit | **dropped entirely** | WARP Connector / Gateway |
| **Brisbane → 10.16.69.2 (v3)** | **`10.255.255.1` (WireGuard mesh)** | **~114 ms** | **34 Mbit** | **passes, clean to ~40 Mbit** | **measurement tool, not path** |

The CGNAT and WARP rows are overlays that shaped or blocked UDP and do **not** represent what
rMDP will traverse. The **WireGuard mesh (v3) is the representative path** — UDP passes natively
with source IP preserved, and it's also how rMDP would realistically run host↔viewer. Endpoints
for context: Ookla from the host **137/99 Mbit (Optus)**; this Mac **258/166 Mbit**.

### The real number (WireGuard mesh, ~114 ms RTT, smooth-paced UDP)

| Offered | Delivered | Loss |
|---|---|---|
| 5 Mbit/s | 4.94 | 0.07% |
| 10 Mbit/s | 10.1 | 0.19% |
| 20 Mbit/s | 19.8 | 0.00% |
| 30 Mbit/s | 30.2 | 0.22% |
| 35 Mbit/s | 35.0 | 0.03% |
| 40 Mbit/s | 39.9 | 0.24% |
| 50 Mbit/s | 45.8 | 8.54% |
| 100 Mbit/s | 94.2 | 6.21% |

**Clean to ~40 Mbit/s.** Above that the loss is the single-threaded Python sink/pacer saturating,
not the path — 94 Mbit delivered at 100 offered proves the path has far more headroom (and the
non-monotonic loss, 14% at 75 but 6% at 100, is the signature of a tool bottleneck, not a link
one). TCP reference (bypasses the Python pacer entirely): **34 Mbit**. So an rMDP-relevant path
gives **tens of Mbit clean** — 15–25× the tunnel figures, and comfortably above what HALO needs
even during fullscreen video (~8 Mbit) with headroom for the whole desktop.

**Nuance on the burst finding (below):** on this fat pipe, bursty and smooth both showed ~0%
loss at 10 and 20 Mbit. **The burst penalty is a shallow-queue phenomenon** — it appears on
constrained tunnel paths, not when there's headroom. That doesn't weaken the requirement: it
means sub-frame pacing is a *robustness feature for bad links*, which is exactly where rMDP's
adaptive loop earns its keep. Keep it; it costs nothing on good paths and saves the connection on
bad ones.

## Finding 1 — the "path dies at 1.6 Mbit" claim was partly my own send pattern

The original spike (RESULTS.md §C/§G) reported a knee at ~1.6–2 Mbit/s. Re-testing with an
evenly-spaced sender instead of frame-cadence bursts moved that knee substantially:

| Offered (same rate) | Bursty (60fps) | Smooth-paced |
|---|---|---|
| 2 Mbit/s | 1.58 Mbit delivered | 1.98 Mbit, 0% loss |
| 3 Mbit/s | 13.7% loss | 0.00% loss |
| 4 Mbit/s | 97% loss | 0.00% loss |

Same bitrate, ~20% less throughput and an order-of-magnitude more loss when sent as bursts. A
shallow tunnel queue drops the microburst at the head of each frame regardless of the average
rate.

**Design consequence (feeds §2.7):** the pacer must spread each frame's packets across the
frame interval — sub-frame pacing — not release them at frame start. This is now a first-class
requirement, not an implementation detail. The delay-gradient control still sits on top of it.

## Finding 2 — WARP / Zero-Trust overlays can silently drop UDP while passing TCP + ICMP

The v2 path is a **Cloudflare WARP Connector** doing site-to-site routing between the two private
subnets. Confirmed on the host: route back to the client is `dev CloudflareWARP src 100.96.0.8`;
`cloudflared` + `warp-svc` both running. The connector supports TCP/UDP/ICMP by design.

Yet measured behaviour over it:

| Protocol | Result |
|---|---|
| ICMP | ✅ works, 78 ms |
| TCP (`:22`, arbitrary `:7443`) | ✅ works, source preserved as real client IP `10.80.111.27` |
| UDP (`:7443`, `:443`, `:53`, `:51820`) | ❌ **zero packets arrive** — verified on eth0, CloudflareWARP, and `any` |

Host firewall is `policy ACCEPT`, no rules — the drop is inside the Cloudflare path, not on the
host. TCP to arbitrary ports passing with source preserved proves the site-to-site routing works;
the drop is **UDP-specific**, most likely a **Cloudflare Gateway → Network firewall policy** that
permits TCP/ICMP but not UDP (or a subnet-routing asymmetry for UDP on the client-side connector
at `10.80.111.70`). That is a Cloudflare-dashboard config, not fixable from the endpoints.

### Why this is a real rMDP hazard, not just a test snag

rMDP is UDP-first (QUIC datagrams). A viewer or host sitting behind a WARP/Zero-Trust overlay —
increasingly common in exactly the SMB/MSP environments this targets — may find **the entire
transport black-holed while `ping` and `ssh` work fine**, giving a "network's up but rMDP won't
connect" failure that's maddening to diagnose. The TCP fallback the design already carries is
**not a degraded mode on these paths — it is the only mode.** Two implications:

1. The capability handshake must **actively probe UDP reachability** at connect time (send a few
   datagrams, require echo within a deadline) and fail over to TCP fast, rather than assuming
   QUIC datagrams will flow because the control channel connected.
2. The connection UI needs to *surface* "running over TCP fallback (UDP blocked upstream)" so the
   user understands why latency is worse — otherwise it reads as an rMDP bug.

## Resolved

A **WireGuard mesh path (v3)** was stood up and gave the clean measurement that was outstanding:
**tens of Mbit clean UDP, ~40 Mbit measured before the Python tooling (not the path) became the
limit.** UDP passes natively with source preserved. This is the representative rMDP number and
supersedes the tunnel figures for planning purposes.

## Finding 3 — QUIC over a mesh/overlay must address the peer by its MESH IP, not its LAN IP

Real QUIC-to-QUIC (Apple `Network.framework` client → `aioquic` server) over the WireGuard path
**failed to handshake entirely** when the client targeted the host's LAN IP `10.16.69.2` —
`waiting: Operation timed out`, zero packets. Raw UDP to the same address worked fine, which is
what made it confusing.

Root cause: the host receives on `10.16.69.2` (eth0) but its route back to the client is via
`dev wg-mesh src 10.255.255.2`, so **replies are sourced from `10.255.255.2`, a different IP than
the client sent to.** Raw UDP didn't care — a connectionless socket's `recvfrom` accepts a reply
from any source. **QUIC binds the connection to the peer address and drops responses from an
unexpected source IP**, so the handshake never completes. Confirmed directly: an echo test to
`10.16.69.2:7443` returned packets sourced from `10.255.255.2:7443`.

**Fix:** address the peer by its WireGuard mesh IP (`10.255.255.2`) so forward and return are
symmetric on the tunnel. With that change the QUIC handshake completed immediately.

**rMDP consequence:** over any mesh/overlay (WireGuard, Tailscale-style, or NAT with
asymmetric routing), rMDP must connect to the peer on the **same address the peer will source
replies from** — i.e. the overlay address, not a LAN address that happens to also be reachable.
The capability handshake / peer discovery must surface the overlay address as the connect target.
This is exactly the kind of thing that "works in raw-UDP testing, fails in QUIC" — worth a test
case.

### QUIC-over-WG throughput: tool-limited, path & Apple's stack are fine

Once connected, QUIC was clean at 5 Mbit (0% loss) but showed 31% loss at 10 Mbit and 96% at
20 Mbit — **all attributable to the single-threaded `aioquic` Python echo server, not the path or
Apple's QUIC.** Proof:

- Raw UDP was clean to ~40 Mbit on this identical path.
- Server-side count = client-echoed count exactly (2239 = 2239 at 10 Mbit) → **zero return-path
  loss**; the "loss" is the server's UDP socket buffer overflowing because aioquic's event loop
  (decrypt + process + re-encrypt per packet) can't drain it fast enough. `aioquic` CPU-bound in
  `top` during the run.
- **Apple's QUIC stayed healthy throughout** — `transportSmoothedRTT` held ~140ms and
  `transportMinimumRTT` ~99ms even while my app-level round-trip ballooned to 4–6s, because the
  queue is in the aioquic echo server, not in QUIC's transport. `retransmitted: 0 B` (correct for
  unreliable datagrams).

So: **QUIC datagrams work correctly over WireGuard; Apple's telemetry is accurate over it; the
throughput ceiling in this test is the Python echo server.** A non-Python (or one-way, fast-sink)
QUIC server would be needed to find the true QUIC ceiling, but the raw-UDP ~40 Mbit already
establishes the path has ample headroom for rMDP.
