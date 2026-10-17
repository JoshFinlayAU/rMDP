import Foundation

/// rMDP wire format — the ONE place framing lives (CLAUDE.md: protocol code is versioned and
/// testable in isolation). Transport moves opaque bytes; app code only sees typed messages.
///
/// Two framings ride one QUIC connection (§2.6):
///   - **Reliable streams** (control = channel 0, input = channel 1) carry `ControlMessage`s,
///     each framed as `u32 length | u8 type | body` (big-endian).
///   - **Datagrams** carry video fragments with a fixed `VideoFragmentHeader`.
///
/// Version history:
///   - v1 (2026-10-17): MVP — full-frame H.264, password auth, keyframe-request loss recovery.
public enum RMDPWire {
    public static let protocolVersion: UInt16 = 1
    public static let alpn = "rmdp/1"
    /// Conservative datagram size (header + payload). `usableDatagramFrameSize` isn't reliable
    /// right after the datagram channel opens (reads 0), so don't derive MTU from it yet.
    public static let maxDatagramSize = 1200
    /// Hard cap on a single control frame, so a hostile/corrupt length can't make us allocate GBs.
    public static let maxControlFrameSize = 64 * 1024
}

public enum WireError: Error, Equatable {
    case truncated
    case unknownMessageType(UInt8)
    case frameTooLarge(Int)
    case badVersion(UInt8)
    case badHeader
    case invalidString
}

// MARK: - Byte writer / reader

public struct ByteWriter {
    public private(set) var data = Data()
    public init(capacity: Int = 64) { data.reserveCapacity(capacity) }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func bytes(_ d: Data) { data.append(d) }
    /// u16 length-prefixed UTF-8.
    public mutating func string(_ s: String) {
        let utf8 = Data(s.utf8.prefix(Int(UInt16.max)))
        u16(UInt16(utf8.count)); data.append(utf8)
    }
}

public struct ByteReader {
    private let data: Data
    public private(set) var offset: Int
    public init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    public var remaining: Int { data.endIndex - offset }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw WireError.truncated }
        defer { offset += n }
        return data[offset..<(offset + n)]
    }
    private mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let d = try take(MemoryLayout<T>.size)
        var v: T = 0
        for b in d { v = (v << 8) | T(b) }
        return v
    }
    public mutating func u8() throws -> UInt8 { try int(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try int(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try int(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try int(UInt64.self) }
    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    public mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    public mutating func bytes(_ n: Int) throws -> Data { Data(try take(n)) }
    public mutating func rest() -> Data { Data((try? take(remaining)) ?? Data()) }
    public mutating func string() throws -> String {
        let n = Int(try u16())
        guard let s = String(data: try take(n), encoding: .utf8) else { throw WireError.invalidString }
        return s
    }
}
