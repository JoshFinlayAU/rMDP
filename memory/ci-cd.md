---
name: ci-cd
description: GitHub Actions CI (macos-26, warnings-as-errors, tests, bench smoke) + tag-driven release (ad-hoc signed arm64 tarball); what CI can't cover
metadata:
  type: project
---

Added 2026-10-17 (PR #1). `.github/workflows/ci.yml` runs on push to main + PRs on GitHub's
**`macos-26` arm64** image (GA; default Xcode 26 ships swift-tools 6.2+). Gates: debug+tests and
release builds with `-warnings-as-errors`, `swift test --parallel`, smoke-run of headless benches
(`rmdp-scrollpoc` / `rmdp-crispbench` exit 1 on correctness failure; `rmdp-classifybench` just runs).

`.github/workflows/release.yml`: on `v*` tag (or manual dispatch with a tag) → same test gate →
ad-hoc `codesign -s -` arm64 `rmdp-host` + `rmdp-viewer` → tarball + sha256 → GitHub Release
(`v0.*` = prerelease). **Not Developer-ID signed / notarised** — needs Apple Developer secrets;
until then users must `xattr -d com.apple.quarantine`, and every build re-prompts TCC.

**CI can't cover** (no console session / TCC on runners): ScreenCaptureKit capture, CGEvent input,
end-to-end feel. The real-codec test skips if the runner VM lacks a low-latency H.264 encoder
(`RMDP_REQUIRE_HW_CODEC=1` forces it).

**Gotcha seen same day:** with Josh's screen locked/asleep, SCK reports `noDisplay` exactly like a
headless session — host encodes 0 frames and the viewer shows black at 0 fps with NO error shown.
Before blaming code for 0 fps, run `rmdp-capturetest`. UX gap: host should tell the viewer why.

Related: [[mvp-status]], [[git-remote]].
