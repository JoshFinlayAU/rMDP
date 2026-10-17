import Foundation

/// A computed summary of a batch of latency samples (all values in milliseconds).
public struct LatencySummary: Sendable, CustomStringConvertible {
    public let count: Int
    public let mean: Double
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let min: Double
    public let max: Double

    public var description: String {
        guard count > 0 else { return "no samples" }
        return String(format: "n=%d  mean=%.2f  p50=%.2f  p95=%.2f  p99=%.2f  min=%.2f  max=%.2f ms",
                      count, mean, p50, p95, p99, min, max)
    }
}

/// Fixed-capacity, single-producer latency recorder.
///
/// Recording is a bounds-checked array write with no allocation, no logging, and no
/// lock — safe to call from a frame/decode callback per the hot-path rules. The
/// backing store is preallocated; once full it wraps (a ring), so long runs keep the
/// most recent `capacity` samples. `summarize()` is called off-thread after the run.
///
/// Single-producer only: one thread records, and `summarize()` must not race a
/// concurrent `record`. In the harness the decode callback is the sole producer and
/// summarize runs after draining.
public final class LatencyRecorder: @unchecked Sendable {
    private var buffer: [Double]
    private var writeIndex = 0
    private var total = 0
    public let capacity: Int

    public init(capacity: Int = 100_000) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.buffer = [Double](repeating: 0, count: capacity)
    }

    /// Record one sample in milliseconds. O(1), no allocation.
    public func record(_ millis: Double) {
        buffer[writeIndex] = millis
        writeIndex += 1
        if writeIndex == capacity { writeIndex = 0 }
        total += 1
    }

    /// Number of samples recorded (may exceed capacity; only the last `capacity` are kept).
    public var recordedCount: Int { total }

    public func summarize() -> LatencySummary {
        let n = Swift.min(total, capacity)
        guard n > 0 else {
            return LatencySummary(count: 0, mean: 0, p50: 0, p95: 0, p99: 0, min: 0, max: 0)
        }
        let sorted = Array(buffer[0..<n]).sorted()
        let sum = sorted.reduce(0, +)
        return LatencySummary(
            count: n,
            mean: sum / Double(n),
            p50: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99),
            min: sorted.first!,
            max: sorted.last!
        )
    }

    /// Nearest-rank percentile on an already-sorted array.
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let rank = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[rank]
    }
}
