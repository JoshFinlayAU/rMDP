// Unprivileged UDP impairment relay.
//
// sender ──► relay(:7444) ──► receiver(:7443)
//        ◄──               ◄──
//
// QUIC is encrypted UDP, so a blind datagram relay is transparent to it —
// but the token bucket, added delay, and drops are NOT: the connection's
// congestion controller sees a genuinely constrained path. This is what
// loopback can't give us, without needing sudo/pfctl.
//
// Uses BSD sockets directly. Network.framework would impose its own buffering
// on the very thing we're trying to measure.

import Foundation
import Darwin

final class ImpairmentRelay: @unchecked Sendable {
    let listenPort: UInt16
    let targetPort: UInt16
    let rateBytesPerSec: Double
    let delayMs: Double
    let lossRate: Double

    private var fd: Int32 = -1
    private var thread: Thread?
    private let stopped = NSLock()
    private var shouldStop = false

    // Stats
    private let statLock = NSLock()
    private(set) var forwarded = 0
    private(set) var droppedLoss = 0
    private(set) var droppedQueue = 0

    init(listenPort: UInt16, targetPort: UInt16,
         rateMbit: Double, delayMs: Double, lossRate: Double) {
        self.listenPort = listenPort
        self.targetPort = targetPort
        self.rateBytesPerSec = rateMbit * 1e6 / 8.0
        self.delayMs = delayMs
        self.lossRate = lossRate
    }

    func stats() -> (forwarded: Int, loss: Int, queue: Int) {
        statLock.lock(); defer { statLock.unlock() }
        return (forwarded, droppedLoss, droppedQueue)
    }

    func start() throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw RelayError.socketFailed(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Large socket buffers so the relay itself isn't the bottleneck
        var bufSize: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw RelayError.bindFailed(errno) }

        let t = Thread { [weak self] in self?.pump() }
        t.qualityOfService = .userInteractive
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    func stop() {
        stopped.lock(); shouldStop = true; stopped.unlock()
        if fd >= 0 { close(fd); fd = -1 }
    }

    private struct Pending {
        let data: [UInt8]
        let releaseAt: Double
        let toClient: Bool
    }

    private func pump() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var clientAddr: sockaddr_in?
        var queue: [Pending] = []
        var tokens = rateBytesPerSec * 0.05     // 50ms of burst allowance
        var lastRefill = monotonicSeconds()
        var rng = SystemRandomNumberGenerator()

        // Non-blocking so we can service the delay queue
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = targetPort.bigEndian
        target.sin_addr.s_addr = inet_addr("127.0.0.1")

        while true {
            stopped.lock(); let done = shouldStop; stopped.unlock()
            if done { return }

            // --- receive whatever is available ---
            var src = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &srcLen)
                }
            }

            let now = monotonicSeconds()

            if n > 0 {
                let isFromReceiver = (src.sin_port == target.sin_port)
                if !isFromReceiver { clientAddr = src }

                if Double.random(in: 0..<1, using: &rng) < lossRate {
                    statLock.lock(); droppedLoss += 1; statLock.unlock()
                } else {
                    // Bound the queue — a real bottleneck link drops when full.
                    if queue.count < 2048 {
                        queue.append(Pending(data: Array(buf[0..<n]),
                                             releaseAt: now + delayMs / 1000.0,
                                             toClient: isFromReceiver))
                    } else {
                        statLock.lock(); droppedQueue += 1; statLock.unlock()
                    }
                }
            }

            // --- refill token bucket ---
            let elapsed = now - lastRefill
            lastRefill = now
            tokens = min(tokens + elapsed * rateBytesPerSec, rateBytesPerSec * 0.05)

            // --- release due packets, rate-limited ---
            var i = 0
            while i < queue.count {
                let p = queue[i]
                guard p.releaseAt <= now else { i += 1; continue }
                let cost = Double(p.data.count)
                guard tokens >= cost else { break }   // bucket empty: stall
                tokens -= cost

                var dest: sockaddr_in? = p.toClient ? clientAddr : target
                if var d = dest {
                    _ = withUnsafePointer(to: &d) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            p.data.withUnsafeBufferPointer { bp in
                                sendto(fd, bp.baseAddress, p.data.count, 0,
                                       sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    statLock.lock(); forwarded += 1; statLock.unlock()
                }
                dest = nil
                queue.remove(at: i)
            }

            if n <= 0 && queue.isEmpty { usleep(200) }
        }
    }

    enum RelayError: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
    }
}

func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}
