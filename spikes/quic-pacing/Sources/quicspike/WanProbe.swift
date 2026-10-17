// rMDP spike 001b — real-WAN pacer probe.
//
// Sends frame-cadence bursts of UDP datagrams to a remote echo responder over
// a real path, and measures what a SQP-style controller would actually consume:
//
//   - RTT per packet (echo), and its variance
//   - one-way-delay TREND (the congestion signal — absolute OWD needs clock
//     sync, the gradient does not)
//   - receiver-side inter-packet dispersion => bandwidth estimate from the
//     frame burst itself ("the frame is the probe")
//   - loss, by sequence gap
//
// This is raw UDP on purpose: it establishes the ground truth for what the
// path can do, independent of whether Network.framework's QUIC will let us
// drive the send rate. Compare the two to see what Apple's CC is costing us.

import Foundation
import Darwin

struct WanResult {
    var sent = 0
    var echoed = 0
    var rttMs: [Double] = []
    var owdTrendUs: [Double] = []
    var burstDispersionUs: [Double] = []
    var lost = 0
}

func runWanProbe(host: String, port: UInt16, mbit: Double,
                 frames: Int, frameHz: Double, payload: Int) -> WanResult {
    var out = WanResult()

    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { print("socket() failed"); return out }
    defer { close(fd) }

    var snd: Int32 = 4 << 20
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var dest = sockaddr_in()
    dest.sin_family = sa_family_t(AF_INET)
    dest.sin_port = port.bigEndian
    dest.sin_addr.s_addr = inet_addr(host)

    // datagrams per frame to hit the requested rate
    let perFrame = max(1, Int((mbit * 1e6 / 8.0) / frameHz / Double(payload)))
    let frameInterval = 1.0 / frameHz

    var buf = [UInt8](repeating: 0xAB, count: payload)
    var rxbuf = [UInt8](repeating: 0, count: 65536)

    // seq -> send time
    var sendTimes = [UInt32: UInt64]()
    sendTimes.reserveCapacity(frames * perFrame)
    var seq: UInt32 = 0

    // Receiver thread: drain echoes continuously so RTT isn't inflated by
    // us not reading. This matters — a blocked reader looks like path delay.
    let rxLock = NSLock()
    var rttSamples: [Double] = []
    var arrivalsBySeq: [UInt32: UInt64] = [:]
    var stopRx = false

    let rxThread = Thread {
        while true {
            rxLock.lock(); let s = stopRx; rxLock.unlock()
            if s { return }
            let n = recv(fd, &rxbuf, rxbuf.count, 0)
            guard n >= 12 else { continue }
            let now = DispatchTime.now().uptimeNanoseconds
            let rseq = rxbuf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian }
            rxLock.lock()
            arrivalsBySeq[rseq] = now
            if let t0 = sendTimes[rseq] {
                rttSamples.append(Double(now &- t0) / 1e6)
            }
            rxLock.unlock()
        }
    }
    rxThread.qualityOfService = .userInteractive
    rxThread.start()

    let start = DispatchTime.now().uptimeNanoseconds
    for frame in 0..<frames {
        let target = start &+ UInt64(Double(frame) * frameInterval * 1e9)
        let now = DispatchTime.now().uptimeNanoseconds
        if target > now {
            let ns = target - now
            if ns > 1000 { usleep(useconds_t(ns / 1000)) }
        }

        for _ in 0..<perFrame {
            let t = DispatchTime.now().uptimeNanoseconds
            buf.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: seq.bigEndian, toByteOffset: 0, as: UInt32.self)
                raw.storeBytes(of: t.bigEndian, toByteOffset: 4, as: UInt64.self)
            }
            rxLock.lock(); sendTimes[seq] = t; rxLock.unlock()

            _ = withUnsafePointer(to: &dest) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buf.withUnsafeBufferPointer { bp in
                        sendto(fd, bp.baseAddress, payload, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            out.sent += 1
            seq &+= 1
        }
    }

    // drain late echoes
    Thread.sleep(forTimeInterval: 1.5)
    rxLock.lock(); stopRx = true
    let rtts = rttSamples
    let arrivals = arrivalsBySeq
    rxLock.unlock()

    out.rttMs = rtts
    out.echoed = arrivals.count
    out.lost = out.sent - out.echoed

    // OWD trend: RTT deltas between consecutive received packets. A rising
    // trend = queue building = the signal a delay-based controller acts on.
    let ordered = arrivals.keys.sorted()
    for i in 1..<max(1, ordered.count) {
        let a = ordered[i - 1], b = ordered[i]
        guard let ta = arrivals[a], let tb = arrivals[b] else { continue }
        out.burstDispersionUs.append(Double(tb &- ta) / 1000.0)
    }
    if rtts.count > 1 {
        for i in 1..<rtts.count {
            out.owdTrendUs.append((rtts[i] - rtts[i - 1]) * 1000.0)
        }
    }
    return out
}
