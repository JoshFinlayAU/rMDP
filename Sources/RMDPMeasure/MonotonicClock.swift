import Foundation

/// A single monotonic time source, in nanoseconds, shared across the pipeline so
/// capture→render latency is measured against one clock rather than guessed.
///
/// Backed by `DispatchTime.now().uptimeNanoseconds`, which is `mach_absolute_time`
/// scaled to ns — monotonic, unaffected by wall-clock changes, and cheap enough to
/// call in a frame callback.
public enum MonotonicClock {
    @inlinable
    public static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Milliseconds between two `nowNanos()` readings, as a Double.
    @inlinable
    public static func millis(from start: UInt64, to end: UInt64) -> Double {
        Double(end &- start) / 1_000_000.0
    }
}
