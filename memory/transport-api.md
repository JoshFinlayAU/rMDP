---
name: transport-api
description: rMDP transport = macOS 26 Network.framework NetworkConnection<QUIC> (streams + datagrams on one connection); old NWConnectionGroup API failed; min macOS raised to 26
metadata:
  type: project
---

Decided 2026-10-17 while starting the MVP (loopback spike, M4 Pro, macOS 26.5).

**Use the macOS 26 Swift-native API: `NetworkListener` / `NetworkConnection<QUIC>`.** One QUIC
connection gives `openStream()` / `inboundStreams {}` (reliable control + input) **and**
`conn.datagrams` (video) — exactly the design's §2.6 channel model. Verified: TLS 1.3 with a
self-signed identity, stream round-trip OK, 2000/2000 datagrams echoed.

**Why not the macOS 12+ `NWConnectionGroup`/`NWMultiplexGroup` API:** couldn't get a reliable
stream and datagrams on one connection. With `isDatagram=true` on the group, `NWConnection(from:)`
yields a *datagram flow*, and a stream opened with `isDatagram=false` options fails instantly
(`ENETDOWN`). If client and server disagree on `isDatagram` the handshake **hangs silently**.
`extract()` returns nil. Not worth more time when the 26 API just works.

**Cost:** package minimum raised **macOS 14 → 26** (swift-tools 6.2). Both ends must run macOS 26.
Deviation from CLAUDE.md's "macOS 14+" — accepted for MVP.

**Measured gotchas:**
- Awaited sequential `datagrams.send` = **263 Mbit/s, 0 loss** on loopback — plenty.
- `Task.sleep(1ms)` actually sleeps **~8ms** → never pace on Task.sleep; use a dedicated thread
  (`usleep`/`mach_wait_until`), per [[spike-001-quic-pacing]].
- In-memory identity: `SecPKCS12Import` + `kSecImportToMemoryOnly` **crashes on an EC key**
  (LibreSSL p12); RSA-2048 works. Identity generated with `/usr/bin/openssl`.
- `usableDatagramFrameSize` read 0 right after `datagrams` opened — don't trust it for MTU yet;
  use a fixed conservative 1200B.

Related: [[spike-001-quic-pacing]], [[path-testing-findings]], [[halo-algorithm-v0.1]].
