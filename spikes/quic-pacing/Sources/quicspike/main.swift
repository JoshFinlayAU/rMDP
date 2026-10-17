// rMDP spike 001 — QUIC datagram pacing on Network.framework
//
// Question: can we drive send rate from our own pacer, or does Apple's
// congestion control own it? Measures:
//   A. send-completion backpressure — does completion latency track offered load?
//   B. pacing accuracy at frame cadence (60fps bursts)
//   C. what telemetry we can actually read back (RTT etc.)
//
// Loopback only. This measures the API's behaviour, not the network's.

import Foundation
import Network

// MARK: - Config

let payloadSize = 1100          // bytes per datagram, under typical MTU
let frameHz = 60.0
let testFrames = Int(ProcessInfo.processInfo.environment["RMDP_FRAMES"] ?? "300") ?? 300
let datagramsPerFrame = Int(ProcessInfo.processInfo.environment["RMDP_DPF"] ?? "12") ?? 12

let alpn = "rmdp-spike"
let port: NWEndpoint.Port = 7443

// MARK: - Stats

final class Stats: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var completionLatenciesUs: [Double] = []
    private(set) var sendCallLatenciesUs: [Double] = []
    private(set) var frameStartDeltasUs: [Double] = []
    private(set) var sent = 0
    private(set) var completed = 0
    private(set) var errors = 0

    func recordCompletion(_ us: Double) {
        lock.lock(); defer { lock.unlock() }
        completionLatenciesUs.append(us); completed += 1
    }
    func recordSendCall(_ us: Double) {
        lock.lock(); defer { lock.unlock() }
        sendCallLatenciesUs.append(us); sent += 1
    }
    func recordFrameDelta(_ us: Double) {
        lock.lock(); defer { lock.unlock() }
        frameStartDeltasUs.append(us)
    }
    func recordError() { lock.lock(); errors += 1; lock.unlock() }

    func snapshot() -> (sent: Int, completed: Int, errors: Int) {
        lock.lock(); defer { lock.unlock() }
        return (sent, completed, errors)
    }
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let idx = Int((Double(s.count - 1) * p).rounded())
    return s[idx]
}

func summarize(_ name: String, _ xs: [Double]) {
    guard !xs.isEmpty else { print("  \(name): no samples"); return }
    let mean = xs.reduce(0, +) / Double(xs.count)
    print(String(format: "  %@  n=%d  mean=%.1fus  p50=%.1f  p95=%.1f  p99=%.1f  max=%.1f",
                 name, xs.count, mean,
                 percentile(xs, 0.50), percentile(xs, 0.95),
                 percentile(xs, 0.99), xs.max() ?? 0))
}

// MARK: - Identity (self-signed, ad-hoc, for loopback only)

func makeIdentity() -> sec_identity_t? {
    // Prefer a throwaway keychain (RMDP_KEYCHAIN) so we never touch — or prompt
    // against — the user's login keychain. Self-signed is fine here: loopback
    // and a pinned peer, not a public CA.
    var searchList: [SecKeychain]? = nil
    if let kcPath = ProcessInfo.processInfo.environment["RMDP_KEYCHAIN"] {
        var kc: SecKeychain?
        if SecKeychainOpen(kcPath, &kc) == errSecSuccess, let kc {
            _ = SecKeychainUnlock(kc, UInt32("rmdpspike".utf8.count), "rmdpspike", true)
            searchList = [kc]
        }
    }

    var query: [String: Any] = [
        kSecClass as String: kSecClassIdentity,
        kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if let searchList {
        query[kSecMatchSearchList as String] = searchList as CFArray
    }

    var copyResult: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &copyResult)
    guard status == errSecSuccess, let result = copyResult else {
        print("  (no identity found, status=\(status))")
        return nil
    }
    return sec_identity_create(result as! SecIdentity)
}

// MARK: - Parameters

func quicParams(isServer: Bool, identity: sec_identity_t?) -> NWParameters {
    let opts = NWProtocolQUIC.Options(alpn: [alpn])
    opts.isDatagram = true
    opts.maxDatagramFrameSize = 1200
    opts.idleTimeout = 30_000
    opts.maxUDPPayloadSize = 1400

    if isServer, let identity {
        sec_protocol_options_set_local_identity(opts.securityProtocolOptions, identity)
    } else {
        // Loopback spike: accept the self-signed peer.
        sec_protocol_options_set_verify_block(
            opts.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue.global()
        )
    }
    let params = NWParameters(quic: opts)
    return params
}

