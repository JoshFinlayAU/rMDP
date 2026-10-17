// rMDP spike 001G — real QUIC client against a remote aioquic server.
//
// This is the end-to-end measurement the earlier parts could only approximate:
// Apple's QUIC stack, its own congestion control, over a genuine WAN path,
// talking to a real QUIC peer. Datagrams are echoed by the server so we get
// true RTT per packet, and the server independently reports what it received
// so forward-path loss is attributable rather than inferred.

import Foundation
import Network

func runRealQuicClient(host: String, port: UInt16, mbit: Double, frames: Int) {
    let payloadSize = 1100
    let frameHz = 60.0
    let perFrame = max(1, Int((mbit * 1e6 / 8.0) / frameHz / Double(payloadSize)))

    let opts = NWProtocolQUIC.Options(alpn: ["rmdp-spike"])
    opts.isDatagram = true
    opts.maxDatagramFrameSize = 1400
    opts.idleTimeout = 60_000
    opts.maxUDPPayloadSize = 1400
    // Self-signed peer on a pinned host: accept for the spike.
    sec_protocol_options_set_verify_block(
        opts.securityProtocolOptions,
        { _, _, complete in complete(true) },
        DispatchQueue.global()
    )

    let params = NWParameters(quic: opts)
    let conn = NWConnection(host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: port)!,
                            using: params)
    let connQueue = DispatchQueue(label: "rmdp.realquic.conn", qos: .userInteractive)
    let pacer = DispatchQueue(label: "rmdp.realquic.pacer", qos: .userInteractive)

    let lock = NSLock()
    var sendTimes = [UInt32: UInt64]()
    var rtts: [Double] = []
    var echoed = 0
    var sent = 0
    let sem = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable {
        var pending: NWConnection.PendingDataTransferReport?
        var recv: (@Sendable () -> Void)?
    }
    let box = Box()

    let receiveLoop: @Sendable () -> Void = {
        conn.receiveMessage { data, _, _, err in
            if let data, data.count >= 4 {
                let now = DispatchTime.now().uptimeNanoseconds
                let seq = data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
                }
                lock.lock()
                echoed += 1
                if let t0 = sendTimes[seq] {
                    rtts.append(Double(now &- t0) / 1e6)
                }
                lock.unlock()
            }
            if err == nil { box.recv?() }
        }
    }
    box.recv = receiveLoop

    conn.stateUpdateHandler = { st in
        switch st {
        case .ready:
            print("  QUIC handshake complete — connection ready")
            box.pending = conn.startDataTransferReport()
            receiveLoop()
            pacer.async {
                var payload = Data(repeating: 0xAB, count: payloadSize)
                let start = DispatchTime.now().uptimeNanoseconds
                var seq: UInt32 = 0
                let interval = 1.0 / frameHz

                for frame in 0..<frames {
                    let target = start &+ UInt64(Double(frame) * interval * 1e9)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if target > now, target - now > 1000 {
                        usleep(useconds_t((target - now) / 1000))
                    }
                    for _ in 0..<perFrame {
                        let t = DispatchTime.now().uptimeNanoseconds
                        payload.withUnsafeMutableBytes { raw in
                            raw.storeBytes(of: seq.bigEndian, toByteOffset: 0, as: UInt32.self)
                            raw.storeBytes(of: t.bigEndian, toByteOffset: 4, as: UInt64.self)
                        }
                        lock.lock(); sendTimes[seq] = t; sent += 1; lock.unlock()
                        conn.send(content: payload, completion: .contentProcessed { _ in })
                        seq &+= 1
                    }
                }
                // allow late echoes to land
                DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { sem.signal() }
            }
        case .failed(let e):
            print("  QUIC connection FAILED: \(e)")
            sem.signal()
        case .waiting(let e):
            print("  waiting: \(e)")
        default: break
        }
    }

    conn.start(queue: connQueue)

    if sem.wait(timeout: .now() + 120) == .timedOut {
        print("  TIMEOUT — no completion within 120s")
    }

    lock.lock()
    let s = sent, e = echoed
    let r = rtts
    lock.unlock()

    print("  sent=\(s) echoed=\(e) unreturned=\(s - e) " +
          String(format: "(%.2f%%)", s > 0 ? 100.0 * Double(s - e) / Double(s) : 0))
    summarize("RTT (ms)                   ", r)
    if !r.isEmpty, let mn = r.min(), let mx = r.max() {
        print(String(format: "  queue delay: min=%.1fms max=%.1fms swing=%.1fms", mn, mx, mx - mn))
    }

    let group = DispatchGroup()
    group.enter()
    if let pending = box.pending {
        pending.collect(queue: .global()) { rep in
            let p = rep.aggregatePathReport
            print("\n  Apple QUIC telemetry (real path):")
            print("    interface:     \(p.interface.type)")
            print(String(format: "    rtt smoothed:  %.1f ms", p.transportSmoothedRTT * 1000))
            print(String(format: "    rtt minimum:   %.1f ms", p.transportMinimumRTT * 1000))
            print(String(format: "    rtt variance:  %.1f ms", p.transportRTTVariance * 1000))
            print("    sent app:      \(p.sentApplicationByteCount) B")
            print("    retransmitted: \(p.retransmittedTransportByteCount) B")
            print("    rx out-of-order: \(p.receivedTransportOutOfOrderByteCount) B")
            group.leave()
        }
    } else { group.leave() }
    _ = group.wait(timeout: .now() + 10)
    conn.cancel()
}
