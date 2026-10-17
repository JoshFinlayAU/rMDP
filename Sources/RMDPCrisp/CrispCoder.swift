import Foundation

/// The crisp plane (draft §2.3): lossless encoding of `.crisp` tiles.
///
/// Per changed crisp tile the encoder picks the cheapest exact encoding:
///   REF — the tile's pixels are already in the shared cache → send just a slot index
///   PAL — ≤16 distinct luma values → palette + packed indices
///   RAW — LZFSE (Apple Compression), or stored raw if incompressible
/// plus a frame-level scroll: if the whole viewport shifted by `dy`, the decoder shifts its
/// reconstruction first and only genuinely-changed tiles are sent.
///
/// **The encoder owns cache-slot allocation and sends the slot with every record**, so the two
/// caches cannot desync — the decoder is a pure follower. Cache eviction is deterministic LRU;
/// on a hash hit the encoder verifies the cached pixels actually match (guards against the
/// vanishingly rare FNV collision) before emitting a REF.
///
/// Scope: luma plane. The identical machinery applies to the CbCr plane for full colour — a
/// deliberate follow-up, not a design change.

private enum Method: UInt8 { case ref = 0, pal = 1, raw = 2 }

public final class CrispCache {
    struct Slot { var hash: UInt64 = 0; var pixels: [UInt8] = []; var used: UInt64 = 0; var valid = false }
    private(set) var slots: [Slot]
    private var clock: UInt64 = 0
    let capacity: Int
    public init(capacity: Int = 4096) { self.capacity = capacity; slots = Array(repeating: Slot(), count: capacity) }

    /// Encoder side: find a slot whose cached pixels equal `pixels` (true cache hit).
    func find(hash: UInt64, pixels: [UInt8]) -> Int? {
        for i in 0..<capacity where slots[i].valid && slots[i].hash == hash && slots[i].pixels == pixels {
            clock += 1; slots[i].used = clock; return i
        }
        return nil
    }
    /// Encoder side: allocate a slot (free, else LRU victim) and store.
    func insert(hash: UInt64, pixels: [UInt8]) -> Int {
        var victim = 0
        if let free = slots.firstIndex(where: { !$0.valid }) { victim = free }
        else { var best = UInt64.max; for i in 0..<capacity where slots[i].used < best { best = slots[i].used; victim = i } }
        clock += 1
        slots[victim] = Slot(hash: hash, pixels: pixels, used: clock, valid: true)
        return victim
    }
    /// Decoder side: store pixels into the slot the encoder dictated.
    func put(_ index: Int, pixels: [UInt8]) { slots[index].pixels = pixels; slots[index].valid = true }
    func get(_ index: Int) -> [UInt8] { slots[index].pixels }
    func touch(_ index: Int) { clock += 1; slots[index].used = clock }
}

public final class CrispEncoder {
    public let width, height, tileSize, cols, rows: Int
    private let cache: CrispCache
    public init(width: Int, height: Int, tileSize: Int = 64, cacheCapacity: Int = 4096) {
        self.width = width; self.height = height; self.tileSize = tileSize
        self.cols = (width + tileSize - 1) / tileSize
        self.rows = (height + tileSize - 1) / tileSize
        self.cache = CrispCache(capacity: cacheCapacity)
    }

    public func encodeFrame(luma: UnsafePointer<UInt8>, bytesPerRow: Int,
                            crispTiles: [Int], scrollDy: Int = 0) -> [UInt8] {
        var w = ByteWriter()
        w.i16(Int16(clamping: scrollDy))
        w.u16(UInt16(crispTiles.count))
        for tileIndex in crispTiles {
            let rect = TileRect(index: tileIndex, cols: cols, tileSize: tileSize, width: width, height: height)
            let pixels = extractTile(luma, bytesPerRow: bytesPerRow, rect: rect)
            let hash = fnv1a(pixels)
            w.u16(UInt16(tileIndex))

            if let slot = cache.find(hash: hash, pixels: pixels) {
                w.u8(Method.ref.rawValue); w.u16(UInt16(slot))
                continue
            }
            let slot = cache.insert(hash: hash, pixels: pixels)
            if let pal = Palette.encode(pixels) {
                w.u8(Method.pal.rawValue); w.u16(UInt16(slot))
                w.u16(UInt16(pal.count)); w.raw(pal)
            } else {
                let (stored, bytes) = LZFSE.encode(pixels)
                w.u8(Method.raw.rawValue); w.u16(UInt16(slot))
                w.u8(stored ? 1 : 0); w.u16(UInt16(bytes.count)); w.raw(bytes)
            }
        }
        return w.bytes
    }
}

