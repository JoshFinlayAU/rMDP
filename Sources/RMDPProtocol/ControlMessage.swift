import Foundation

/// Messages on the reliable streams. Control (channel 0) and input (channel 1) share the type
/// space so one codec covers both; which stream a message rides is the sender's job.
public enum ControlMessage: Equatable, Sendable {
    // Handshake (control stream)
    case hello(version: UInt16, password: String, viewerName: String)
    case welcome(Welcome)
    case reject(reason: String)

    // Session control
    case keyframeRequest
    case ping(viewerNanos: UInt64)
    case pong(viewerNanos: UInt64, hostNanos: UInt64)
    case stats(ViewerStats)

    // Input (input stream). Positions are CAPTURE PIXELS (top-left origin) — the viewer maps its
    // view through DisplayGeometry, the host maps back to its own points. Neither side ever
    // assumes the other's scale. `viewerNanos` = client monotonic timestamp (§2.8).
    case mouseMove(x: Float, y: Float, viewerNanos: UInt64)
    case mouseButton(button: UInt8, down: Bool, x: Float, y: Float, clickCount: UInt8, viewerNanos: UInt64)
    case scroll(dx: Float, dy: Float, viewerNanos: UInt64)
    case key(keyCode: UInt16, down: Bool, flags: UInt64, viewerNanos: UInt64)

    public struct Welcome: Equatable, Sendable {
        public var version: UInt16
        /// Stream (encoded) size in pixels.
        public var streamWidth: UInt32
        public var streamHeight: UInt32
        /// Host display size in points — informational (the viewer works in stream pixels).
        public var displayPointWidth: Double
        public var displayPointHeight: Double
        public var codec: Codec

        public init(version: UInt16 = RMDPWire.protocolVersion, streamWidth: UInt32, streamHeight: UInt32,
                    displayPointWidth: Double, displayPointHeight: Double, codec: Codec = .h264) {
            self.version = version
            self.streamWidth = streamWidth; self.streamHeight = streamHeight
            self.displayPointWidth = displayPointWidth; self.displayPointHeight = displayPointHeight
            self.codec = codec
        }
    }

    public enum Codec: UInt8, Sendable { case h264 = 1 }

    /// Viewer → host link report. This is the telemetry the adaptive controller (§2.7) will feed
    /// on; in v1 the host only logs it.
    public struct ViewerStats: Equatable, Sendable {
        public var intervalMillis: UInt32
        public var bytesReceived: UInt32
        public var framesDecoded: UInt32
        public var framesLost: UInt32
        public var smoothedRTTMillis: Float
        public init(intervalMillis: UInt32, bytesReceived: UInt32, framesDecoded: UInt32,
                    framesLost: UInt32, smoothedRTTMillis: Float) {
            self.intervalMillis = intervalMillis; self.bytesReceived = bytesReceived
            self.framesDecoded = framesDecoded; self.framesLost = framesLost
            self.smoothedRTTMillis = smoothedRTTMillis
        }
    }

    enum TypeCode: UInt8 {
        case hello = 1, welcome = 2, reject = 3
        case keyframeRequest = 4, ping = 5, pong = 6, stats = 7
        case mouseMove = 16, mouseButton = 17, scroll = 18, key = 19
    }

    /// Body only (no length/type prefix).
    func encodeBody(into w: inout ByteWriter) -> TypeCode {
        switch self {
        case let .hello(version, password, viewerName):
            w.u16(version); w.string(password); w.string(viewerName); return .hello
        case let .welcome(v):
            w.u16(v.version); w.u32(v.streamWidth); w.u32(v.streamHeight)
            w.f64(v.displayPointWidth); w.f64(v.displayPointHeight); w.u8(v.codec.rawValue)
            return .welcome
        case let .reject(reason):
            w.string(reason); return .reject
        case .keyframeRequest:
            return .keyframeRequest
        case let .ping(t):
            w.u64(t); return .ping
        case let .pong(v, h):
            w.u64(v); w.u64(h); return .pong
        case let .stats(s):
            w.u32(s.intervalMillis); w.u32(s.bytesReceived); w.u32(s.framesDecoded)
            w.u32(s.framesLost); w.f32(s.smoothedRTTMillis); return .stats
        case let .mouseMove(x, y, t):
            w.f32(x); w.f32(y); w.u64(t); return .mouseMove
        case let .mouseButton(b, down, x, y, cc, t):
            w.u8(b); w.u8(down ? 1 : 0); w.f32(x); w.f32(y); w.u8(cc); w.u64(t); return .mouseButton
        case let .scroll(dx, dy, t):
            w.f32(dx); w.f32(dy); w.u64(t); return .scroll
        case let .key(code, down, flags, t):
            w.u16(code); w.u8(down ? 1 : 0); w.u64(flags); w.u64(t); return .key
        }
    }

