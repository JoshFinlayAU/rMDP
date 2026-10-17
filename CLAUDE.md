# rMDP — software spoke

Remote macOS Display Protocol — a custom macOS→macOS remote desktop stack: capture, adaptive encode, transport, decode, and input injection, tuned so a desktop across the world still feels local.

Inherits the hub's global rules (see `../../CLAUDE.md`). This file adds spoke-specific context.

## What this actually is

Two halves plus a wire format:

- **Host (server)** — runs on the machine being controlled. Captures the display, encodes, streams, and injects incoming input events.
- **Viewer (client)** — renders the decoded stream, captures local keyboard/mouse/trackpad, sends input upstream, reports link quality back.
- **Protocol** — the framing/negotiation layer between them (`rMDP`): capability handshake, stream setup, frame/packet framing, input channel, control channel (resize, display switch, clipboard, quality hints), and the telemetry the adaptive encoder feeds on.

The headline feature is **dynamic scaling**: bitrate, resolution, framerate, and codec settings move in response to measured bandwidth, RTT, loss, and encoder/decoder load. Treat that control loop as the heart of the project — most design decisions should be argued in terms of "what does this do to perceived latency and bandwidth under a bad link".

## Stack

Nothing is locked in until it's in the repo — check what's actually there before assuming. The expected shape:

- **Language:** Swift (macOS 14+) for anything touching Apple frameworks; Swift Package Manager for layout (`Package.swift`, `Sources/`, `Tests/`). C/C++ only where a codec or transport library forces it, bridged via a small Swift wrapper.
- **Capture:** `ScreenCaptureKit` (`SCStream`) — the only sanctioned path on modern macOS. Gives dirty-rect metadata, per-display/per-window capture, and cursor handling. Avoid the deprecated `CGDisplayStream`.
- **Encode/decode:** `VideoToolbox` hardware H.264/HEVC on both ends (`VTCompressionSession` / `VTDecompressionSession`). Apple Silicon media engine does the heavy lifting; keep sessions long-lived and reconfigure via properties rather than tearing down.
- **Render:** Metal (`CAMetalLayer`) with `CVPixelBuffer`/`IOSurface` handed straight to the GPU — no CPU-side pixel copies in the hot path.
- **Input injection:** `CGEvent` posting via `CGEventPost`/`CGEventTapLocation`, or `IOHIDUserDevice` if virtual-device behaviour is needed for gaming-grade input.
- **Transport:** UDP-based with its own reliability/congestion handling (QUIC via `Network.framework` `NWConnection`, or a hand-rolled datagram protocol). TCP only as a fallback for hostile networks. `Network.framework` also gives Bonjour discovery on LAN.
- **Audio (if/when):** `CoreAudio` tap + Opus, on its own stream with its own pacing.
- **UI:** SwiftUI for viewer chrome and host preferences; the video surface itself is an `NSViewRepresentable` wrapping the Metal layer.

Record the *actual* choices in `memory/` as they're made, with the reasoning — especially anywhere we deviate from the list above.

## How to run / build / test

Confirm these against the repo before quoting them back; update this section when they change.

```bash
swift build                      # debug build
swift build -c release           # release — always benchmark against this, never debug
swift test                       # unit tests
swift test --filter ProtocolTests

# Run the two halves locally (separate terminals)
swift run rmdp-host --listen 0.0.0.0:7443 --display 1
swift run rmdp-viewer --connect 127.0.0.1:7443
```

If an Xcode project appears instead of / alongside SPM:

```bash
xcodebuild -scheme rMDPHost -configuration Release build
xcodebuild -scheme rMDPHost test -destination 'platform=macOS'
```

**Before claiming a change works:**

1. `swift build -c release` clean.
2. `swift test` green.
3. For anything touching capture, encode, transport, or the adaptive loop — **run it**. A remote desktop bug is a *feel* bug; unit tests won't catch a stall, a stutter, or a cursor that lags 80ms behind. Loopback host+viewer on one machine, then two machines on LAN.
4. For adaptive-loop changes, run under simulated impairment and report the numbers, not a vibe:
   ```bash
   # macOS Network Link Conditioner (Additional Tools for Xcode), or:
   sudo dnctl pipe 1 config bw 5Mbit/s delay 120 plr 0.02
   sudo pfctl -f /etc/pf.conf -e     # with a dummynet anchor routing test traffic to pipe 1
   sudo dnctl -q flush               # tear down when done
   ```

## Permissions & entitlements (first-run gotcha)

The host needs TCC grants that **cannot** be scripted around, and a fresh build gets a new identity each time you change signing:

- **Screen Recording** — System Settings → Privacy & Security → Screen Recording. Required for `SCStream`. Denied = black frames or a stream that never starts, often with no useful error.
- **Accessibility** — required for `CGEventPost` input injection. Denied = events silently swallowed, no error at all.
- **Input Monitoring** — needed on the viewer side if intercepting keys via event taps.

