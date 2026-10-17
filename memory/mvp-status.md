---
name: mvp-status
description: rMDP MVP (build-order step 3) built 2026-10-17 — what works, measured loopback numbers, what's untested, what's next
metadata:
  type: project
---

**Built 2026-10-17 on `feat/mvp`.** `rmdp-host` + `rmdp-viewer`: SCStream (NV12, BT.709 pinned) →
VideoToolbox H.264 low-latency → QUIC datagrams (18-byte fragment header, 1200B datagrams) →
reassembler → VT decode → `LayerRenderer` (CAMetalLayer). Input: viewer NSView events → capture-pixel
coords via `DisplayGeometry` → reliable QUIC input stream → `InputInjector` (CGEvent). Protocol v1.

**Security:** TLS 1.3 (QUIC) with a self-signed RSA host identity (generated once via
/usr/bin/openssl, loaded in-memory, never keychain); viewer pins SHA-256 fingerprint
(SSH accept-new); password auth with constant-time compare + 1s failure delay; one viewer at a time.

**Loss policy v1:** any lost frame → freeze on last good frame, request IDR (rate-limited 250ms),
resume at next IDR. Host forced IDRs floored at 250ms — learned the hard way: drop→IDR-per-frame is
positive feedback into congestion (saw a 30 Mbit/s IDR storm into a dead link). Host watchdog drops
a viewer after 3s without control traffic (viewer pings every 500ms).

**Measured, loopback, M4 Pro, native 3024×1964, 20 Mbit cap:** e2e (host scanout → viewer GPU
complete, ping-clock-corrected) **p50 17–20 ms, p95 22–29 ms**, 0 lost; static desktop 0.2 Mbit/s,
IDR ~4.5 Mbit burst on join. Reconnect, wrong-password reject, viewer-death detection verified.

**NOT yet tested (needs Josh, two Macs on macOS 26):** input injection end to end (deliberately not
run on Josh's live desktop — loopback uses `--view-only`), LAN, WAN, dnctl impairment, scroll
direction with natural scrolling, modifier/Cmd-key combos, mixed-DPI viewer.

**Known MVP gaps (by design, next steps):** no app-layer pacer (fragments burst at line rate — fine
on LAN, will hurt on shallow-queue tunnels per [[path-testing-findings]]); no adaptive controller
(fixed bitrate); no TCP fallback (UDP-blocked paths fail); cursor shape not mirrored (local arrow
only); no clipboard; main display only; no Bonjour discovery.

Related: [[transport-api]], [[halo-algorithm-v0.1]], [[cursor-offset-issue]], [[latency-harness]].
