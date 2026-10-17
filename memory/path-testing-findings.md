---
name: path-testing-findings
description: Real-path testing for rMDP transport — sub-frame pacing requirement and WARP-drops-UDP hazard; and why the spike's Mbit numbers are tunnel-limited
metadata:
  type: project
---

Findings from testing rMDP's UDP transport over real links (2026-08-01). Full writeup:
`spikes/quic-pacing/PATH-NOTES.md`. These correct/extend [[spike-001-quic-pacing]].

**The spike's absolute path-capacity numbers (~1.6–5 Mbit/s knees) are artifacts of the test
networks, not real WAN.** Every path tested went through either a carrier CGNAT tunnel
(`100.128.2.2`) or a Cloudflare WARP overlay. The endpoints themselves are fast — Ookla from the
Darwin/Canberra host: 123 down / 58 up (Telstra); this Mac: 258 down / 166 up. The low numbers
are the overlay between them, 50–65× below the slower endpoint. **Do not quote a field bitrate
until we test over a non-overlay or WireGuard path.**

**Finding 1 — sub-frame pacing is mandatory.** Same average bitrate, bursty (all of a frame's
packets at frame start) vs smooth (spread across the 16ms interval): at 2 Mbit bursty delivered
1.58 vs smooth 1.98 Mbit; at 3 Mbit bursty lost 13.7% vs smooth 0.00%; at 4 Mbit bursty lost 97%
vs smooth 0.00%. A shallow tunnel queue drops the microburst at the head of each frame. The
original spike's "knee at 1.6 Mbit" was substantially my own bursty send pattern. **The pacer
must release packets on a sub-frame clock, not "send frame then sleep."** Now a first-class
`HALOConfig` requirement.

**Finding 2 — WARP / Zero-Trust overlays can silently drop UDP while passing TCP+ICMP.** A
Cloudflare WARP Connector doing site-to-site routing passed ICMP (ping) and TCP (ssh, and
arbitrary port 7443, source IP preserved) perfectly, but dropped 100% of UDP on every port tried
(7443/443/53/51820), verified with tcpdump on eth0, the CloudflareWARP interface, and `any`. Host
firewall was open ACCEPT — the drop is inside the Cloudflare path, almost certainly a Gateway L4
network policy. rMDP is UDP-first (QUIC datagrams), so on such a path the whole transport
black-holes while ping/ssh work — a "network's up but rMDP won't connect" failure, common in the
SMB/MSP Zero-Trust environments we target. Design response (in draft §2.6): handshake must
actively probe datagram reachability and fail over to TCP fast; TCP fallback is the only mode on
those paths, not a degraded one; UI must surface "TCP fallback — UDP blocked upstream."

**The real number (WireGuard mesh path, 2026-08-02).** A `wg-mesh` path (route `10.255.255.1`,
~114ms RTT) was stood up — UDP passes natively, source IP preserved. Smooth-paced UDP was clean
to **~40 Mbit/s** (0.24% loss); above that the single-threaded Python sink/pacer saturated, not
the path (94 Mbit delivered at 100 offered). TCP reference 34 Mbit; Ookla host 137/99 Mbit
(Optus). **So an rMDP-relevant path gives tens of Mbit clean — 15–25× the tunnel figures, and
well above HALO's ~8 Mbit worst case (fullscreen video).** This supersedes the CGNAT/WARP numbers
for planning.

Extra nuance: on this fat pipe, burst vs smooth were both ~0% loss — **the burst penalty is a
shallow-queue effect** that only bites on constrained tunnels. Sub-frame pacing stays a
requirement (costs nothing on good paths, saves the connection on bad ones), just reframed as a
bad-link robustness feature.

**Finding 3 — QUIC over a mesh must use the peer's MESH IP, not its LAN IP (2026-08-02).** Real
QUIC-to-QUIC over the WireGuard path failed to handshake when targeting the host's LAN IP
`10.16.69.2` (timeout, zero packets) even though raw UDP to it worked. Cause: host receives on
`10.16.69.2` but routes replies back via `wg-mesh src 10.255.255.2`, so replies come from a
*different* source IP. Raw UDP `recvfrom` accepts any source; **QUIC binds to the peer address and
drops replies from an unexpected source**, so the handshake never completes. Fix: target the mesh
IP `10.255.255.2` (symmetric). **rMDP consequence: over WireGuard/Tailscale-style overlays or
asymmetric NAT, connect to the peer on the address it will source replies from (the overlay
address), not a LAN address — the peer-discovery/handshake must surface that. Classic "works in
raw UDP, fails in QUIC" trap.**

Once connected, QUIC was clean at 5 Mbit but lost 31%/96% at 10/20 Mbit — **all the aioquic
single-threaded Python echo server saturating, NOT the path or Apple's QUIC.** Proof: raw UDP
clean to 40M on same path; server-received = client-echoed exactly (zero return loss, the drop is
the server's socket buffer); and Apple's `transportSmoothedRTT` stayed ~140ms / min ~99ms while
only app-level round-trip ballooned. So QUIC datagrams + Apple telemetry both work correctly over
WireGuard; the ceiling in that test was the test server. Confirms [[spike-001-quic-pacing]]
behaviour holds on a non-CGNAT path.