public final class CrispDecoder {
    public let width, height, tileSize, cols, rows: Int
    private let cache: CrispCache
    public private(set) var recon: [UInt8]      // reconstructed luma plane (tight, bpr == width)
    public init(width: Int, height: Int, tileSize: Int = 64, cacheCapacity: Int = 4096) {
        self.width = width; self.height = height; self.tileSize = tileSize
        self.cols = (width + tileSize - 1) / tileSize
        self.rows = (height + tileSize - 1) / tileSize
        self.cache = CrispCache(capacity: cacheCapacity)
        self.recon = [UInt8](repeating: 0, count: width * height)
    }

    public func decodeFrame(_ data: [UInt8]) {
        var r = ByteReader(data)
        let scrollDy = Int(r.i16())
        if scrollDy != 0 { shiftRecon(dy: scrollDy) }
        let count = Int(r.u16())
        recon.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            for _ in 0..<count {
                let tileIndex = Int(r.u16())
                let rect = TileRect(index: tileIndex, cols: cols, tileSize: tileSize, width: width, height: height)
                let method = Method(rawValue: r.u8())!
                let slot = Int(r.u16())
                let pixels: [UInt8]
                switch method {
                case .ref:
                    pixels = cache.get(slot); cache.touch(slot)
                case .pal:
                    let len = Int(r.u16()); let payload = r.raw(len)
                    pixels = Palette.decode(payload, count: rect.w * rect.h)
                    cache.put(slot, pixels: pixels)
                case .raw:
                    let stored = r.u8() == 1; let len = Int(r.u16()); let payload = r.raw(len)
                    pixels = LZFSE.decode(payload, stored: stored, expected: rect.w * rect.h)
                    cache.put(slot, pixels: pixels)
                }
                writeTile(pixels, into: base, bytesPerRow: width, rect: rect)
            }
        }
    }

    private func shiftRecon(dy: Int) {
        var out = [UInt8](repeating: 0, count: width * height)
        out.withUnsafeMutableBufferPointer { dst in
            recon.withUnsafeBufferPointer { src in
                for row in 0..<height {
                    let s = row + dy
                    if s >= 0 && s < height {
                        for x in 0..<width { dst[row * width + x] = src[s * width + x] }
                    }
                }
            }
        }
        recon = out
    }
}

/// Scroll detection via tile-row hashing (Hume's ~2ms/4K technique). Hash each row of tiles in
/// the previous and current frames; find a vertical offset `dy` for which most current rows match
/// previous rows shifted by `dy`. Returns the best `dy` (0 if no consistent scroll).
public final class ScrollDetector {
    let cols, rows, tileSize, width, height: Int
    private var prevRowHashes: [UInt64] = []
    public init(width: Int, height: Int, tileSize: Int = 64) {
        self.width = width; self.height = height; self.tileSize = tileSize
        self.cols = (width + tileSize - 1) / tileSize
        self.rows = (height + tileSize - 1) / tileSize
    }

    private func rowHashes(_ luma: UnsafePointer<UInt8>, bytesPerRow: Int) -> [UInt64] {
        var hashes = [UInt64](repeating: 0, count: rows)
        for tr in 0..<rows {
            var h: UInt64 = 0xcbf29ce484222325
            let y0 = tr * tileSize, y1 = min(y0 + tileSize, height)
            for y in y0..<y1 {
                let rowp = luma + y * bytesPerRow
                for x in 0..<width { h = (h ^ UInt64(rowp[x])) &* 0x100000001b3 }
            }
            hashes[tr] = h
        }
        return hashes
    }

    /// Feed the current frame; returns detected scroll in *tile-rows* × tileSize (pixels), or 0.
    public func detect(luma: UnsafePointer<UInt8>, bytesPerRow: Int, minMatchRows: Int = 3) -> Int {
        let cur = rowHashes(luma, bytesPerRow: bytesPerRow)
        defer { prevRowHashes = cur }
        guard prevRowHashes.count == rows else { return 0 }
        var bestDy = 0, bestScore = 0
        for dRow in -(rows - 1)...(rows - 1) where dRow != 0 {
            var score = 0
            for r in 0..<rows {
                let s = r + dRow
                if s >= 0 && s < rows && cur[r] == prevRowHashes[s] { score += 1 }
            }
            if score > bestScore { bestScore = score; bestDy = dRow }
        }
        return bestScore >= minMatchRows ? bestDy * tileSize : 0
    }
}
