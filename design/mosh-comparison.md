# What rMDP should steal from Mosh (and what it shouldn't)

**2026-08-02.** Prompted by "look at SSH vs Mosh." Short version: Mosh and rMDP are the same idea
in different resolutions — *synchronize a remote object to its latest state over a lossy datagram
link, and hide RTT with local speculation.* Mosh proved the architecture rMDP already leans on,
and it hands us two concrete techniques plus one honest boundary.

## SSH vs Mosh, in one line each

- **SSH** = an encrypted **byte stream over TCP**. Every byte delivered reliably, in order,
  retransmitted on loss. A keystroke's echo is a full round trip; a lost packet stalls
  *everything* behind it (head-of-line blocking); the session dies when your IP changes or the
  laptop sleeps.
- **Mosh** = **state synchronization over UDP** (SSP). It doesn't ship bytes; it ships the *diff
  between two numbered states of an object* (the terminal screen), always racing toward the
  latest state, and it speculatively echoes your keystrokes locally so typing feels instant.
  ([mosh.org](https://mosh.org/), [paper](https://mosh.org/mosh-paper.pdf))

The leap Mosh made is the one rMDP is built on: **stop thinking "stream," start thinking "sync
the viewer's copy of the screen to the host's current screen."**

## The three SSP mechanics

1. **Idempotent diffs, latest-wins, no retransmission.** Every datagram is a self-contained
   "Instruction": *source state N → target state M, here's the binary diff.* If it's lost, the
   next datagram just carries you from N to the *newest* state — there is nothing to retransmit,
   because stale intermediate states have no value. Losses cost latency, never correctness.
2. **The sender collapses intermediate states.** It always diffs toward the latest state, skipping
   screens the client never needs to see. Its **minimum frame interval is half the smoothed RTT**,
   so roughly one Instruction is in flight at a time — self-clocking rate control that never fills
   the buffer.
3. **Roaming for free.** The highest-sequence authentic packet redefines the server's target
   address; heartbeats every 3 s keep NAT open and detect moves. Survives sleep and network
   changes with no reconnect.

And the interactivity trick: **predictive echo in epochs.** Mosh runs a model of the terminal,
predicts each keystroke's effect, and shows it *only when confident* (a prior prediction on that
row was confirmed). Unconfirmed predictions are **underlined** and reconciled within one RTT;
hard-to-predict input (arrows, ctrl chars) **increments the epoch** and drops back to silent
background prediction. Result: **70% of keystrokes displayed instantly, ~5 ms median vs SSH's
503 ms on 3G.**

---

## What rMDP already does that Mosh validates (independent confirmation, no change needed)

- **Unreliable datagrams, drop stale frames, send the latest** → our QUIC datagram transport +
  skipping `.idle`/stale frames. Mosh is a second, battle-tested vote for exactly this.
- **Idempotent diffs, no retransmission** → the crisp plane is *SSP for pixels*. A lost tile is
  re-queued, not retransmitted; `REF`/`SCROLL` tiles reference a numbered prior state; LTR video
  recovery diffs against the last acknowledged reference frame. Mosh's "diff between any two
  numbered states" **is** our tile-cache model. The tile ledger is what makes SSP tractable for a
  screen — a pixel-level "diff any two states" would be absurd, but a *changed-tiles* diff is
  cheap, which is the whole point of §2.3.
- **Roaming** → QUIC connection migration covers most of it (Wi-Fi→cellular, IP change).

The mental-model win to adopt explicitly: **rMDP is not "a stream of frames," it is "keep the
viewer's tile-state synchronized to the host's current tile-state."** The refine queue, the crisp
plane, and dropping stale frames all fall out of that framing cleanly. Write the protocol in those
terms.

---

## Two things worth stealing

### 1. Mosh's half-RTT self-clocking as an upper bound on the pacer

Spike 001 established rMDP must pace at the app layer and gate on delay (QUIC will happily build a
2.5 s queue). Mosh adds a clean *self-clocking* rule on top: **don't emit the next state update
until the previous is ~acknowledged; floor the inter-update interval at ½·smoothedRTT so ~one
update is in flight.** On a 150 ms WAN link that caps the *state-sync* cadence at ~13 Hz when the
link is slow — which is plenty for a mostly-static desktop and structurally prevents bufferbloat,
complementing (not replacing) the delay-gradient controller. It's most natural for the **crisp
plane and control channel**; the video plane keeps its own higher cadence when there's motion and
bandwidth. Add `stateSyncMinInterval = 0.5 · smoothedRTT` to `HALOConfig`.

### 2. The epoch/confidence framework for speculative rendering — applied where we're *more*
confident than Mosh

The draft (§2.8) deferred speculative echo because "we can't know where a text field is." That's
right for *app content* (see below) — but Mosh's real contribution isn't the terminal model, it's
the **discipline**: predict tentatively, display only when confident, mark unconfirmed state
visually, reconcile within one RTT, and back off when wrong. Applied to the interactions rMDP
*can* predict locally with high confidence, it's a large perceived-latency win with a safe
fallback:

- **Cursor** — already local (design decision), effectively a 100 %-confidence prediction. Free,
  already in.
- **Scroll** — a scroll-wheel/trackpad event almost always shifts the content region by a known
  delta *known locally at the client*. The client can **speculatively shift already-decoded tiles
  vertically and display immediately**, then reconcile against the host's next frame — this is
  Hume's "client-side scroll" idea given Mosh's confidence framing. rMDP already detects scroll
  server-side (tile-row hashing → `SCROLL` refs), so both ends agree on the model; the client just
  applies it a round trip early. Scrolling is the #2 desktop interaction after typing and the
  worst case for a naive stream — this is the biggest single perceived-latency prize.
- **Window drag** — dragging a title bar moves a known region with the cursor; speculatively
  translate that region's last-decoded tiles locally, reconcile on arrival.

Borrow Mosh's machinery verbatim: **epochs** (a batch of speculative shifts that will all be right
or all wrong), **confidence gating** (only show speculation once the host confirms the interaction
mode — e.g. the first scroll frame came back consistent), and **cheap rollback** (on mismatch,
snap to the host frame; at worst the user saw ≤1 RTT of a slightly-wrong shift, exactly Mosh's
guarantee). No visible "underline" needed for pixels, but the same *reconcile-within-one-RTT*
contract holds. This upgrades scroll/drag in §2.8 from "deferred" to "designed, confidence-gated."

