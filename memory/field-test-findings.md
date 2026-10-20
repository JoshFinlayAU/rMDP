---
name: field-test-findings
description: Real two-Mac test findings (from 2026-10-20) — managed work Mac can't accept inbound (needs reverse-connect), viewer has no connect timeout
metadata:
  type: project
---

Two-Mac LAN testing of v0.1.0 started 2026-10-20. Josh's Macs: this one (personal, wired `en9`
10.80.111.0/24, firewall off) and a **work Mac (MDM-managed, on Wi-Fi with private MAC)**.

1. **Managed Macs can't be hosts.** Work Mac's MDM profile enforces the application firewall
   (stealth/block) — even with local admin, inbound ping/TCP/UDP is silently dropped. Fix for the
   test: swap roles (managed Mac = viewer, outbound only). **Design requirement, not an edge case:**
   a reverse-connect mode where the host dials OUT (to the viewer or a relay). Same machinery as NAT
   traversal / CGNAT and the WARP UDP-block finding ([[path-testing-findings]]). Never suggest
   circumventing an employer's MDM profile.
2. **Viewer has no connect timeout** — `openStream()` hangs forever when nothing answers. Needs a
   deadline + a clear error ("no response from host — UDP 7443 blocked or host unreachable").
4. **Ultrawide grey screen (FIXED v0.1.1):** HW H.264 low-latency encoder fails EVERY frame at
   5120×1440 (session creates fine, callback -19354, no sample) — works ≤4096 wide; HEVC LL and
   non-LL H.264 do 5120×1440 fine. Host now clamps the stream to 4096×2304 (aspect kept; 5120×1440 →
   4096×1152, loopback 58 fps, e2e p50 14 ms), self-tests one encode at startup and refuses to start
   on failure, and reports encode errors in its 1 s stats. **Follow-up:** negotiate HEVC so
   ultrawides stream unscaled.
5. Viewer connect timeout (FIXED v0.1.1): 8 s deadline with a "UDP blocked?" explanation.
3. Diagnosis recipe that worked: ARP resolves but ping + TCP time out (not refused) ⇒ target is
   dropping inbound, not a routing problem. A 5a:/xa: locally-administered MAC ⇒ macOS private Wi-Fi
   address ⇒ also consider AP client isolation.

Related: [[mvp-status]], [[transport-api]].
