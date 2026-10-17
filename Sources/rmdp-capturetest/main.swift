// rMDP capture probe — run on a CONSOLE session with Screen Recording granted.
//
// Verifies ScreenCaptureKit actually delivers frames on this machine and reports:
//   - frame delivery rate and status-flag breakdown (.complete/.idle/.blank/…)
//   - dirty-rect coverage (how much of the screen the compositor says changed)
//   - inter-frame delivery jitter (the capture side of motion-to-photon)
//
// This is the piece the headless agent session can't run (0 displays); it's for you
// to run at the console. It does NOT need to be a .app for a quick test, but if TCC
// is flaky from a .build/ binary, wrap it per CLAUDE.md notes.

import Foundation
import ScreenCaptureKit
import CoreVideo
import RMDPMeasure
import RMDPCapture

func envInt(_ k: String, _ d: Int) -> Int { ProcessInfo.processInfo.environment[k].flatMap(Int.init) ?? d }
let seconds = envInt("RMDP_SECONDS", 5)
let fps = envInt("RMDP_FPS", 60)

print("rMDP capture probe — \(seconds)s at up to \(fps)fps")
print("Screen Recording preflight: \(CGPreflightScreenCaptureAccess())\n")

let jitter = LatencyRecorder(capacity: 10_000)
var frameCount = 0
var lastArrival: UInt64 = 0
var statusCounts: [Int: Int] = [:]
var dirtyCoverageSum = 0.0
let lock = NSLock()

let capture = ScreenCapture { frame in
    let now = MonotonicClock.nowNanos()
    lock.lock()
    frameCount += 1
    statusCounts[frame.status.rawValue, default: 0] += 1
    if lastArrival != 0 { jitter.record(MonotonicClock.millis(from: lastArrival, to: now)) }
    lastArrival = now
    // dirty coverage as a fraction of content rect
    let area = frame.contentRect.width * frame.contentRect.height
    if area > 0 {
        let dirty = frame.dirtyRects.reduce(0.0) { $0 + $1.width * $1.height }
        dirtyCoverageSum += min(1.0, dirty / area)
    }
    lock.unlock()
}

let started = DispatchSemaphore(value: 0)
var startError: Error?
capture.start(fps: fps) { err in startError = err; started.signal() }
_ = started.wait(timeout: .now() + 10)

if let startError {
    print("❌ capture failed to start: \(startError)")
    print("   (headless/SSH sessions report 0 displays and cannot capture — run at the console)")
    exit(2)
}

Thread.sleep(forTimeInterval: Double(seconds))
let stopped = DispatchSemaphore(value: 0)
capture.stop { stopped.signal() }
_ = stopped.wait(timeout: .now() + 5)

lock.lock()
print("frames delivered: \(frameCount)  (\(String(format: "%.1f", Double(frameCount)/Double(seconds))) fps effective)")
let statusName = [0: "complete", 1: "idle", 2: "blank", 3: "suspended", 4: "started", 5: "stopped"]
for (raw, n) in statusCounts.sorted(by: { $0.key < $1.key }) {
    print("  status .\(statusName[raw] ?? "?(\(raw))"): \(n)")
}
print("inter-frame delivery jitter: \(jitter.summarize())")
if frameCount > 0 {
    print(String(format: "avg dirty-rect coverage: %.1f%% of screen per frame",
                 100.0 * dirtyCoverageSum / Double(frameCount)))
}
lock.unlock()