// MARK: - Receiver

func runReceiver(identity: sec_identity_t, ready: @escaping @Sendable () -> Void) throws -> NWListener {
    let params = quicParams(isServer: true, identity: identity)
    let listener = try NWListener(using: params, on: port)
    var received = 0
    var firstAt: DispatchTime?
    var lastAt: DispatchTime?
    var bytes = 0

    listener.newConnectionHandler = { conn in
        conn.stateUpdateHandler = { st in
            if case .ready = st { }
        }
        func pump() {
            conn.receiveMessage { data, _, _, err in
                if let data, !data.isEmpty {
                    received += 1
                    bytes += data.count
                    let now = DispatchTime.now()
                    if firstAt == nil { firstAt = now }
                    lastAt = now
                }
                if err == nil { pump() }
            }
        }
        conn.start(queue: .global(qos: .userInteractive))
        pump()
    }
    listener.stateUpdateHandler = { st in
        if case .ready = st { ready() }
    }
    listener.start(queue: .global(qos: .userInteractive))

    // Stash a reporter on the listener via an atexit-style closure
    receiverReport = {
        guard let f = firstAt, let l = lastAt, received > 0 else {
            print("  receiver: no datagrams received")
            return
        }
        let secs = Double(l.uptimeNanoseconds - f.uptimeNanoseconds) / 1e9
        let mbit = secs > 0 ? (Double(bytes) * 8.0 / secs) / 1e6 : 0
        print(String(format: "  receiver: %d datagrams, %.2f MB, %.2fs, %.2f Mbit/s goodput",
                     received, Double(bytes) / 1e6, secs, mbit))
    }
    return listener
}

nonisolated(unsafe) var receiverReport: (() -> Void)?

// MARK: - Sender

/// Dedicated pacer queue, deliberately separate from the connection queue.
let pacerQueue = DispatchQueue(label: "rmdp.spike.pacer", qos: .userInteractive)

func runSender(stats: Stats, done: @escaping @Sendable () -> Void) {
    let params = quicParams(isServer: false, identity: nil)
    let targetHost = ProcessInfo.processInfo.environment["RMDP_QUIC_TARGET"] ?? "127.0.0.1"
    let relayOn = ProcessInfo.processInfo.environment["RMDP_RELAY"] != nil
    let targetPort = relayOn ? (NWEndpoint.Port(rawValue: 7444) ?? port) : port
    let conn = NWConnection(host: NWEndpoint.Host(targetHost), port: targetPort, using: params)
    let queue = DispatchQueue(label: "rmdp.spike.conn", qos: .userInteractive)
    let payload = Data(repeating: 0xAB, count: payloadSize)

    conn.stateUpdateHandler = { st in
        switch st {
        case .ready:
            // Report must be started before the traffic it measures.
            let pending = conn.startDataTransferReport()
            // MUST NOT run on `queue` — that is the connection's own callback
            // queue, and a long-running pacer there serializes every send
            // completion behind it (measured: 2.5s mean, pure artifact).
            pacerQueue.async { paceLoop(conn: conn, payload: payload, stats: stats,
                                        pending: pending, done: done) }
        case .failed(let e):
            print("  sender failed: \(e)")
            done()
        case .cancelled:
            done()
        default: break
        }
    }
    conn.start(queue: queue)
}

func paceLoop(conn: NWConnection, payload: Data, stats: Stats,
              pending: NWConnection.PendingDataTransferReport,
              done: @escaping @Sendable () -> Void) {
    let frameInterval = 1.0 / frameHz
    let start = DispatchTime.now()
    var lastFrameStart = start

    for frame in 0..<testFrames {
        // Target wall-clock for this frame's burst
        let target = start.uptimeNanoseconds &+ UInt64(Double(frame) * frameInterval * 1e9)
        let now = DispatchTime.now().uptimeNanoseconds
        if target > now {
            // Busy-ish precise sleep: the pacer's own scheduling accuracy is
            // part of what we're measuring, so use a real sleep not a spin.
            let sleepNs = target - now
            if sleepNs > 1000 {
                usleep(useconds_t(sleepNs / 1000))
            }
        }

        let frameStart = DispatchTime.now()
        stats.recordFrameDelta(Double(frameStart.uptimeNanoseconds &- lastFrameStart.uptimeNanoseconds) / 1000.0)
        lastFrameStart = frameStart

        for _ in 0..<datagramsPerFrame {
            let sendCallStart = DispatchTime.now()
            conn.send(content: payload, completion: .contentProcessed { err in
                let us = Double(DispatchTime.now().uptimeNanoseconds &- sendCallStart.uptimeNanoseconds) / 1000.0
                if err != nil { stats.recordError() } else { stats.recordCompletion(us) }
            })
            let callUs = Double(DispatchTime.now().uptimeNanoseconds &- sendCallStart.uptimeNanoseconds) / 1000.0
            stats.recordSendCall(callUs)
        }
    }

    // Let in-flight completions land
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
        reportTelemetry(conn: conn, pending: pending, then: done)
    }
}

