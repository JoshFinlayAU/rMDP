---
name: halo-algorithm-v0.1
description: HALO — the proposed dual-plane adaptive encoding algorithm for rMDP, drafted 2026-08-01
metadata:
  type: project
---

**HALO** (Hybrid Adaptive Latency-Optimised) is rMDP's proprietary encoding design. Full draft:
`design/rmdp-algorithm-draft-v0.1.md`. Nothing implemented as of 2026-08-01 — this is a design
proposal only.

Core shape: a 64×64 tile ledger classifies each changed screen region into a **video plane**
(VideoToolbox HEVC/H.264, low-latency RC, bounded to the moving region's bounding box) or a
**crisp plane** (lossless tile cache / scroll refs / palette / zstd-with-trained-dictionary).
A **refine queue** rebuilds tiles to lossless once motion stops. Transport is QUIC datagrams
(RFC 9221) over `Network.framework`; congestion control is SQP-style (frame bursts as the
bandwidth probe). Loss recovery uses Long Term Reference frames + adaptive FEC — never periodic
IDRs.

**The decision that drives everything:** priority order is latency → text quality → framerate →
bandwidth. This deliberately *inverts* Parsec's ordering (latency → framerate → quality), which
is right for games and wrong for a desktop. Consequence: the crisp plane is always lossless and
never negotiates quality — under congestion we send fewer tiles, never worse tiles. Text
sharpness is not on the degradation ladder at all.

**Prior art it descends from:** Citrix Thinwire selective encoding + Intelligent Build to
Lossless, and Teradici PCoIP progressive build. Both solved this problem correctly; neither
ships on macOS. That's the gap rMDP fills.

**Blocking unknown:** whether `Network.framework` QUIC allows pacer-driven send rate control.
If not, fall back to raw UDP + Noise IK. This spike must run before anything is built on the
transport assumption — see [[rmdp-open-questions]].

Related: [[rmdp-latency-targets]]
