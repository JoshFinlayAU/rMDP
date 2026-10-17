import Foundation
import Compression

/// Lossless building blocks for the crisp plane. All operate on tight (unpadded) tile buffers
/// of `w*h` luma bytes. Everything here is exactly reversible — the crisp plane never loses a bit.

// MARK: - Tile extraction / insertion (handles partial edge tiles)

public struct TileRect {
    public let x: Int, y: Int, w: Int, h: Int
    public init(index: Int, cols: Int, tileSize: Int, width: Int, height: Int) {
        let c = index % cols, r = index / cols
        x = c * tileSize
        y = r * tileSize
        w = Swift.min(tileSize, width - x)
        h = Swift.min(tileSize, height - y)
    }
}

/// Copy a tile out of a luma plane into a tight buffer.
public func extractTile(_ luma: UnsafePointer<UInt8>, bytesPerRow: Int, rect: TileRect) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: rect.w * rect.h)
    out.withUnsafeMutableBufferPointer { dst in
        for row in 0..<rect.h {
            let src = luma + (rect.y + row) * bytesPerRow + rect.x
            for col in 0..<rect.w { dst[row * rect.w + col] = src[col] }
        }
    }
    return out
}

/// Write a tight tile buffer back into a luma plane.
public func writeTile(_ pixels: [UInt8], into luma: UnsafeMutablePointer<UInt8>,
                      bytesPerRow: Int, rect: TileRect) {
    pixels.withUnsafeBufferPointer { src in
        for row in 0..<rect.h {
            let dst = luma + (rect.y + row) * bytesPerRow + rect.x
            for col in 0..<rect.w { dst[col] = src[row * rect.w + col] }
        }
    }
}

// MARK: - FNV-1a hash

public func fnv1a(_ bytes: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

// MARK: - Palette codec (≤16 distinct luma values)

public enum Palette {
    /// Returns nil if the tile has more than `maxColors` distinct values.
    public static func encode(_ tile: [UInt8], maxColors: Int = 16) -> [UInt8]? {
        var seen = [Bool](repeating: false, count: 256)
        var palette: [UInt8] = []
        for b in tile {
            if !seen[Int(b)] { seen[Int(b)] = true; palette.append(b); if palette.count > maxColors { return nil } }
        }
        palette.sort()
        var indexOf = [UInt8](repeating: 0, count: 256)
        for (i, c) in palette.enumerated() { indexOf[Int(c)] = UInt8(i) }
        let bits = max(1, Int(ceil(log2(Double(max(2, palette.count))))))

        var out: [UInt8] = [UInt8(palette.count)]
        out.append(contentsOf: palette)
        // Pack indices MSB-first.
        var acc: UInt32 = 0, nbits = 0
        for b in tile {
            acc = (acc << UInt32(bits)) | UInt32(indexOf[Int(b)])
            nbits += bits
            while nbits >= 8 { nbits -= 8; out.append(UInt8((acc >> UInt32(nbits)) & 0xFF)) }
        }
        if nbits > 0 { out.append(UInt8((acc << UInt32(8 - nbits)) & 0xFF)) }
        return out
    }

    public static func decode(_ data: [UInt8], count: Int) -> [UInt8] {
        let n = Int(data[0])
        let palette = Array(data[1..<(1 + n)])
        let bits = max(1, Int(ceil(log2(Double(max(2, n))))))
        var out = [UInt8](); out.reserveCapacity(count)
        var byteIdx = 1 + n
        var acc: UInt32 = 0, nbits = 0
        while out.count < count {
            while nbits < bits { acc = (acc << 8) | UInt32(data[byteIdx]); byteIdx += 1; nbits += 8 }
            nbits -= bits
            let idx = Int((acc >> UInt32(nbits)) & ((1 << UInt32(bits)) - 1))
            out.append(palette[idx])
        }
        return out
    }
}

// MARK: - LZFSE (Apple Compression framework — no external dependency)

public enum LZFSE {
    /// Returns (stored, bytes). `stored == true` means incompressible → bytes are the raw tile.
    public static func encode(_ src: [UInt8]) -> (stored: Bool, bytes: [UInt8]) {
        let cap = src.count + 64
        var dst = [UInt8](repeating: 0, count: cap)
        let n = dst.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in
                compression_encode_buffer(d.baseAddress!, cap, s.baseAddress!, src.count, nil, COMPRESSION_LZFSE)
            }
        }
        if n == 0 || n >= src.count { return (true, src) }     // expanded/failed → store raw
        return (false, Array(dst[0..<n]))
    }

    public static func decode(_ src: [UInt8], stored: Bool, expected: Int) -> [UInt8] {
        if stored { return src }
        var dst = [UInt8](repeating: 0, count: expected)
        let n = dst.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in
                compression_decode_buffer(d.baseAddress!, expected, s.baseAddress!, src.count, nil, COMPRESSION_LZFSE)
            }
        }
        return Array(dst[0..<n])
    }
}

// MARK: - Little-endian varint-free writer/reader helpers

public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    public mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    public mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
}

public struct ByteReader {
    let bytes: [UInt8]; public private(set) var pos = 0
    public init(_ b: [UInt8]) { bytes = b }
    public mutating func u8() -> UInt8 { defer { pos += 1 }; return bytes[pos] }
    public mutating func u16() -> UInt16 { let lo = UInt16(bytes[pos]); let hi = UInt16(bytes[pos+1]); pos += 2; return lo | (hi << 8) }
    public mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
    public mutating func raw(_ n: Int) -> [UInt8] { defer { pos += n }; return Array(bytes[pos..<pos+n]) }
    public var remaining: Int { bytes.count - pos }
}
