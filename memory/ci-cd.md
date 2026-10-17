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
arm64 `rmdp-host` + `rmdp-viewer` → tarball + sha256 → GitHub Release (`v0.*` = prerelease).
**Signing (decided 2026-10-17 by Josh):** Developer ID Application **Serenity Space Pty Ltd, team
4S7BG5A4XV** (the only Developer ID cert in his keychain), hardened runtime + secure timestamp,
identifiers `au.com.athenanetworks.rmdp.{host,viewer}`; notarised via **App Store Connect API key**
(`notarytool --wait`). Secrets live in the GitHub Environment **`release`** (allowed refs: `v*` tags,
`main`): DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD, NOTARY_API_KEY_P8_BASE64,
NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID. Missing secrets ⇒ falls back to ad-hoc with a warning.
Bare Mach-O can't be stapled ⇒ Gatekeeper checks the ticket online at first launch. Both binaries
verified to run under hardened runtime (ad-hoc + `--options runtime`, loopback) — the first-run
`/usr/bin/openssl` identity generation path was NOT re-exercised signed. Stable Developer ID
signature ⇒ TCC grants survive upgrades (ad-hoc lost them every build).

**CI can't cover** (no console session / TCC on runners): ScreenCaptureKit capture, CGEvent input,
end-to-end feel. The real-codec test skips if the runner VM lacks a low-latency H.264 encoder
(`RMDP_REQUIRE_HW_CODEC=1` forces it).

**Gotcha seen same day:** with Josh's screen locked/asleep, SCK reports `noDisplay` exactly like a
headless session — host encodes 0 frames and the viewer shows black at 0 fps with NO error shown.
Before blaming code for 0 fps, run `rmdp-capturetest`. UX gap: host should tell the viewer why.

Related: [[mvp-status]], [[git-remote]].
