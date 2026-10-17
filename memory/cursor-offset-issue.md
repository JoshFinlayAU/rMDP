---
name: cursor-offset-issue
description: Field observation (Josh) — remote cursor was offset from the real cursor by a substantial amount in a client test; likely the Retina points/pixels transform
metadata:
  type: project
---

**Field report (Josh, 2026-08-03):** in a client test, the cursor shown on the stream did **not**
match his actual cursor — off by a substantial amount. (Which tool showed this is unconfirmed —
rMDP's own `rmdp-capturetest` renders nothing and the pipeline uses synthetic frames, so this was
likely a reference tool or a console-side setup; clarify.)

**Why this matters / likely cause.** This is exactly the gotcha CLAUDE.md and draft §2.8 flag:
- Capture is in **pixels** (Retina 2× → a 1920×1080-point display captures at 3840×2160 backing).
- Pointer/cursor position is in **points**. Draw the remote cursor using pixel coords as if they
  were points (or scale by the wrong factor) → an offset that **grows with distance from the
  origin** (a 2× error at Retina). This is the #1 suspect for a "substantial" mismatch.
- Other candidates, distinguishable by symptom:
  - **Constant** offset everywhere → Y-axis origin flip (AppKit bottom-left vs Quartz top-left),
    or the display's origin in global multi-monitor space not being (0,0), or the window's
    content-inset not subtracted.
  - Offset **scales with window size** → stream captured at one resolution, displayed in a
    differently-sized window without applying the same scale to cursor coords.
  - Small (few px) constant → cursor **hotspot** (click-point vs image top-left) not applied.

**Design implication.** rMDP's design deliberately makes the cursor **local metadata drawn
client-side** (§2.8) — so ANY offset lives entirely in the one capture-pixels→local-point
coordinate transform. This is precisely the "get the coordinate transform into ONE tested function
early and never inline it again" rule (CLAUDE.md gotchas). Action items when we build the
cursor/input layer:
1. One `struct DisplayGeometry` (backingScaleFactor, display origin, capture size, view size) with
   a single tested `captureToView` / `viewToCapture` function; unit-test round-trips at 1×/2× and
   mixed-DPI multi-monitor.
2. Apply cursor hotspot explicitly.
3. The same transform governs INPUT injection (viewToCapture for CGEventPost) — an input-mapping
   offset would make clicks land in the wrong place too, so this bug and input accuracy are the
   same root cause. Fix once, test once.

To pin the exact cause next time: note whether the offset is **constant** or **grows as the
pointer moves away from a corner**, and whether the viewer window matches the capture resolution.

**Built 2026-08-03 (no stream-rendering client ever existed — the reported observation was from a
reference tool or a console setup, not rMDP code):**
- `RMDPGeometry.DisplayGeometry` — the single tested transform (capture pixels ↔ content points,
  with AppKit bottom-left flip helpers). Pure ratio `contentPoints/capturePixels` absorbs Retina
  scale + any stream downscale. 5 unit tests incl. one proving the naive bug's offset **grows with
  distance** (0 at origin, 960pt mid-screen, 1920pt at edge on a 2× display). This is THE function
  cursor draw AND `CGEventPost` input injection must both use — same root cause, one fix.
- `rmdp-cursorprobe` — console tool (needs a display; exits cleanly headless). Reads real display
  geometry + live `NSEvent.mouseLocation`, prints correct-vs-naive draw position and the gap as
  you move the cursor. Josh runs it on console to confirm scale-bug vs origin-flip and give exact
  numbers.
- **Also noted:** `rmdp-capturetest` sets the stream to POINT size (`display.width`), i.e. a
  downscaled stream, not native pixels — that scale choice itself feeds the transform and is worth
  deciding deliberately.

Related: [[halo-algorithm-v0.1]] (§2.8 input/cursor), [[latency-harness]] (capture side).

**CONFIRMED 2026-10-17 (Josh ran `rmdp-cursorprobe` on console, MacBook display 1512×982pt /
3024×1964px, 2×):** pure **Retina scale bug**. Naive gap = 0 at top-left (capture origin), grows
linearly with distance: 982pt at bottom-left, 1803pt at bottom-right (= √(1512²+982²), i.e. exactly
the full point-coordinate distance). No constant component → no origin/multi-monitor offset on a
single display; the Y flip is handled. `DisplayGeometry` as built is the fix. Mixed-DPI
multi-monitor still untested.
