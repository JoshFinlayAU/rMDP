import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import RMDPCodec

/// The low-latency H.264 encoder needs Apple Silicon's media engine. CI runners are VMs that may
/// not expose it, so skip there rather than fail for an environment reason. Set
/// RMDP_REQUIRE_HW_CODEC=1 to turn a missing encoder into a failure instead.
let hardwareEncoderAvailable: Bool = {
    if ProcessInfo.processInfo.environment["RMDP_REQUIRE_HW_CODEC"] == "1" { return true }
    return (try? H264Encoder(width: 64, height: 64)) != nil
}()

/// Encode → H264AccessUnit (wire form) → rebuild sample buffer → decode. Proves the
/// packetisation the host/viewer rely on, on real VideoToolbox hardware (works headless).
@Test(.enabled(if: hardwareEncoderAvailable, "no low-latency H.264 encoder (VM without media engine?)"))
func accessUnitRoundTripsThroughRealCodec() throws {
    let w = 640, h = 360
    let pool = try PixelBufferPool(width: w, height: h, minBuffers: 4)
    let enc = try H264Encoder(width: w, height: h, bitrateBps: 2_000_000)
    let dec = H264Decoder()

    let lock = NSLock()
    var units: [H264AccessUnit] = []
    for i in 0..<10 {
        let pb = try pool.makeBuffer()
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for row in 0..<h { memset(y + row * stride, Int32((row + i * 7) & 0xFF), w) }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * h / 2)
        CVPixelBufferUnlockBaseAddress(pb, [])
        try enc.encode(pb, pts: CMTime(value: Int64(i), timescale: 60), forceKeyframe: i == 5) { sb in
            guard let sb, let au = H264AccessUnit(sampleBuffer: sb) else { return }
            lock.lock(); units.append(au); lock.unlock()
        }
    }
    enc.finish()

    #expect(units.count == 10)
    #expect(units[0].isKeyframe && !units[0].parameterSets.isEmpty)   // first frame is always IDR
    #expect(units[5].isKeyframe && !units[5].parameterSets.isEmpty)   // forced IDR honoured
    #expect(!units[1].isKeyframe && units[1].parameterSets.isEmpty)

    var format: CMVideoFormatDescription?
    var decoded = 0
    for au in units {
        if au.isKeyframe { format = H264AccessUnit.formatDescription(parameterSets: au.parameterSets) }
        let fmt = try #require(format)
        let sb = try #require(au.sampleBuffer(format: fmt))
        try dec.decode(sb) { img in
            if let img, CVPixelBufferGetWidth(img) == w { lock.lock(); decoded += 1; lock.unlock() }
        }
    }
    dec.finish()
    #expect(decoded == 10)

    // Joining at the forced IDR (mid-stream) must also decode — that's loss recovery.
    let late = H264Decoder()
    var lateDecoded = 0
    let fmt5 = try #require(H264AccessUnit.formatDescription(parameterSets: units[5].parameterSets))
    for au in units[5...] {
        try late.decode(try #require(au.sampleBuffer(format: fmt5))) { img in
            if img != nil { lock.lock(); lateDecoded += 1; lock.unlock() }
        }
    }
    late.finish()
    #expect(lateDecoded == 5)
}
