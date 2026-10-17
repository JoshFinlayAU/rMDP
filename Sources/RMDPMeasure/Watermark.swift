import Foundation

/// In-band latency watermark: encodes a 64-bit value (a capture-time monotonic
/// timestamp, or a frame ID) into the luma plane of a frame as a strip of large
/// high-contrast blocks, and reads it back after the frame has been through capture,
/// codec, transport, decode, and render.
///
/// Why luma blocks: H.264/HEVC keep the luma plane at full resolution even in 4:2:0,
/// and blocks far larger than a macroblock survive lossy quantisation. This is the
/// black-box way to measure *true* end-to-end latency — it captures encode, decode,
/// and (when detected off a real display) capture+scanout latency that a timestamp
/// merely attached to a buffer would miss.
///
/// Layout: a horizontal strip of `cellW × cellH` cells at (originX, originY).
///   cells 0..7   : preamble 0xAC (1010 1100) — presence check + black/white calibration
///   cells 8..71  : 64-bit payload, MSB first
/// A bit is a solid cell: `levelHigh` for 1, `levelLow` for 0. Detection samples a
/// small region at each cell centre, calibrates the threshold from the preamble's
/// known bits, validates the preamble, then reads the payload. A frame with no valid
/// preamble (idle/blank/garbage) returns nil rather than a wrong number.
public struct WatermarkCodec: Sendable {
    public let cellW: Int
    public let cellH: Int
    public let originX: Int
    public let originY: Int
    public let levelLow: UInt8
    public let levelHigh: UInt8

    static let preamble: UInt8 = 0xAC          // 1010 1100
    static let preambleBits = 8
    static let payloadBits = 64
    static var totalCells: Int { preambleBits + payloadBits }   // 72

    /// Video-range-safe defaults (16/235-ish) so limited-range 4:2:0 doesn't clip the
    /// extremes and blur the threshold. 16×16 cells clear a macroblock comfortably.
    public init(cellW: Int = 16, cellH: Int = 16,
                originX: Int = 0, originY: Int = 0,
                levelLow: UInt8 = 40, levelHigh: UInt8 = 215) {
        self.cellW = cellW
        self.cellH = cellH
        self.originX = originX
        self.originY = originY
        self.levelLow = levelLow
        self.levelHigh = levelHigh
    }

    /// Total pixel width the strip occupies — callers should ensure the frame is at
    /// least this wide (and `originY + cellH` tall).
    public var requiredWidth: Int { originX + Self.totalCells * cellW }
    public var requiredHeight: Int { originY + cellH }

    // MARK: - Embed

    /// Write `value` into the luma plane. `luma` points at row 0; rows are
    /// `bytesPerRow` apart (may exceed `width` for alignment padding).
    public func embed(_ value: UInt64,
                      luma: UnsafeMutablePointer<UInt8>,
                      width: Int, height: Int, bytesPerRow: Int) {
        guard requiredWidth <= width, requiredHeight <= height else { return }

        // Build the 72-bit cell stream: preamble then payload MSB-first.
        for cell in 0..<Self.totalCells {
            let bit: Bool
            if cell < Self.preambleBits {
                bit = (Self.preamble >> (Self.preambleBits - 1 - cell)) & 1 == 1
            } else {
                let p = cell - Self.preambleBits
                bit = (value >> (Self.payloadBits - 1 - p)) & 1 == 1
            }
            fill(cell: cell, level: bit ? levelHigh : levelLow,
                 luma: luma, bytesPerRow: bytesPerRow)
        }
    }

    private func fill(cell: Int, level: UInt8,
                      luma: UnsafeMutablePointer<UInt8>, bytesPerRow: Int) {
        let x0 = originX + cell * cellW
        for dy in 0..<cellH {
            let row = luma + (originY + dy) * bytesPerRow + x0
            row.update(repeating: level, count: cellW)
        }
    }

    // MARK: - Extract

    /// Read a value back, or nil if no valid watermark is present.
    public func extract(luma: UnsafePointer<UInt8>,
                        width: Int, height: Int, bytesPerRow: Int) -> UInt64? {
        guard requiredWidth <= width, requiredHeight <= height else { return nil }

        // Sample every cell's centre region first.
        var samples = [Double](repeating: 0, count: Self.totalCells)
        for cell in 0..<Self.totalCells {
            samples[cell] = sampleCell(cell, luma: luma, bytesPerRow: bytesPerRow)
        }

        // Calibrate hi/lo from the known preamble bits (0xAC = 1,0,1,0,1,1,0,0).
        var hiSum = 0.0, hiN = 0, loSum = 0.0, loN = 0
        for cell in 0..<Self.preambleBits {
            let bit = (Self.preamble >> (Self.preambleBits - 1 - cell)) & 1 == 1
            if bit { hiSum += samples[cell]; hiN += 1 }
            else { loSum += samples[cell]; loN += 1 }
        }
        guard hiN > 0, loN > 0 else { return nil }
        let hi = hiSum / Double(hiN)
        let lo = loSum / Double(loN)
        // Reject if there's no real separation (blank/uniform frame).
        guard hi - lo >= 24.0 else { return nil }
        let threshold = (hi + lo) / 2.0

        // Validate the whole preamble decodes correctly — guards against locking onto
        // arbitrary content that happens to have a bright top-left corner.
        var decodedPreamble: UInt8 = 0
        for cell in 0..<Self.preambleBits {
            decodedPreamble <<= 1
            if samples[cell] > threshold { decodedPreamble |= 1 }
        }
        guard decodedPreamble == Self.preamble else { return nil }

        // Read the payload.
        var value: UInt64 = 0
        for cell in Self.preambleBits..<Self.totalCells {
            value <<= 1
            if samples[cell] > threshold { value |= 1 }
        }
        return value
    }

    /// Average luma over a small window at the cell centre — robust to codec ringing
    /// at cell edges without needing the whole cell.
    private func sampleCell(_ cell: Int,
                            luma: UnsafePointer<UInt8>, bytesPerRow: Int) -> Double {
        let cx = originX + cell * cellW + cellW / 2
        let cy = originY + cellH / 2
        let half = Swift.max(1, Swift.min(cellW, cellH) / 4)   // sample ~half the cell
        var sum = 0, n = 0
        for dy in -half...half {
            let row = luma + (cy + dy) * bytesPerRow
            for dx in -half...half {
                sum += Int(row[cx + dx]); n += 1
            }
        }
        return Double(sum) / Double(n)
    }
}
