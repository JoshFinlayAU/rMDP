import Foundation
import Network
import CryptoKit
import RMDPProtocol

/// What the host app plugs into the transport. Called from transport tasks — implementations
/// must hop to their own queues; never do frame work inline here.
public protocol HostSessionDelegate: AnyObject, Sendable {
    /// Stream parameters to advertise in `welcome`.
    func welcome() -> ControlMessage.Welcome
    func sessionStarted(_ session: HostSession)
    func sessionEnded(_ session: HostSession, error: Error?)
    /// Control-channel messages the transport doesn't handle itself (keyframeRequest, stats).
    func session(_ session: HostSession, control: ControlMessage)
    /// Input-channel messages, in order.
    func session(_ session: HostSession, input: ControlMessage)
}

/// One authenticated viewer.
public final class HostSession: @unchecked Sendable {
    public let viewerName: String
    public let remote: String
    private let continuation: AsyncStream<EncodedVideoFrame>.Continuation
    let frames: AsyncStream<EncodedVideoFrame>

    /// Frames queued but not yet on the wire. Small on purpose: a frame that waits behind two
    /// others is already stale, and queueing is how latency balloons (spike 001).
    public static let maxQueuedFrames = 2

    init(viewerName: String, remote: String) {
        self.viewerName = viewerName
        self.remote = remote
        (frames, continuation) = AsyncStream.makeStream(of: EncodedVideoFrame.self,
                                                       bufferingPolicy: .bufferingNewest(Self.maxQueuedFrames))
    }

    /// Queue a frame for sending. Returns false if it pushed an older queued frame out — the
    /// viewer's decode chain is then broken, so the caller must make the next frame an IDR.
    /// Safe to call from the encoder's callback thread; never blocks.
    @discardableResult
    public func sendVideo(_ frame: EncodedVideoFrame) -> Bool {
        if case .dropped = continuation.yield(frame) { return false }
        return true
    }

    func finish() { continuation.finish() }
}

public enum HostServerError: Error, CustomStringConvertible {
    case viewerSilent
    case authTimeout

    public var description: String {
        switch self {
        case .viewerSilent: return "viewer went silent (no control traffic)"
        case .authTimeout: return "viewer did not authenticate in time"
        }
    }
}

/// QUIC listener: authenticates one viewer at a time, then pumps video datagrams out and
/// control/input messages in.
public final class HostServer: @unchecked Sendable {
    private let port: UInt16
    private let password: String
    private let identity: HostIdentity
    private weak var delegate: HostSessionDelegate?
    private let busy = BusyFlag()

    /// Failed-auth delay — makes online password guessing slow.
    public static let authFailureDelayNanos: UInt64 = 1_000_000_000
    /// No control traffic for this long ⇒ viewer is gone. Viewers ping every 500ms, so this is
    /// 6 missed pings — far quicker than QUIC's idle timeout, and it stops us encoding into the
    /// void (a dead viewer otherwise fills the send queue and forces an IDR every frame).
    public static let viewerSilenceTimeoutNanos: UInt64 = 3_000_000_000
    /// A connection that hasn't authenticated by now is dropped.
    public static let authTimeoutNanos: UInt64 = 10_000_000_000

    public init(port: UInt16, password: String, identity: HostIdentity, delegate: HostSessionDelegate) {
        self.port = port
        self.password = password
        self.identity = identity
        self.delegate = delegate
    }

    public func run() async throws {
        let listener = try NetworkListener(using: .parameters {
            TransportConfig.quic().tls.localIdentity(identity.identity)
        }.localPort(NWEndpoint.Port(rawValue: port)!))
        try await listener.run { [self] conn in
            await handle(conn)
        }
    }

