import Foundation

/// Video datagram (channel 2) header — fixed 18 bytes, big-endian:
///
///     ver:4 | chan:4 │ flags:8 │ frameID:32 │ fragIndex:16 │ fragCount:16 │ captureNanos:64
///
/// Deviation from draft §3's 8-byte header: v1 carries a full 32-bit frame ID (no wrap handling
/// needed for ~2 years at 60fps) and the host's full monotonic capture time, so end-to-end
/// latency is measurable without a session epoch. 10 extra bytes on 1200 is <1% — revisit when
/// the crisp plane lands and datagrams get small.
public struct VideoFragmentHeader: Equatable, Sendable {
    public static let size = 18
    public static let channel: UInt8 = 2

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
    }

    public var flags: Flags
    public var frameID: UInt32
    public var fragIndex: UInt16
    public var fragCount: UInt16
    /// Host `MonotonicClock` ns when the frame was scheduled for scanout on the host display.
    public var captureNanos: UInt64

    public init(flags: Flags, frameID: UInt32, fragIndex: UInt16, fragCount: UInt16, captureNanos: UInt64) {
        self.flags = flags; self.frameID = frameID
        self.fragIndex = fragIndex; self.fragCount = fragCount; self.captureNanos = captureNanos
    }

    public func write(into w: inout ByteWriter) {
        w.u8(UInt8(RMDPWire.protocolVersion & 0x0F) << 4 | Self.channel)
        w.u8(flags.rawValue); w.u32(frameID); w.u16(fragIndex); w.u16(fragCount); w.u64(captureNanos)
    }

    public static func parse(_ r: inout ByteReader) throws -> VideoFragmentHeader {
        let vc = try r.u8()
        guard vc >> 4 == UInt8(RMDPWire.protocolVersion & 0x0F) else { throw WireError.badVersion(vc >> 4) }
        guard vc & 0x0F == channel else { throw WireError.badHeader }
        let h = VideoFragmentHeader(flags: Flags(rawValue: try r.u8()), frameID: try r.u32(),
                                    fragIndex: try r.u16(), fragCount: try r.u16(),
                                    captureNanos: try r.u64())
        guard h.fragCount > 0, h.fragIndex < h.fragCount else { throw WireError.badHeader }
        return h
    }
}

/// One encoded video frame as it crosses the wire (before fragmentation / after reassembly).
///
/// Payload layout: `u8 paramSetCount | (u16 len | bytes)* | AVCC sample data`. Parameter sets
/// (SPS/PPS) ride every keyframe so a viewer can join or recover from any IDR without a
/// separate config message.
public struct EncodedVideoFrame: Equatable, Sendable {
    public var frameID: UInt32
    public var isKeyframe: Bool
    public var captureNanos: UInt64
    public var parameterSets: [Data]
    public var sampleData: Data

    public init(frameID: UInt32, isKeyframe: Bool, captureNanos: UInt64,
                parameterSets: [Data], sampleData: Data) {
        self.frameID = frameID; self.isKeyframe = isKeyframe; self.captureNanos = captureNanos
        self.parameterSets = parameterSets; self.sampleData = sampleData
    }

    func payload() -> Data {
        var w = ByteWriter(capacity: sampleData.count + 64)
        w.u8(UInt8(parameterSets.count))
        for ps in parameterSets { w.u16(UInt16(ps.count)); w.bytes(ps) }
        w.bytes(sampleData)
        return w.data
    }

    static func fromPayload(_ p: Data, header: VideoFragmentHeader) throws -> EncodedVideoFrame {
        var r = ByteReader(p)
        let n = Int(try r.u8())
        var sets: [Data] = []
        for _ in 0..<n { sets.append(try r.bytes(Int(try r.u16()))) }
        return EncodedVideoFrame(frameID: header.frameID, isKeyframe: header.flags.contains(.keyframe),
                                 captureNanos: header.captureNanos, parameterSets: sets,
                                 sampleData: r.rest())
    }

    /// Split into datagrams of at most `maxDatagramSize` bytes each (header included).
    public func fragments(maxDatagramSize: Int = RMDPWire.maxDatagramSize) -> [Data] {
        let body = payload()
        let chunk = maxDatagramSize - VideoFragmentHeader.size
        precondition(chunk > 0)
        let count = max(1, (body.count + chunk - 1) / chunk)
        precondition(count <= Int(UInt16.max), "frame too large to fragment")
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let start = body.startIndex + i * chunk
            let end = min(start + chunk, body.endIndex)
            var w = ByteWriter(capacity: VideoFragmentHeader.size + (end - start))
            VideoFragmentHeader(flags: isKeyframe ? [.keyframe] : [], frameID: frameID,
                                fragIndex: UInt16(i), fragCount: UInt16(count),
                                captureNanos: captureNanos).write(into: &w)
            w.bytes(body[start..<end])
            out.append(w.data)
        }
        return out
    }
}
