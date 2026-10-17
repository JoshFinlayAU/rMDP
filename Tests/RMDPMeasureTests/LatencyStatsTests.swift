import Testing
@testable import RMDPMeasure

@Test func percentilesOnKnownDistribution() {
    let r = LatencyRecorder(capacity: 1000)
    for i in 1...100 { r.record(Double(i)) }   // 1..100
    let s = r.summarize()
    #expect(s.count == 100)
    #expect(s.min == 1)
    #expect(s.max == 100)
    #expect(abs(s.mean - 50.5) < 0.001)
    // nearest-rank: p50 -> index round(99*0.5)=50 -> value 51; p95 -> index 94 -> 95; p99 -> 98 -> 99
    #expect(s.p50 == 51)
    #expect(s.p95 == 95)
    #expect(s.p99 == 99)
}

@Test func emptyRecorderIsSafe() {
    let s = LatencyRecorder(capacity: 10).summarize()
    #expect(s.count == 0)
}

@Test func ringWrapsKeepingRecentSamples() {
    let r = LatencyRecorder(capacity: 100)
    for i in 1...250 { r.record(Double(i)) }    // last 100 kept are 151..250
    let s = r.summarize()
    #expect(s.recordedCountMatches(r, expected: 250))
    #expect(s.count == 100)
    #expect(s.min == 151)
    #expect(s.max == 250)
}

private extension LatencySummary {
    func recordedCountMatches(_ r: LatencyRecorder, expected: Int) -> Bool {
        r.recordedCount == expected
    }
}