// MARK: - Telemetry

func reportTelemetry(conn: NWConnection, pending: NWConnection.PendingDataTransferReport,
                     then: @escaping @Sendable () -> Void) {
    pending.collect(queue: .global()) { r in
        let p = r.aggregatePathReport
        print("\n[C] Telemetry readable from NWConnection (aggregate path):")
        print(String(format: "  duration:        %.3fs", r.duration))
        print("  interface:       \(p.interface.type)")
        print("  sent:            app=\(p.sentApplicationByteCount)B transport=\(p.sentTransportByteCount)B ip_pkts=\(p.sentIPPacketCount)")
        print("  retransmitted:   \(p.retransmittedTransportByteCount)B")
        print(String(format: "  rtt:             smoothed=%.3fms min=%.3fms var=%.3fms",
                     p.transportSmoothedRTT * 1000, p.transportMinimumRTT * 1000,
                     p.transportRTTVariance * 1000))
        print("  rx out-of-order: \(p.receivedTransportOutOfOrderByteCount)B  dup=\(p.receivedTransportDuplicateByteCount)B")
        then()
    }
}

// MARK: - Main

// --- Real QUIC client mode: connect to a remote aioquic server over a real path ---
if let qHost = ProcessInfo.processInfo.environment["RMDP_QUIC_REMOTE"] {
    let mbit = Double(ProcessInfo.processInfo.environment["RMDP_QUIC_MBIT"] ?? "2") ?? 2
    let frames = Int(ProcessInfo.processInfo.environment["RMDP_QUIC_FRAMES"] ?? "180") ?? 180
    print("rMDP spike 001G — REAL QUIC over real WAN path")
    print("target: \(qHost):7443   offered: \(mbit) Mbit/s\n")
    runRealQuicClient(host: qHost, port: 7443, mbit: mbit, frames: frames)
    exit(0)
}

// --- WAN probe mode: real path, raw UDP ground truth ---
if let wanHost = ProcessInfo.processInfo.environment["RMDP_WAN_HOST"] {
    let mbit = Double(ProcessInfo.processInfo.environment["RMDP_WAN_MBIT"] ?? "8") ?? 8
    let frames = Int(ProcessInfo.processInfo.environment["RMDP_WAN_FRAMES"] ?? "300") ?? 300
    let pl = Int(ProcessInfo.processInfo.environment["RMDP_WAN_PAYLOAD"] ?? "1100") ?? 1100
    print("rMDP spike 001b — real-WAN pacer probe (raw UDP)")
    print("target: \(wanHost):7443   offered: \(mbit) Mbit/s  frames: \(frames) @ 60Hz\n")
    var relayForProbe: ImpairmentRelay?
    var probePort: UInt16 = 7443
    if ProcessInfo.processInfo.environment["RMDP_RELAY"] != nil {
        let rm = Double(ProcessInfo.processInfo.environment["RMDP_RELAY_MBIT"] ?? "2") ?? 2
        let rd = Double(ProcessInfo.processInfo.environment["RMDP_RELAY_DELAY_MS"] ?? "57") ?? 57
        let rl = Double(ProcessInfo.processInfo.environment["RMDP_RELAY_LOSS"] ?? "0") ?? 0
        let rr = ImpairmentRelay(listenPort: 7444, targetPort: 7443,
                                 rateMbit: rm, delayMs: rd, lossRate: rl)
        try? rr.start()
        relayForProbe = rr
        probePort = 7444
        print(String(format: "  relay: %.1f Mbit/s, %.0fms one-way, %.1f%% loss\n", rm, rd, rl*100))
    }
    let r = runWanProbe(host: wanHost, port: probePort, mbit: mbit,
                        frames: frames, frameHz: 60.0, payload: pl)
    if let rr = relayForProbe {
        let rs = rr.stats()
        print("  relay: forwarded=\(rs.forwarded) dropped_queue=\(rs.queue)")
        rr.stop()
    }
    print("  sent=\(r.sent) echoed=\(r.echoed) lost=\(r.lost) " +
          String(format: "(%.2f%%)", r.sent > 0 ? 100.0*Double(r.lost)/Double(r.sent) : 0))
    summarize("RTT (ms)                   ", r.rttMs)
    summarize("inter-arrival gap (us)     ", r.burstDispersionUs)
    summarize("|RTT delta| (us) OWD trend ", r.owdTrendUs.map { abs($0) })
    if !r.rttMs.isEmpty {
        let mn = r.rttMs.min()!, mx = r.rttMs.max()!
        print(String(format: "  queue delay range: min=%.1fms max=%.1fms swing=%.1fms",
                     mn, mx, mx-mn))
    }
    exit(0)
}

