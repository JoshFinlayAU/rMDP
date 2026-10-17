import Testing
import Foundation
@testable import RMDPCrisp

// MARK: - Primitives

@Test func paletteRoundTripExact() {
    // A tile with 4 distinct luma values.
    var tile = [UInt8]()
    for i in 0..<(64 * 64) { tile.append([16, 80, 160, 235][i % 4]) }
    let enc = Palette.encode(tile)
    #expect(enc != nil)
    let dec = Palette.decode(enc!, count: tile.count)
    #expect(dec == tile)
    #expect(enc!.count < tile.count / 3)          // 2 bits/px vs 8 → big win
}

@Test func paletteRejectsHighColorTiles() {
    var tile = [UInt8](); for i in 0..<4096 { tile.append(UInt8(i & 0xFF)) }  // 256 colours
    #expect(Palette.encode(tile) == nil)
}

@Test func lzfseRoundTripExact() {
    var tile = [UInt8](repeating: 0, count: 4096)
    var s: UInt64 = 12345
    for i in 0..<tile.count { s ^= s << 13; s ^= s >> 7; s ^= s << 17; tile[i] = UInt8(truncatingIfNeeded: s) }
    let (stored, bytes) = LZFSE.encode(tile)
    let dec = LZFSE.decode(bytes, stored: stored, expected: tile.count)
    #expect(dec == tile)
}

// MARK: - Full crisp plane round-trip (the losslessness guarantee)

private func makeLuma(_ w: Int, _ h: Int, seed: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            // text-like: mostly two colours with occasional accents, region depends on seed
            let v: UInt8 = ((x ^ y ^ seed) & 7) == 0 ? 235 : (((x + seed) & 15) == 0 ? 128 : 16)
            buf[y * w + x] = v
        }
    }
    return buf
}

@Test func crispPlaneIsPixelExactAcrossAllMethods() {
    let W = 256, H = 192
    let enc = CrispEncoder(width: W, height: H)
    let dec = CrispDecoder(width: W, height: H)
    let allTiles = Array(0..<(enc.cols * enc.rows))

    let src = makeLuma(W, H, seed: 1)
    src.withUnsafeBufferPointer { p in
        let data = enc.encodeFrame(luma: p.baseAddress!, bytesPerRow: W, crispTiles: allTiles)
        dec.decodeFrame(data)
    }
    #expect(dec.recon == src)                    // lossless: reconstruction == source, exactly
}

@Test func repeatedTileBecomesCheapRef() {
    let W = 256, H = 64
    let enc = CrispEncoder(width: W, height: H)
    let dec = CrispDecoder(width: W, height: H)
    let tiles = Array(0..<enc.cols)
    let src = makeLuma(W, H, seed: 2)

    // Frame 1: everything is new → PAL/RAW.
    let f1 = src.withUnsafeBufferPointer { enc.encodeFrame(luma: $0.baseAddress!, bytesPerRow: W, crispTiles: tiles) }
    dec.decodeFrame(f1)
    // Frame 2: identical content → every tile is a cache REF → tiny.
    let f2 = src.withUnsafeBufferPointer { enc.encodeFrame(luma: $0.baseAddress!, bytesPerRow: W, crispTiles: tiles) }
    dec.decodeFrame(f2)
    #expect(dec.recon == src)                    // still exact
    #expect(f2.count < f1.count / 4)             // REF frame is a fraction of the first
    #expect(f2.count <= 4 + tiles.count * 5)     // ~5 bytes per REF tile (index+method+slot)
}

@Test func cacheStaysInSyncOverManyFrames() {
    let W = 192, H = 128
    let enc = CrispEncoder(width: W, height: H, cacheCapacity: 8)   // tiny cache → forces eviction
    let dec = CrispDecoder(width: W, height: H, cacheCapacity: 8)
    let tiles = Array(0..<(enc.cols * enc.rows))
    for f in 0..<30 {
        let src = makeLuma(W, H, seed: f % 5)      // cycles content → mix of hits, misses, evictions
        src.withUnsafeBufferPointer { p in
            let data = enc.encodeFrame(luma: p.baseAddress!, bytesPerRow: W, crispTiles: tiles)
            dec.decodeFrame(data)
            #expect(dec.recon == src, "desync at frame \(f)")
        }
    }
}

// MARK: - Scroll detection

@Test func scrollDetectorFindsVerticalOffset() {
    let W = 128, H = 256                          // 2×4 tiles
    let det = ScrollDetector(width: W, height: H)
    // A tall doc; viewport at two offsets one tile-row apart.
    func viewport(_ off: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<W { b[y * W + x] = UInt8((off + y) & 0xFF) } }
        return b
    }
    let a = viewport(0), b = viewport(64)          // scrolled down by one tile-row (64px)
    _ = a.withUnsafeBufferPointer { det.detect(luma: $0.baseAddress!, bytesPerRow: W) }   // prime
    let dy = b.withUnsafeBufferPointer { det.detect(luma: $0.baseAddress!, bytesPerRow: W) }
    #expect(dy == 64)
}

@Test func scrollShiftReconstructsCarriedContent() {
    // After a detected scroll, the decoder carries overlapping content; only new tiles are sent.
    let W = 128, H = 256
    let enc = CrispEncoder(width: W, height: H)
    let dec = CrispDecoder(width: W, height: H)
    let allTiles = Array(0..<(enc.cols * enc.rows))
    func viewport(_ off: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<W { b[y * W + x] = UInt8(((off + y) * 7 ^ x) & 0xFF) } }
        return b
    }
    let f0 = viewport(0)
    f0.withUnsafeBufferPointer { dec.decodeFrame(enc.encodeFrame(luma: $0.baseAddress!, bytesPerRow: W, crispTiles: allTiles)) }
    #expect(dec.recon == f0)
    // Now scroll down 64px: send scrollDy + all tiles (the bottom row is newly revealed).
    let f1 = viewport(64)
    f1.withUnsafeBufferPointer { dec.decodeFrame(enc.encodeFrame(luma: $0.baseAddress!, bytesPerRow: W, crispTiles: allTiles, scrollDy: 64)) }
    #expect(dec.recon == f1)                       // exact after shift + records
}