    static func decodeBody(type: UInt8, _ r: inout ByteReader) throws -> ControlMessage {
        guard let tc = TypeCode(rawValue: type) else { throw WireError.unknownMessageType(type) }
        switch tc {
        case .hello:
            return .hello(version: try r.u16(), password: try r.string(), viewerName: try r.string())
        case .welcome:
            let version = try r.u16(), w = try r.u32(), h = try r.u32()
            let pw = try r.f64(), ph = try r.f64()
            let codecRaw = try r.u8()
            guard let codec = Codec(rawValue: codecRaw) else { throw WireError.badHeader }
            return .welcome(Welcome(version: version, streamWidth: w, streamHeight: h,
                                    displayPointWidth: pw, displayPointHeight: ph, codec: codec))
        case .reject:
            return .reject(reason: try r.string())
        case .keyframeRequest:
            return .keyframeRequest
        case .ping:
            return .ping(viewerNanos: try r.u64())
        case .pong:
            return .pong(viewerNanos: try r.u64(), hostNanos: try r.u64())
        case .stats:
            return .stats(ViewerStats(intervalMillis: try r.u32(), bytesReceived: try r.u32(),
                                      framesDecoded: try r.u32(), framesLost: try r.u32(),
                                      smoothedRTTMillis: try r.f32()))
        case .mouseMove:
            return .mouseMove(x: try r.f32(), y: try r.f32(), viewerNanos: try r.u64())
        case .mouseButton:
            return .mouseButton(button: try r.u8(), down: try r.u8() != 0, x: try r.f32(), y: try r.f32(),
                                clickCount: try r.u8(), viewerNanos: try r.u64())
        case .scroll:
            return .scroll(dx: try r.f32(), dy: try r.f32(), viewerNanos: try r.u64())
        case .key:
            return .key(keyCode: try r.u16(), down: try r.u8() != 0, flags: try r.u64(), viewerNanos: try r.u64())
        }
    }

    /// Full frame: `u32 length | u8 type | body`, where length counts type + body.
    public func encoded() -> Data {
        var body = ByteWriter()
        let type = encodeBody(into: &body)
        var w = ByteWriter(capacity: body.data.count + 5)
        w.u32(UInt32(body.data.count + 1)); w.u8(type.rawValue); w.bytes(body.data)
        return w.data
    }
}

/// Incremental decoder for a reliable stream: feed it whatever bytes arrived, pull out every
/// complete message. Streams deliver arbitrary chunk boundaries, so this must never assume one
/// read == one message.
public struct ControlFramer {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ chunk: Data) { buffer.append(chunk) }

    /// Next complete message, nil if more bytes are needed. Throws on malformed input — the
    /// caller should drop the connection (a desynced stream can't be recovered).
    public mutating func next() throws -> ControlMessage? {
        guard buffer.count >= 4 else { return nil }
        var r = ByteReader(buffer)
        let len = Int(try r.u32())
        guard len >= 1 else { throw WireError.truncated }
        guard len <= RMDPWire.maxControlFrameSize else { throw WireError.frameTooLarge(len) }
        guard buffer.count >= 4 + len else { return nil }
        let type = try r.u8()
        var body = ByteReader(try r.bytes(len - 1))
        let msg = try ControlMessage.decodeBody(type: type, &body)
        buffer.removeFirst(4 + len)
        buffer = Data(buffer)   // re-base indices to 0
        return msg
    }
}
