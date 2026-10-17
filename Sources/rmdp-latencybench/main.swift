// rMDP latency harness — draft step 2.
//
// Measures the REAL VideoToolbox H.264 encode→decode latency floor on this machine,
// the term the research says dominates desktop-stream latency. Method: stamp a
// monotonic timestamp into each frame's luma via the in-band watermark, run the frame
// through the hardware encoder and decoder, read the timestamp back off the decoded
// frame, and record now − stamp. No screen capture, so no TCC grant needed.
//
// What this number is: embed → encode-queue → encode → decode-queue → decode. It is
// NOT full motion-to-photon (no capture, no display scanout) — those get added when
// the real pipeline (draft step 3) plugs into this same harness. This establishes the
// codec floor everything else is argued against.

import Foundation
import CoreMedia
import CoreVideo
import RMDPMeasure
import RMDPCodec

// MARK: - Config (env-overridable)

func envInt(_ k: String, _ d: Int) -> Int { ProcessInfo.processInfo.environment[k].flatMap(Int.init) ?? d }

let width = envInt("RMDP_W", 1920)
let height = envInt("RMDP_H", 1080)
let frames = envInt("RMDP_FRAMES", 300)
let fps = envInt("RMDP_FPS", 60)
let bitrate = envInt("RMDP_BITRATE", 20_000_000)
// Warmup frames: encoded/decoded to prime the VT sessions (first frame is an IDR and
// the media engine ramps), but excluded from the latency stats. Standard practice —
// including them just measures cold-start, not steady-state interactive latency.
let warmup = envInt("RMDP_WARMUP", 30)
// Content entropy: 0 = low (compressible bands, codec floor); 1 = high (per-pixel
// noise, worst-case full-motion). Real desktop sits near the floor most of the time.
let noise = envInt("RMDP_NOISE", 0) == 1

print("rMDP latency harness — H.264 encode→decode floor")
print("host: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("\(width)x\(height) @ \(fps)fps, \(frames) frames, \(bitrate/1_000_000) Mbit/s target, "
      + "content=\(noise ? "high-entropy" : "low-entropy")\n")

// MARK: - Pipeline

let pool = try PixelBufferPool(width: width, height: height)
let encoder = try H264Encoder(width: width, height: height, bitrateBps: bitrate)
let decoder = H264Decoder()
let wm = WatermarkCodec()
let recorder = LatencyRecorder(capacity: frames + 16)

// All bookkeeping funnels through one serial queue so LatencyRecorder stays
// single-producer regardless of which VT queue a callback lands on.
let collector = DispatchQueue(label: "rmdp.bench.collector")
var watermarkHits = 0
var compressedBytes = 0
var codedFrames = 0         // non-warmup frames that produced a bitstream
var poolFailures = 0        // couldn't get a buffer from the pool
var encodeDrops = 0         // encoder returned nil (RealTime frame drop)
var decodeFailures = 0
var submitted = 0
var resolved = 0
var allSubmitted = false
let allDone = DispatchSemaphore(value: 0)

// Paint a frame: moving diagonal luma (real work for the encoder), neutral chroma,
// then the watermark on top. Returns the stamp embedded (captured right before embed
// so paint time is excluded from the measured latency).
func paint(_ pb: CVPixelBuffer, frameIndex: Int) -> UInt64 {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    // Luma (plane 0): moving diagonal gradient — cheap per-row, gives the encoder
    // non-trivial content that changes each frame.
    let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let yw = CVPixelBufferGetWidthOfPlane(pb, 0)
    let yh = CVPixelBufferGetHeightOfPlane(pb, 0)
    let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    if noise {
        // High-entropy: fresh pseudo-random luma every frame — worst case for the
        // encoder (like full-motion video filling the screen).
        var seed = UInt64(frameIndex &+ 1) &* 0x9E3779B97F4A7C15
        for row in 0..<yh {
            let p = y + row * ybpr
            for col in 0..<yw {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                p[col] = UInt8(truncatingIfNeeded: seed)
            }
        }
    } else {
        // Low-entropy: moving diagonal bands — best case, the codec floor.
        for row in 0..<yh {
            let base = UInt8((row + frameIndex * 3) & 0xFF)
            let p = y + row * ybpr
            for col in 0..<yw { p[col] = base &+ UInt8((col >> 3) & 0x3F) }
        }
    }

    // Chroma (plane 1, interleaved CbCr, half height): neutral grey.
    let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    let ch = CVPixelBufferGetHeightOfPlane(pb, 1)
    let cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    memset(c, 128, ch * cbpr)

    // Watermark last, on top of the luma pattern.
    let stamp = MonotonicClock.nowNanos()
    wm.embed(stamp, luma: y, width: yw, height: yh, bytesPerRow: ybpr)
    return stamp
}