// --- Relay mode: run QUIC or raw UDP through a calibrated impairment path ---
// Calibrated against the MEASURED Brisbane->Darwin curve (spike 001c):
//   ~114ms baseline RTT, knee between 1-2 Mbit/s, deep queue above it.
// Both stacks see identical conditions, so the delta is attributable to the
// congestion controller and nothing else.
let relayEnabled = ProcessInfo.processInfo.environment["RMDP_RELAY"] != nil
var activeRelay: ImpairmentRelay?
if relayEnabled {
    let mbit = Double(ProcessInfo.processInfo.environment["RMDP_RELAY_MBIT"] ?? "2") ?? 2
    let delay = Double(ProcessInfo.processInfo.environment["RMDP_RELAY_DELAY_MS"] ?? "57") ?? 57
    let loss = Double(ProcessInfo.processInfo.environment["RMDP_RELAY_LOSS"] ?? "0") ?? 0
    let r = ImpairmentRelay(listenPort: 7444, targetPort: 7443,
                            rateMbit: mbit, delayMs: delay, lossRate: loss)
    do {
        try r.start()
        activeRelay = r
        print(String(format: "  relay: %.1f Mbit/s bottleneck, %.0fms one-way (=%.0fms RTT), %.1f%% loss\n",
                     mbit, delay, delay*2, loss*100))
    } catch {
        print("  relay failed to start: \(error)")
        exit(5)
    }
}

print("rMDP spike 001 — QUIC datagram pacing on Network.framework")
print("host: \(ProcessInfo.processInfo.operatingSystemVersionString), arm64")
print("offered load: \(datagramsPerFrame) x \(payloadSize)B @ \(Int(frameHz))Hz = "
      + String(format: "%.2f Mbit/s\n", Double(datagramsPerFrame * payloadSize * 8) * frameHz / 1e6))

guard let identity = makeIdentity() else {
    print("SKIP: no keychain identity available for the QUIC listener.")
    print("      The API-surface findings (parts A/C) do not depend on this;")
    print("      see the header audit in the spike report.")
    exit(2)
}

let stats = Stats()
let sem = DispatchSemaphore(value: 0)

do {
    let listener = try runReceiver(identity: identity) {
        runSender(stats: stats) { sem.signal() }
    }
    defer { listener.cancel() }

    if sem.wait(timeout: .now() + 60) == .timedOut {
        print("TIMEOUT — connection never completed")
        exit(3)
    }
} catch {
    print("listener error: \(error)")
    exit(4)
}

let snap = stats.snapshot()
print("\n[A] Send-completion backpressure")
print("  datagrams offered: \(snap.sent), completed: \(snap.completed), errors: \(snap.errors)")
summarize("send() call blocking time  ", stats.sendCallLatenciesUs)
summarize("completion callback latency", stats.completionLatenciesUs)

print("\n[B] Pacer scheduling accuracy (inter-frame deltas, target \(Int(1e6/frameHz))us)")
summarize("frame interval             ", stats.frameStartDeltasUs)

receiverReport?()
if let r = activeRelay {
    let rs = r.stats()
    print("  relay: forwarded=\(rs.forwarded) dropped_loss=\(rs.loss) dropped_queue=\(rs.queue)")
    r.stop()
}
print("")
