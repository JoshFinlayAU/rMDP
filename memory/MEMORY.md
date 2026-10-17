# rMDP — Private Memory Index

Facts specific to this spoke. One line per memory file.

- [HALO algorithm v0.1](halo-algorithm-v0.1.md) — the dual-plane adaptive encoding design; why it inverts Parsec's priorities.
- [Latency targets](rmdp-latency-targets.md) — what we're aiming for and the published numbers it's calibrated against.
- [Open questions](rmdp-open-questions.md) — unresolved unknowns, including the QUIC pacing spike that blocks the transport layer.
- [Spike 001 — QUIC pacing](spike-001-quic-pacing.md) — RESOLVED: no rate-control API, use QUIC anyway, pace at app layer; gate on delay not loss.
- [Path testing findings](path-testing-findings.md) — sub-frame pacing is mandatory; WARP overlays silently drop UDP; spike Mbit numbers are tunnel-limited, not real WAN.
- [Latency harness](latency-harness.md) — first real SPM package; watermark method validated; H.264 encode→decode floor ~8ms 1080p / ~19ms 4K on M4 Pro; SCK delivers ~2ms before scanout (capture term ≈0).
- [Mosh ideas](mosh-ideas.md) — adopt state-sync framing, half-RTT self-clocking, confidence-gated scroll/drag speculation; content prediction stays deferred.
- [Scroll POC](scroll-poc.md) — speculative scroll built & verified; perceived latency RTT→0, edge cost = scrollSpeed × RTT; cap the rate on high-RTT links.
- [CLASSIFY layer](classify-layer.md) — tile ledger + classifier built & measured; CPU classify viable at 4K (dirty 0.46ms), overturns the GPU-hashing assumption.
- [CRISP plane](crisp-plane.md) — lossless REF/PAL/RAW + scroll built & measured; text desktop 0.035–0.2 Mbit/s pixel-exact; scroll detection must feed the classifier.
- [Cursor offset issue](cursor-offset-issue.md) — field report: CONFIRMED pure 2× Retina scale bug (probe 2026-10-17); DisplayGeometry is the fix; same root cause as input-injection accuracy.
- [Git remote](git-remote.md) — GitHub JoshFinlayAU/mrdp (spelled mrdp); history starts 2026-10-17 initial import.