let frameInterval = 1.0 / Double(fps)
let runStart = DispatchTime.now().uptimeNanoseconds

for i in 0..<frames {
    // Pace submissions to the capture cadence.
    let target = runStart &+ UInt64(Double(i) * frameInterval * 1e9)
    let now = DispatchTime.now().uptimeNanoseconds
    if target > now, target - now > 1000 { usleep(useconds_t((target - now) / 1000)) }

    let pb: CVPixelBuffer
    do { pb = try pool.makeBuffer() } catch {
        collector.sync { poolFailures += 1 }; continue
    }
    _ = paint(pb, frameIndex: i)
    let pts = CMTime(value: Int64(i), timescale: Int32(fps))
    collector.sync { submitted += 1 }
    let frameIndex = i

    // Every submitted frame resolves exactly once — encode-drop, decode-fail, or
    // decoded. `resolve()` is the single place that advances the completion counter.
    func resolve(_ body: () -> Void) {
        body()
        resolved += 1
        if allSubmitted && resolved == submitted { allDone.signal() }
    }

    do {
        try encoder.encode(pb, pts: pts) { sampleBuffer in
            guard let sampleBuffer else { collector.async { resolve { encodeDrops += 1 } }; return }
            let size = CMSampleBufferGetTotalSampleSize(sampleBuffer)
            do {
                try decoder.decode(sampleBuffer) { image in
                    let t1 = MonotonicClock.nowNanos()
                    var stamp: UInt64? = nil
                    if let image {
                        stamp = withLumaPlaneReadOnly(image) { luma, w, h, bpr in
                            wm.extract(luma: luma, width: w, height: h, bytesPerRow: bpr)
                        }
                    }
                    collector.async {
                        resolve {
                            let isWarmup = frameIndex < warmup
                            if !isWarmup { compressedBytes += size; codedFrames += 1 }
                            if let s = stamp {
                                if !isWarmup { recorder.record(MonotonicClock.millis(from: s, to: t1)) }
                                watermarkHits += 1
                            } else if image == nil {
                                decodeFailures += 1
                            }
                        }
                    }
                }
            } catch {
                collector.async { resolve { decodeFailures += 1 } }
            }
        }
    } catch {
        collector.sync { resolve { encodeDrops += 1 } }
    }
}

encoder.finish()
decoder.finish()
// Mark submission complete and re-check in case everything already resolved.
collector.sync {
    allSubmitted = true
    if resolved == submitted { allDone.signal() }
}

if allDone.wait(timeout: .now() + 60) == .timedOut {
    collector.sync { print("⚠️  timed out: resolved \(resolved)/\(submitted) submitted") }
}

// MARK: - Report

collector.sync {
    let s = recorder.summarize()
    let avgKB = codedFrames > 0 ? Double(compressedBytes) / Double(codedFrames) / 1024.0 : 0
    let mbitAtFps = codedFrames > 0 ? Double(compressedBytes) * 8.0 / Double(codedFrames) * Double(fps) / 1e6 : 0
    let decoded = watermarkHits + decodeFailures
    print("[encode→decode latency, \(warmup) warmup frames excluded]")
    print("  \(s)")
    print(String(format: "[bitstream]  avg %.1f KB/frame  =>  %.1f Mbit/s at %d fps", avgKB, mbitAtFps, fps))
    print("[frames]  submitted=\(submitted) decoded=\(decoded)"
          + "  poolFail=\(poolFailures) encoderDropped=\(encodeDrops) decodeFail=\(decodeFailures)")
    print("[integrity]  watermark recovered \(watermarkHits)/\(decoded) decoded frames")
    if decoded > 0 && watermarkHits < decoded {
        print("  ⚠️  some decoded frames lost the watermark — investigate before trusting latency")
    }
    if encodeDrops > 0 {
        let pct = 100.0 * Double(encodeDrops) / Double(max(1, submitted))
        print(String(format: "  ⓘ  encoder dropped %.0f%% of frames — RealTime mode shedding load "
                     + "(latency below is for frames that encoded)", pct))
    }
}
