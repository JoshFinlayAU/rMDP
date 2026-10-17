// rMDP pipeline latency — draft step 3 (render half, verifiable headless).
//
// Extends the codec floor with the REAL Metal render stage:
//   synthetic frame → watermark → H.264 encode → H.264 decode → Metal NV12→RGB
//   render (offscreen, real GPU) → GPU-complete timestamp → readback + verify.
//
// Measures stamp → render-complete: embed, encode, decode, and GPU render. Still not
// motion-to-photon (no SCStream capture, no display scanout) — but it adds the render
// cost to the numbers from rmdp-latencybench. Synthetic frames = no TCC needed.
//
// The capture half (SCStream) can't run in a headless session; see rmdp-capturetest,
// which you run on a console session with Screen Recording granted.

import Foundation
import CoreMedia
import CoreVideo
import RMDPMeasure
import RMDPCodec
import RMDPRender

func envInt(_ k: String, _ d: Int) -> Int { ProcessInfo.processInfo.environment[k].flatMap(Int.init) ?? d }

let width = envInt("RMDP_W", 1920)
let height = envInt("RMDP_H", 1080)
let frames = envInt("RMDP_FRAMES", 200)
let fps = envInt("RMDP_FPS", 60)
let bitrate = envInt("RMDP_BITRATE", 50_000_000)   // headroom so rate-cap drops don't confound
let warmup = envInt("RMDP_WARMUP", 20)

print("rMDP pipeline latency — encode → decode → Metal render")
print("host: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("\(width)x\(height) @ \(fps)fps, \(frames) frames\n")

let pool = try PixelBufferPool(width: width, height: height)
let encoder = try H264Encoder(width: width, height: height, bitrateBps: bitrate)
let decoder = H264Decoder()
let renderer = try MetalRenderer(width: width, height: height)
let wm = WatermarkCodec()
let recorder = LatencyRecorder(capacity: frames + 16)   // stamp → render-complete

let collector = DispatchQueue(label: "rmdp.pipeline.collector")
let renderSlot = DispatchSemaphore(value: 1)   // single offscreen target → one render at a time
var watermarkHits = 0, resolved = 0, submitted = 0, decodeFails = 0, renderMiss = 0
var allSubmitted = false
let allDone = DispatchSemaphore(value: 0)

func paint(_ pb: CVPixelBuffer, frameIndex: Int) -> UInt64 {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let yw = CVPixelBufferGetWidthOfPlane(pb, 0), yh = CVPixelBufferGetHeightOfPlane(pb, 0)
    let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    for row in 0..<yh {
        let base = UInt8((row + frameIndex * 3) & 0xFF)
        let p = y + row * ybpr
        for col in 0..<yw { p[col] = base &+ UInt8((col >> 3) & 0x3F) }
    }
    let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    memset(c, 128, CVPixelBufferGetHeightOfPlane(pb, 1) * CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
    let stamp = MonotonicClock.nowNanos()
    wm.embed(stamp, luma: y, width: yw, height: yh, bytesPerRow: ybpr)
    return stamp
}

let frameInterval = 1.0 / Double(fps)
let runStart = DispatchTime.now().uptimeNanoseconds

for i in 0..<frames {
    let target = runStart &+ UInt64(Double(i) * frameInterval * 1e9)
    let now = DispatchTime.now().uptimeNanoseconds
    if target > now, target - now > 1000 { usleep(useconds_t((target - now) / 1000)) }

    guard let pb = try? pool.makeBuffer() else { continue }
    let stamp = paint(pb, frameIndex: i)
    let frameIndex = i
    collector.sync { submitted += 1 }
    let pts = CMTime(value: Int64(i), timescale: Int32(fps))

    func resolve(_ body: () -> Void) {
        body(); resolved += 1
        if allSubmitted && resolved == submitted { allDone.signal() }
    }

    do {
        try encoder.encode(pb, pts: pts) { sb in
            guard let sb else { collector.async { resolve {} }; return }
            do {
                try decoder.decode(sb) { image in
                    guard let image else { collector.async { resolve { decodeFails += 1 } }; return }
                    // Serialize the render stage (one shared offscreen target).
                    renderSlot.wait()
                    do {
                        try renderer.render(image) {
                            let t1 = MonotonicClock.nowNanos()
                            // Verify watermark survived the GPU path (off the timed line).
                            let rb = renderer.readbackLuma()
                            let recovered = rb.luma.withUnsafeBufferPointer { buf in
                                wm.extract(luma: buf.baseAddress!, width: rb.width,
                                           height: rb.height, bytesPerRow: rb.bytesPerRow)
                            }
                            renderSlot.signal()
                            collector.async {
                                resolve {
                                    if frameIndex >= warmup {
                                        recorder.record(MonotonicClock.millis(from: stamp, to: t1))
                                    }
                                    if recovered == stamp { watermarkHits += 1 } else { renderMiss += 1 }
                                }
                            }
                        }
                    } catch {
                        renderSlot.signal()
                        collector.async { resolve { renderMiss += 1 } }
                    }
                }
            } catch { collector.async { resolve { decodeFails += 1 } } }
        }
    } catch { collector.sync { resolve {} } }
}

encoder.finish()
decoder.finish()
collector.sync { allSubmitted = true; if resolved == submitted { allDone.signal() } }
if allDone.wait(timeout: .now() + 60) == .timedOut {
    collector.sync { print("⚠️  timed out: \(resolved)/\(submitted)") }
}

collector.sync {
    print("[stamp → render-complete latency, \(warmup) warmup excluded]")
    print("  \(recorder.summarize())")
    let rendered = watermarkHits + renderMiss
    print("[frames]  submitted=\(submitted) rendered=\(rendered) decodeFail=\(decodeFails)")
    print("[integrity]  watermark survived encode→decode→render in \(watermarkHits)/\(rendered) frames")
    if rendered > 0 && watermarkHits < rendered {
        print("  ⚠️  watermark lost after render in \(renderMiss) frames — check YCbCr→RGB→luma path")
    }
}
