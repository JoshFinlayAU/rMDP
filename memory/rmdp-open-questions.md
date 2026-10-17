---
name: rmdp-open-questions
description: Unresolved technical questions blocking or shaping rMDP's implementation, as of 2026-08-01
metadata:
  type: project
---

Open as of 2026-08-01, ordered by how much they block:

1. ~~**Does `Network.framework` QUIC expose enough send-rate control for our own pacer?**~~
   **RESOLVED 2026-08-01 — see [[spike-001-quic-pacing]].** No rate-control API exists, but we
   use QUIC regardless and pace at the application layer. Noise IK fallback dropped.
   *Follow-on:* verify `transportSmoothedRTT` populates on a real QUIC path (reads 0.000ms on
   loopback), and compare QUIC-to-QUIC throughput against the raw-UDP curve to see what Apple's
   congestion control costs.
2. **HEVC 4:4:4 hardware encode on Apple Silicon is unconfirmed.** 4:2:2 Main10 encode *is*
   confirmed (Compressor 4.6.1+, Monterey 12.3+). Decode handles 400/420/422/444 8–10 bit.
   Verify encode support with `VTSessionCopySupportedPropertyDictionary` on target hardware.
3. **AV1 encode is not broadly available** — hardware decode from M3 onward, but encode only on
   higher-tier parts (M4 Ultra, M5 Pro/Max). Must be negotiated in the handshake, never assumed.
4. Tile size: 64×64 vs 32×32. Smaller tracks text better, costs 4× the ledger. Measure both.
5. Multi-display: one stream per display (independent adaptation, leaning this way) vs one
   composited surface (simpler).
6. Audio is out of scope for v1, but reserve channel IDs now so adding it isn't a version bump.

See [[halo-algorithm-v0.1]] for the design these bear on.
