import Foundation
import Network
import Security
import RMDPProtocol

public enum ViewerError: Error, CustomStringConvertible {
    case rejected(String)
    case hostKeyMismatch(host: String, expected: String, got: String)
    case unexpectedMessage(String)
    case closed

    public var description: String {
        switch self {
        case .rejected(let r): return "host refused the connection: \(r)"
        case let .hostKeyMismatch(host, expected, got):
            return """
            HOST IDENTITY CHANGED for \(host)!
              pinned:    \(HostIdentity.shortFingerprint(expected))
              presented: \(HostIdentity.shortFingerprint(got))
            Someone may be intercepting the connection, or the host regenerated its identity.
            If you trust the change, remove the entry from \(KnownHosts.path).
            """
        case .unexpectedMessage(let m): return "protocol error: unexpected \(m)"
        case .closed: return "connection closed"
        }
    }
}

/// Viewer side: connect, pin, authenticate, then expose datagrams + control + input.
public final class ViewerClient: @unchecked Sendable {
    public let hostKey: String
    private let conn: NetworkConnection<QUIC>
    private let pinResult = PinResult()
    private var control: MessageStream!
    private var input: MessageStream!
    private let inputQueue: AsyncStream<ControlMessage>.Continuation
    private let inputMessages: AsyncStream<ControlMessage>

    /// Called on first contact with a host (fingerprint just pinned) — print it so a human can
    /// compare against what the host shows.
    public var onNewHostPinned: (@Sendable (String) -> Void)?

    public init(host: String, port: UInt16) {
        hostKey = "\(host):\(port)"
        let key = hostKey
        let pin = pinResult
        conn = NetworkConnection(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
                                 using: .parameters {
            TransportConfig.quic().tls.certificateValidator { _, trust in
                let t = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let leaf = chain.first else {
                    return false
                }
                let fp = HostIdentity.fingerprint(of: leaf)
                guard var known = try? KnownHosts() else { return false }
                let verdict = known.check(host: key, fingerprint: fp)
                await pin.record(verdict: verdict, fingerprint: fp)
                if case .mismatch = verdict { return false }
                return true
            }
        })
        (inputMessages, inputQueue) = AsyncStream.makeStream(of: ControlMessage.self)
    }

    /// Handshake. Returns the host's stream parameters.
    public func connect(password: String, viewerName: String) async throws -> ControlMessage.Welcome {
        let raw: QUIC.Stream<QUICStream>
        do {
            raw = try await conn.openStream()
        } catch {
            if case let (.mismatch(expected), got)? = await pinResult.outcome {
                throw ViewerError.hostKeyMismatch(host: hostKey, expected: expected, got: got)
            }
            throw error
        }
        if case let (.newlyPinned, fp)? = await pinResult.outcome { onNewHostPinned?(fp) }

        control = MessageStream(raw)
        try await control.sendTag(.control)
        try await control.send(.hello(version: RMDPWire.protocolVersion, password: password, viewerName: viewerName))
        switch try await control.receive() {
        case .welcome(let w)?:
            input = MessageStream(try await conn.openStream())
            try await input.sendTag(.input)
            startInputPump()
            return w
        case .reject(let r)?: throw ViewerError.rejected(r)
        case let m?: throw ViewerError.unexpectedMessage("\(m)")
        case nil: throw ViewerError.closed
        }
    }

    /// Receive loop for video datagrams. Runs until the connection ends.
    public func receiveDatagrams(_ handler: @Sendable (Data) -> Void) async throws {
        let d = try await conn.datagrams
        while true {
            let m = try await d.receive()
            handler(m.content)
        }
    }

    /// Receive loop for host → viewer control messages (pong, reject, …).
    public func receiveControl(_ handler: @Sendable (ControlMessage) -> Void) async throws {
        while let m = try await control.receive() { handler(m) }
        throw ViewerError.closed
    }

    public func sendControl(_ m: ControlMessage) async throws { try await control.send(m) }

    /// Queue an input event. Never blocks the caller (UI thread); order is preserved and nothing
    /// is dropped — losing a keystroke is unforgivable (§2.8).
    public func sendInput(_ m: ControlMessage) { inputQueue.yield(m) }

    private func startInputPump() {
        let stream = input!, messages = inputMessages
        Task.detached(priority: .userInitiated) {
            for await m in messages { try? await stream.send(m) }
        }
    }
}

actor PinResult {
    private(set) var outcome: (KnownHosts.Verdict, String)?
    func record(verdict: KnownHosts.Verdict, fingerprint: String) { outcome = (verdict, fingerprint) }
}
