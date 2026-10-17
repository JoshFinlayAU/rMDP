import Foundation
import Network
import RMDPProtocol

/// First byte on every stream the viewer opens, so the host knows which channel it is without
/// relying on stream-ID ordering (§2.6 channel table).
public enum StreamTag: UInt8, Sendable {
    case control = 0
    case input = 1
}

/// A reliable QUIC stream speaking `ControlMessage`s.
public final class MessageStream: @unchecked Sendable {
    let stream: QUIC.Stream<QUICStream>
    private var framer = ControlFramer()

    init(_ stream: QUIC.Stream<QUICStream>) { self.stream = stream }

    public func send(_ m: ControlMessage) async throws {
        try await stream.send(m.encoded())
    }

    /// Next message; nil on clean end of stream. Must be called from ONE task (owns the framer).
    public func receive() async throws -> ControlMessage? {
        while true {
            if let m = try framer.next() { return m }
            let chunk = try await stream.receive(atLeast: 1, atMost: 64 * 1024)
            if chunk.content.isEmpty && chunk.metadata.endOfStream { return nil }
            framer.append(chunk.content)
        }
    }

    func receiveTag() async throws -> StreamTag? {
        let b = try await stream.receive(exactly: 1)
        return b.content.first.flatMap(StreamTag.init(rawValue:))
    }

    func sendTag(_ t: StreamTag) async throws { try await stream.send(Data([t.rawValue])) }
}

public enum TransportConfig {
    /// Idle timeout: long enough to ride out a Wi-Fi blip, short enough that a dead viewer is
    /// noticed. Keepalives (ping every second) keep a healthy session well inside it.
    public static let idleTimeoutMillis = 15_000
    public static let maxDatagramFrameSize = 1400

    static func quic() -> QUIC {
        QUIC(alpn: [RMDPWire.alpn])
            .idleTimeout(idleTimeoutMillis)
            .maxDatagramFrameSize(maxDatagramFrameSize)
            .initialMaxBidirectionalStreams(4)
    }
}
