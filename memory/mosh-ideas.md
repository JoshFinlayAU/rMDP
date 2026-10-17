---
name: mosh-ideas
description: What rMDP adopts from Mosh — state-sync framing, half-RTT self-clocking, confidence-gated scroll/drag speculation; and why content prediction stays deferred
metadata:
  type: project
---

Analysis of SSH vs Mosh for rMDP (2026-08-02). Full writeup: `design/mosh-comparison.md`.

**Core takeaway:** Mosh and rMDP are the same idea — *synchronize a remote object to its latest
state over lossy UDP, and hide RTT with local speculation.* SSH is a reliable byte stream over
TCP (round-trip echo, head-of-line blocking, dies on IP change); Mosh (SSP) ships idempotent
diffs between numbered states of the terminal, races to latest, and predictively echoes keystrokes
(70% shown instantly, ~5ms vs SSH's 503ms on 3G). Mosh independently validates rMDP's whole
architecture: unreliable datagrams, drop stale frames, idempotent tile diffs, no retransmission,
roaming.

**Adopted into the design:**
1. **Framing** — state rMDP as "keep the viewer's tile-state synced to the host's current
   tile-state," not "a stream of frames." The crisp plane IS SSP-for-pixels; the tile ledger is
   what makes a screen-sized state-diff affordable (Mosh's terminal is KB, our screen is MB).
   Added to §2 architecture intro.
2. **Half-RTT self-clocking** (§2.7) — `stateSyncMinInterval = 0.5·smoothedRTT` as an upper bound
   on crisp/control cadence so ~one update is in flight; complements (doesn't replace) the
   delay-gradient controller from [[spike-001-quic-pacing]]. Bufferbloat-proof by construction.
3. **Confidence-gated speculative rendering** (§2.8) — promote **scroll** and **window-drag** from
   "deferred" to designed: client speculatively shifts already-decoded tiles by the locally-known
   delta and displays immediately, reconciling within one RTT. Borrow Mosh's machinery verbatim:
   epochs (all-right-or-all-wrong batches), confidence gating (speculate only after the host
   confirms the interaction mode), cheap rollback (snap to host frame on mismatch, ≤1 RTT of
   wrongness). Scroll is the biggest perceived-latency prize after typing. This is Hume's
   client-side-scroll idea given Mosh's safety framing; both ends already model scroll (tile-row
   hashing → SCROLL refs, §2.3).

**Explicitly NOT adopted — and Mosh proves the deferral right:** speculative prediction of app
*content* (what pixels a keystroke produces). Mosh predicts only because it fully models the
server (it is a terminal). rMDP can't model an arbitrary macOS app. Speculate on *geometry* we
know locally (cursor, scroll offset, drag translation), never on *content* we'd have to invent — a
wrong content guess is worse than the latency; a wrong scroll-offset guess self-heals in ≤1 RTT.

Related: [[halo-algorithm-v0.1]], [[rmdp-latency-targets]], [[spike-001-quic-pacing]].