    private func handle(_ conn: NetworkConnection<QUIC>) async {
        let remote = (conn.currentPath?.remoteEndpoint ?? conn.remoteEndpoint).map { "\($0)" } ?? "?"
        let state = ConnectionState()
        do {
            // Streams and the watchdog race; whichever finishes first ends the connection
            // (returning from this handler closes it).
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    try await conn.inboundStreams { [self] raw in
                        let stream = MessageStream(raw)
                        switch try await stream.receiveTag() {
                        case .control?:
                            try await runControl(stream, conn: conn, remote: remote, state: state)
                        case .input?:
                            guard let session = await state.waitForSession() else { return }
                            while let m = try await stream.receive() { delegate?.session(session, input: m) }
                        case nil:
                            return
                        }
                    }
                }
                group.addTask { try await Self.watchdog(state) }
                try await group.next()
                group.cancelAll()
            }
            if let s = await state.session { await end(s, state: state, error: nil) }
        } catch {
            if let s = await state.session { await end(s, state: state, error: error) }
        }
    }

    private static func watchdog(_ state: ConnectionState) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            try await Task.sleep(nanoseconds: 500_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            if await state.session == nil {
                if now &- started > authTimeoutNanos { throw HostServerError.authTimeout }
            } else if now &- (await state.lastSeenNanos) > viewerSilenceTimeoutNanos {
                throw HostServerError.viewerSilent
            }
        }
    }

    private func end(_ s: HostSession, state: ConnectionState, error: Error?) async {
        guard await state.markEnded() else { return }
        s.finish()
        await busy.release()
        delegate?.sessionEnded(s, error: error)
    }

    private func runControl(_ stream: MessageStream, conn: NetworkConnection<QUIC>,
                            remote: String, state: ConnectionState) async throws {
        guard case let .hello(version, pw, name)? = try await stream.receive() else { return }
        if version != RMDPWire.protocolVersion {
            try await stream.send(.reject(reason: "protocol version \(version) unsupported (host speaks \(RMDPWire.protocolVersion))"))
            return
        }
        if !Self.constantTimeEqual(pw, password) {
            try await Task.sleep(nanoseconds: Self.authFailureDelayNanos)
            try await stream.send(.reject(reason: "authentication failed"))
            return
        }
        guard await busy.acquire() else {
            try await stream.send(.reject(reason: "host busy — another viewer is connected"))
            return
        }
        guard let delegate else { await busy.release(); return }

        let session = HostSession(viewerName: name, remote: remote)
        try await stream.send(.welcome(delegate.welcome()))
        await state.start(session)
        delegate.sessionStarted(session)

        let datagrams = try await conn.datagrams
        let sender = Task {
            for await frame in session.frames {
                for d in frame.fragments() { try await datagrams.send(d) }
            }
        }
        defer { sender.cancel() }

        while let m = try await stream.receive() {
            await state.touch()
            switch m {
            case .ping(let t):
                try await stream.send(.pong(viewerNanos: t, hostNanos: DispatchTime.now().uptimeNanoseconds))
            default:
                delegate.session(session, control: m)
            }
        }
        await end(session, state: state, error: nil)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        // Compare digests so length differences don't leak through timing either.
        let da = SHA256.hash(data: Data(a.utf8)), db = SHA256.hash(data: Data(b.utf8))
        return zip(da, db).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// One viewer at a time in v1.
actor BusyFlag {
    private var held = false
    func acquire() -> Bool { if held { return false }; held = true; return true }
    func release() { held = false }
}

/// Per-connection rendezvous between the control stream (which authenticates) and the input
/// stream (which must not deliver anything until authentication succeeded).
actor ConnectionState {
    private(set) var session: HostSession?
    private(set) var lastSeenNanos = DispatchTime.now().uptimeNanoseconds
    func touch() { lastSeenNanos = DispatchTime.now().uptimeNanoseconds }
    private var ended = false
    private var waiters: [CheckedContinuation<HostSession?, Never>] = []

    func start(_ s: HostSession) {
        session = s
        touch()
        waiters.forEach { $0.resume(returning: s) }
        waiters.removeAll()
    }

    func waitForSession() async -> HostSession? {
        if let session { return session }
        if ended { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func markEnded() -> Bool {
        if ended { return false }
        ended = true
        waiters.forEach { $0.resume(returning: nil) }
        waiters.removeAll()
        return true
    }
}
