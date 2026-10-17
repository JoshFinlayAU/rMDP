import Foundation

/// Tunables for viewer-side reassembly and loss handling. Named, documented, in one place
/// (CLAUDE.md: no magic constants in the adaptive path).
public struct ReassemblyConfig: Sendable {
    /// How many NEWER complete frames may arrive while an older frame is still incomplete before
    /// we declare the older one lost. Small: QUIC datagrams on one path rarely reorder by much,
    /// and every frame of waiting is a frame of added latency.
    public var maxReorderFrames: Int = 2
    /// An incomplete frame older than this (by receive time of its first fragment) is lost.
    public var fragmentTimeoutNanos: UInt64 = 50_000_000
    /// While waiting for an IDR after loss, re-ask at most this often (the request itself could
    /// be in flight, and the host may already be encoding one).
    public var keyframeRequestIntervalNanos: UInt64 = 250_000_000
    /// Cap on concurrently-assembling frames (bounds memory under garbage input).
    public var maxPendingFrames: Int = 16

    public init() {}
}

/// Turns video datagrams back into frames, in order, and decides when the decode chain is broken.
///
/// v1 recovery policy (draft §2.5's LTR scheme comes later): full-frame H.264 P-frames depend on
/// their predecessor, so ANY lost frame poisons everything after it. On loss we stop emitting
/// frames, ask the host for a keyframe, and resume at the next IDR. The viewer keeps showing the
/// last good frame meanwhile — a freeze, never garbage.
///
/// Pure logic, driven by `ingest` + `poll` with caller-supplied time, so it's exactly testable.
public struct Reassembler {
    public enum Event: Equatable {
        case frame(EncodedVideoFrame)
        /// Decode chain broken — send a keyframe request now.
        case requestKeyframe
    }

    public let config: ReassemblyConfig

    private struct Pending {
        var header: VideoFragmentHeader
        var parts: [Data?]
        var received: Int
        var firstSeenNanos: UInt64
        var bytes: Int
    }
    private var pending: [UInt32: Pending] = [:]
    private var complete: [UInt32: EncodedVideoFrame] = [:]
    /// Next frame ID the decoder needs; nil until the first keyframe (we can't start mid-GOP).
    private var nextExpected: UInt32?
    private var awaitingKeyframe = true
    private var lastKeyframeRequestNanos: UInt64?
    /// When the current wait for an IDR began (first poll for the initial wait).
    private var awaitingSinceNanos: UInt64?

    public private(set) var framesLost = 0
    public private(set) var datagramsRejected = 0

    public init(config: ReassemblyConfig = ReassemblyConfig()) { self.config = config }

    public var isAwaitingKeyframe: Bool { awaitingKeyframe }

    /// Feed one datagram. Returns events in the order the caller should act on them.
    public mutating func ingest(_ datagram: Data, nowNanos: UInt64) -> [Event] {
        var r = ByteReader(datagram)
        guard let h = try? VideoFragmentHeader.parse(&r) else { datagramsRejected += 1; return [] }
        let body = r.rest()

        // Stale: older than what the decoder already consumed.
        if let next = nextExpected, !awaitingKeyframe, Int32(bitPattern: h.frameID &- next) < 0 {
            return poll(nowNanos: nowNanos)
        }
        if complete[h.frameID] == nil {
            var p = pending[h.frameID] ?? Pending(header: h, parts: Array(repeating: nil, count: Int(h.fragCount)),
                                                   received: 0, firstSeenNanos: nowNanos, bytes: 0)
            guard p.header.fragCount == h.fragCount else { datagramsRejected += 1; return [] }
            if p.parts[Int(h.fragIndex)] == nil {
                p.parts[Int(h.fragIndex)] = body
                p.received += 1
                p.bytes += body.count
            }
            if p.received == p.parts.count {
                pending[h.frameID] = nil
                var payload = Data(capacity: p.bytes)
                for part in p.parts { payload.append(part!) }
                if let f = try? EncodedVideoFrame.fromPayload(payload, header: p.header) {
                    complete[h.frameID] = f
                } else {
                    datagramsRejected += 1
                }
            } else {
                pending[h.frameID] = p
                if pending.count > config.maxPendingFrames, let oldest = oldestPendingID() {
                    pending[oldest] = nil
                }
            }
        }
        return poll(nowNanos: nowNanos)
    }

    /// Advance time-based decisions (fragment timeouts, keyframe re-requests). Call periodically
    /// even when no datagrams arrive — a stalled link must still trigger recovery.
    public mutating func poll(nowNanos: UInt64) -> [Event] {
        var events: [Event] = []

        if awaitingKeyframe {
            // Resume at the newest complete keyframe; anything older is useless.
            if let kf = complete.values.filter(\.isKeyframe).max(by: { Self.older($0.frameID, than: $1.frameID) }) {
                complete = complete.filter { !Self.older($0.key, than: kf.frameID) }
                pending = pending.filter { !Self.older($0.key, than: kf.frameID) }
                awaitingKeyframe = false
                nextExpected = kf.frameID
                awaitingSinceNanos = nil
            } else {
                // P-frames are undecodable until an IDR arrives — don't hoard them. Discarding
                // one proves we joined mid-GOP, so ask straight away; otherwise only ask once the
                // interval passes (at startup the host's opening IDR is usually still arriving).
                let before = complete.count
                complete = complete.filter { $0.value.isKeyframe }
                let discardedPFrame = complete.count < before
                let since = awaitingSinceNanos ?? nowNanos
                awaitingSinceNanos = since
                let reference = lastKeyframeRequestNanos ?? since
                let due = nowNanos &- reference >= config.keyframeRequestIntervalNanos
                if due || (discardedPFrame && lastKeyframeRequestNanos == nil) {
                    lastKeyframeRequestNanos = nowNanos
                    events.append(.requestKeyframe)
                }
                return events
            }
        }

        while var next = nextExpected {
            if let f = complete.removeValue(forKey: next) {
                events.append(.frame(f))
                next &+= 1
                nextExpected = next
                continue
            }
            // `next` missing. Is it lost?
            let newerComplete = complete.keys.filter { Self.older(next, than: $0) }.count
            let timedOut = pending[next].map { nowNanos &- $0.firstSeenNanos > config.fragmentTimeoutNanos } ?? false
            // A newer frame has started arriving while `next` never showed up at all.
            let neverArrived = pending[next] == nil && pending.values.contains {
                Self.older(next, than: $0.header.frameID) && nowNanos &- $0.firstSeenNanos > config.fragmentTimeoutNanos
            }
            if newerComplete > config.maxReorderFrames || timedOut || neverArrived {
                framesLost += 1
                awaitingKeyframe = true
                awaitingSinceNanos = nowNanos
                lastKeyframeRequestNanos = nil
                pending[next] = nil
                // A keyframe already sitting in `complete` lets us recover immediately.
                events.append(contentsOf: poll(nowNanos: nowNanos))
                if !events.contains(where: { if case .frame = $0 { return true }; return false }) &&
                    !events.contains(.requestKeyframe) {
                    lastKeyframeRequestNanos = nowNanos
                    events.append(.requestKeyframe)
                }
            }
            break
        }
        return events
    }

    /// Wrap-safe ordering on 32-bit frame IDs.
    static func older(_ a: UInt32, than b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }

    private func oldestPendingID() -> UInt32? {
        pending.keys.min(by: { Self.older($0, than: $1) })
    }
}