Notes that will save an hour:
- TCC is keyed to the code signature + bundle path. Rebuilding an unsigned binary or moving it re-triggers (or silently loses) the grant. Sign consistently, even ad-hoc, and keep the built path stable.
- `swift run` binaries in `.build/` are awkward for TCC. If permissions get flaky, package into a proper `.app` bundle for testing.
- `tccutil reset ScreenCapture <bundle-id>` resets a grant — **ask before running it**, it clears real user state.
- SSH/headless sessions cannot grant TCC and often can't capture at all. Test on a real logged-in console session.

## Conventions

- **Swift API Design Guidelines**, plain and boring. `swift-format` / SwiftLint if configured; match surrounding style over personal preference.
- **Layer boundaries are real.** `Capture` → `Encode` → `Transport` → `Decode` → `Render`, plus `Input` and `Control` side channels. No layer reaches around another. The adaptive controller reads telemetry from all of them but is its own component — don't scatter rate decisions into the encoder.
- **Protocol code is versioned and testable in isolation.** Wire format lives in one place, has explicit version negotiation from day one, and is covered by round-trip encode/decode tests including truncated and malformed input. Never let framing logic leak into transport or app code.
- **Wire format changes are breaking changes.** Bump the protocol version, note it in `memory/`, and state the compatibility impact in the commit body.
- **Concurrency:** Swift structured concurrency (`async`/`await`, actors) for control flow; dedicated serial `DispatchQueue`s for the capture and encode callbacks — those run on framework-owned threads with hard timing budgets, so no `await` on a lock in a frame callback. Mark the hot path clearly.
- **Never block the frame path.** No allocation, logging, JSON, or locks in per-frame code. Buffer pools (`CVPixelBufferPool`) over fresh allocations. Log via a lock-free ring buffer drained off-thread.
- **Latency is a first-class metric.** Timestamp frames at capture and carry that through to render so end-to-end latency is measurable, not guessed. Any change to the hot path gets a before/after number: p50/p95/p99 latency, bandwidth, dropped frames.
- **No magic constants in the adaptive loop.** Thresholds, ramp rates, and hysteresis windows are named, documented, and tunable in one config struct. This code will be tuned a hundred times — make that cheap.
- **Errors:** typed Swift `Error`s per layer. Network paths degrade gracefully — a bad link reconnects and drops quality, it never crashes or hangs the UI.
- **Git:** branch before committing (`feat/adaptive-hysteresis`, `fix/sck-cursor-offset`). Commit/push only when asked. Commit body says *why*, and for hot-path work includes the measurement.

## Gotchas

- **ScreenCaptureKit delivers frames with status flags** — `.idle`, `.blank`, `.suspended`. A "frame" isn't always new pixels. Check `SCStreamFrameInfo` before encoding or you'll burn bandwidth on duplicates and break dirty-rect logic.
- **Retina scaling.** Points vs pixels vs backing scale factor. Capture is in pixels, input events are in points, mixed-DPI multi-monitor setups make this genuinely nasty. Get the coordinate transform into one tested function early and never inline it again.
- **Cursor**: hardware cursor is composited separately. Decide deliberately — burned into the stream (simple, laggy) or sent as metadata and drawn client-side (responsive, more work). Client-side is the right answer for the "feels real" goal.
- **HDR / P3 displays.** Color space mismatch shows up as washed-out or oversaturated output. Pin and convert explicitly; don't rely on defaults matching between capture and render.
- **`VTCompressionSession` reconfiguration** mid-stream can force a keyframe or silently ignore the property. Adaptive resolution changes need an explicit IDR and viewer-side handling of the resolution switch.
- **Encoder/decoder latency ≠ network latency.** B-frames and lookahead will destroy interactivity — disable them, force low-latency / real-time rate control mode.
- **App Nap and display sleep** will throttle or kill the host. Take a power assertion, disable App Nap, and decide what "remote user connected" means for local sleep behaviour.
- **NAT traversal** is a real project, not a footnote. LAN first (Bonjour), then decide on relay vs STUN/TURN vs Tailscale-style overlay before promising "from anywhere in the world".
- **Security is not optional** — this streams a live desktop and accepts remote input. Encrypted transport and authenticated peers from the start, not bolted on later. Never log frame contents, clipboard data, or keystrokes.

## Notes

- Private memory: `memory/` · Spoke skills: `skills/`
- Keep design decisions with their rationale in `memory/` — codec choice, transport choice, adaptive-loop tuning, protocol version history. Benchmark numbers belong there too, so later tuning has a baseline to argue against.
- Confirm before destructive git ops (force-push, reset --hard, branch deletes).

## Installed skills

Reach for these when the task matches — they're installed in `.claude/skills/`:

- **macos-development** — Comprehensive macOS development guidance including Swift 6+, SwiftUI, SwiftData, architecture patterns, AppKit bridging, and macOS 26 Tahoe APIs. Use for macOS code review, best practices, UI review, or platform-specific features.  _(skills.sh: rshankras/claude-code-apple-skills)_
