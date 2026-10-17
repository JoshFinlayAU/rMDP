import Testing
import Foundation
@testable import RMDPMeasure

// A stand-in luma plane: plain heap buffer, no CVPixelBuffer needed.
private final class LumaBuffer {
    let width: Int, height: Int, bytesPerRow: Int
    let ptr: UnsafeMutablePointer<UInt8>
    init(width: Int, height: Int, fill: UInt8 = 128) {
        self.width = width; self.height = height; self.bytesPerRow = width
        ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        ptr.update(repeating: fill, count: width * height)
    }
    deinit { ptr.deallocate() }
}

@Test func roundTripExactValue() {
    let wm = WatermarkCodec()
    let buf = LumaBuffer(width: 1280, height: 128)
    let value: UInt64 = 0x0123_4567_89AB_CDEF
    wm.embed(value, luma: buf.ptr, width: buf.width, height: buf.height, bytesPerRow: buf.bytesPerRow)
    let out = wm.extract(luma: buf.ptr, width: buf.width, height: buf.height, bytesPerRow: buf.bytesPerRow)
    #expect(out == value)
}

@Test func roundTripBoundaryValues() {
    let wm = WatermarkCodec()
    for value: UInt64 in [0, .max, 1, 0x8000_0000_0000_0000, 0xFFFF_FFFF, MonotonicClock.nowNanos()] {
        let buf = LumaBuffer(width: 1280, height: 64)
        wm.embed(value, luma: buf.ptr, width: buf.width, height: buf.height, bytesPerRow: buf.bytesPerRow)
        let out = wm.extract(luma: buf.ptr, width: buf.width, height: buf.height, bytesPerRow: buf.bytesPerRow)
        #expect(out == value, "failed for \(value)")
    }
}

@Test func blankFrameReturnsNil() {
    let wm = WatermarkCodec()
    let buf = LumaBuffer(width: 1280, height: 64, fill: 128)   // uniform, no watermark
    #expect(wm.extract(luma: buf.ptr, width: buf.width, height: buf.height, bytesPerRow: buf.bytesPerRow) == nil)
}

@Test func survivesModerateNoise() {
    // Simulate codec quantisation: perturb every pixel by ±20. High-contrast cells
    // should still decode.
    let wm = WatermarkCodec()
    let buf = LumaBuffer(width: 1280, height: 64)
    let value: UInt64 = 0xDEAD_BEEF_CAFE_F00D
    wm.embed(value, luma: buf.ptr, width: buf.width, height: buf.height, bytesPerRow: buf.bytesPerRow)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for i in 0..<(buf.width * buf.height) {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17   // xorshift
        let delta = Int(seed % 41) - 20
        let v = Int(buf.ptr[i]) + delta
        buf.ptr[i] = UInt8(max(0, min(255, v)))
    }
    let out = wm.extract(luma: buf.ptr, width: buf.width, height: buf.height, bytesPerRow: buf.bytesPerRow)
    #expect(out == value)
}

@Test func respectsBytesPerRowPadding() {
    // Real CVPixelBuffers pad rows; ensure we honour a stride wider than the width.
    let wm = WatermarkCodec()
    let width = 1280, height = 64, stride = 1408   // padded
    let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: stride * height)
    defer { ptr.deallocate() }
    ptr.update(repeating: 128, count: stride * height)
    let value: UInt64 = 0xABCD_1234_5678_9EF0
    wm.embed(value, luma: ptr, width: width, height: height, bytesPerRow: stride)
    #expect(wm.extract(luma: ptr, width: width, height: height, bytesPerRow: stride) == value)
}

@Test func tooSmallFrameFailsCleanly() {
    let wm = WatermarkCodec()   // needs 72*16 = 1152 px wide
    let buf = LumaBuffer(width: 640, height: 64)
    // embed is a no-op when it doesn't fit; extract must not read OOB and must return nil
    wm.embed(12345, luma: buf.ptr, width: buf.width, height: buf.height, bytesPerRow: buf.bytesPerRow)
    #expect(wm.extract(luma: buf.ptr, width: buf.width, height: buf.height, bytesPerRow: buf.bytesPerRow) == nil)
}