---

## What does NOT transfer — and Mosh shows why the deferral was right

Mosh predicts by running a **complete model of the server** (it *is* a terminal emulator; it knows
exactly what `a` does at the cursor). rMDP cannot run a model of an arbitrary macOS app — we have
no idea what pixels a keystroke produces in Photoshop, a browser, or a game. So **speculative
prediction of app *content* stays off the table**, precisely as §2.8 said. The lesson from Mosh is
to speculate only on the *geometry* we control locally (cursor position, scroll offset, drag
translation), never on *content* we'd have to invent. Getting a content prediction wrong is worse
than the latency; getting a scroll-offset prediction wrong costs ≤1 RTT and self-heals.

Also note the resolution gap: Mosh's object is ~kilobytes of character cells, so "diff any two
states" is trivial and it can afford a full server model. rMDP's object is megabytes of pixels, so
the tile ledger + hashing is the price of admission that makes the same SSP model affordable. We
don't get Mosh's techniques for free — the tile architecture is what earns them.

## Net change to the design

- §2.7: add `stateSyncMinInterval = 0.5·smoothedRTT` self-clocking as an upper bound on the crisp/
  control cadence, above the delay-gradient controller.
- §2.8: promote **scroll** and **window-drag** speculation from "deferred" to
  "confidence-gated speculative rendering," using Mosh's epoch/confidence/one-RTT-reconcile model;
  keep app-content prediction deferred.
- Framing: state the protocol as *tile-state synchronization to latest*, not a frame stream.

## Sources

- [Mosh: the mobile shell](https://mosh.org/)
- [Winstein & Balakrishnan, *Mosh: An Interactive Remote Shell for Mobile Clients*, USENIX ATC 2012](https://mosh.org/mosh-paper.pdf)
- [Fermat's Library annotated Mosh paper](https://fermatslibrary.com/s/mosh-an-interactive-remote-shell-for-mobile-clients)
- [mosh(1) man page — predictive echo / epochs](https://man.archlinux.org/man/mosh.1.en)
