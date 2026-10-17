import Testing
import Foundation
@testable import RMDPProtocol

// MARK: - Control messages

let allMessages: [ControlMessage] = [
    .hello(version: 1, password: "correct horse 🐎", viewerName: "josh-mbp"),
    .welcome(.init(streamWidth: 3024, streamHeight: 1964, displayPointWidth: 1512, displayPointHeight: 982)),
    .reject(reason: "bad password"),
    .keyframeRequest,
    .ping(viewerNanos: 123_456_789),
    .pong(viewerNanos: 1, hostNanos: .max),
    .stats(.init(intervalMillis: 1000, bytesReceived: 2_500_000, framesDecoded: 60, framesLost: 1, smoothedRTTMillis: 114.5)),
    .mouseMove(x: 1512.5, y: 0, viewerNanos: 42),
    .mouseButton(button: 1, down: true, x: 3, y: 4, clickCount: 2, viewerNanos: 7),
    .scroll(dx: -1.5, dy: 120, viewerNanos: 9),
    .key(keyCode: 0x24, down: false, flags: 0x100000, viewerNanos: 11),
]

@Test func everyControlMessageRoundTrips() throws {
    for m in allMessages {
        var f = ControlFramer()
        f.append(m.encoded())
        #expect(try f.next() == m)
        #expect(try f.next() == nil)
    }
}

@Test func framerHandlesArbitraryChunkBoundaries() throws {
    let stream = allMessages.reduce(Data()) { $0 + $1.encoded() }
    // Byte-at-a-time is the worst case a stream can deliver.
    var f = ControlFramer()
    var out: [ControlMessage] = []
    for b in stream {
        f.append(Data([b]))
        while let m = try f.next() { out.append(m) }
    }
    #expect(out == allMessages)
}

@Test func truncatedFrameWaitsForMoreBytes() throws {
    let d = ControlMessage.hello(version: 1, password: "pw", viewerName: "v").encoded()
    for cut in 0..<d.count {
        var f = ControlFramer()
        f.append(d.prefix(cut))
        #expect(try f.next() == nil)
    }
}

@Test func malformedControlInputThrows() {
    // Unknown type.
    var f = ControlFramer(); f.append(Data([0, 0, 0, 1, 0xEE]))
    #expect(throws: WireError.unknownMessageType(0xEE)) { try f.next() }
    // Hostile length.
    var g = ControlFramer(); g.append(Data([0x7F, 0xFF, 0xFF, 0xFF, 1]))
    #expect(throws: WireError.frameTooLarge(0x7FFF_FFFF)) { try g.next() }
    // Zero length.
    var z = ControlFramer(); z.append(Data([0, 0, 0, 0]))
    #expect(throws: WireError.truncated) { try z.next() }
    // Body shorter than its type requires (ping needs 8 bytes).
    var b = ControlFramer(); b.append(Data([0, 0, 0, 3, 5, 0, 0]))
    #expect(throws: WireError.truncated) { try b.next() }
    // String length pointing past the end.
    var s = ControlFramer(); s.append(Data([0, 0, 0, 4, 3, 0, 9, 65]))
    #expect(throws: WireError.truncated) { try s.next() }
}

// MARK: - Video fragmentation

func frame(_ id: UInt32, key: Bool = false, size: Int = 3000) -> EncodedVideoFrame {
    EncodedVideoFrame(frameID: id, isKeyframe: key, captureNanos: UInt64(id) * 16_666_667,
                      parameterSets: key ? [Data([0x67, 1, 2, 3]), Data([0x68, 4])] : [],
                      sampleData: Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &+ Int(id)) }))
}

@Test func fragmentsRespectDatagramSizeAndReassemble() {
    let f = frame(7, key: true, size: 10_000)
    let frags = f.fragments()
    #expect(frags.allSatisfy { $0.count <= RMDPWire.maxDatagramSize })
    #expect(frags.count == 9)
    var r = Reassembler()
    var got: [EncodedVideoFrame] = []
    for d in frags.reversed() {   // order within a frame must not matter
        for case .frame(let x) in r.ingest(d, nowNanos: 0) { got.append(x) }
    }
    #expect(got == [f])
}

@Test func tinyAndEmptyFramesStillFragment() {
    let f = EncodedVideoFrame(frameID: 0, isKeyframe: true, captureNanos: 0, parameterSets: [], sampleData: Data())
    #expect(f.fragments().count == 1)
    var r = Reassembler()
    #expect(r.ingest(f.fragments()[0], nowNanos: 0) == [.frame(f)])
}

@Test func malformedDatagramsAreRejectedNotFatal() {
    var r = Reassembler()
    #expect(r.ingest(Data(), nowNanos: 0).isEmpty)
    #expect(r.ingest(Data([0x12, 0, 0]), nowNanos: 0).isEmpty)                  // truncated
    var bad = frame(0, key: true).fragments()[0]; bad[0] = 0x92                  // wrong version
    #expect(r.ingest(bad, nowNanos: 0).isEmpty)
    var idx = frame(0, key: true).fragments()[0]; idx[6] = 0xFF                  // fragIndex >= fragCount
    #expect(r.ingest(idx, nowNanos: 0).isEmpty)
    #expect(r.datagramsRejected == 4)
}

// MARK: - Loss / keyframe policy

func feed(_ r: inout Reassembler, _ f: EncodedVideoFrame, at t: UInt64 = 0) -> [Reassembler.Event] {
    f.fragments().flatMap { r.ingest($0, nowNanos: t) }
}
func ids(_ ev: [Reassembler.Event]) -> [UInt32] {
    ev.compactMap { if case .frame(let f) = $0 { return f.frameID }; return nil }
}

@Test func startsOnlyAtAKeyframe() {
    var r = Reassembler()
    // Joined mid-GOP: P-frames are useless, and we ask for an IDR (once, rate-limited).
    let e1 = feed(&r, frame(5), at: 0)
    #expect(e1 == [.requestKeyframe])
    #expect(ids(feed(&r, frame(6), at: 1_000_000)).isEmpty)
    #expect(ids(feed(&r, frame(7, key: true), at: 2_000_000)) == [7])
    #expect(ids(feed(&r, frame(8), at: 3_000_000)) == [8])
}

@Test func inOrderStreamFlowsWithNoRequests() {
    var r = Reassembler()
    var all: [Reassembler.Event] = []
    all += feed(&r, frame(0, key: true))
    for i in 1...100 { all += feed(&r, frame(UInt32(i)), at: UInt64(i) * 16_000_000) }
    #expect(ids(all) == Array(0...100))
    #expect(!all.contains(.requestKeyframe))
    #expect(r.framesLost == 0)
}

@Test func smallReorderIsAbsorbed() {
    var r = Reassembler()
    _ = feed(&r, frame(0, key: true))
    var ev = feed(&r, frame(2))          // 1 is late
    #expect(ids(ev).isEmpty)
    ev = feed(&r, frame(1))
    #expect(ids(ev) == [1, 2])
    #expect(r.framesLost == 0)
}

@Test func lostFrameFreezesThenRecoversAtNextIDR() {
    var cfg = ReassemblyConfig(); cfg.maxReorderFrames = 2
    var r = Reassembler(config: cfg)
    _ = feed(&r, frame(0, key: true))
    _ = feed(&r, frame(1))
    // Frame 2 lost entirely. 3 and 4 buffer; 5 exceeds the reorder window → loss.
    #expect(ids(feed(&r, frame(3))).isEmpty)
    #expect(ids(feed(&r, frame(4))).isEmpty)
    let ev = feed(&r, frame(5))
    #expect(ids(ev).isEmpty)
    #expect(ev.contains(.requestKeyframe))
    #expect(r.framesLost == 1 && r.isAwaitingKeyframe)
    // Further P-frames are dropped, not decoded into garbage.
    #expect(ids(feed(&r, frame(6))).isEmpty)
    // IDR arrives → resume there.
    #expect(ids(feed(&r, frame(7, key: true))) == [7])
    #expect(ids(feed(&r, frame(8))) == [8])
}

@Test func partialFrameTimesOut() {
    var r = Reassembler()
    _ = feed(&r, frame(0, key: true), at: 0)
    let frags = frame(1, size: 5000).fragments()
    for d in frags.dropLast() { _ = r.ingest(d, nowNanos: 1_000_000) }      // last fragment lost
    #expect(r.poll(nowNanos: 40_000_000).isEmpty)                            // inside timeout
    #expect(r.poll(nowNanos: 60_000_000) == [.requestKeyframe])              // past 50ms
    #expect(r.framesLost == 1)
}

@Test func keyframeRequestsAreRateLimitedWhileWaiting() {
    var r = Reassembler()
    // Startup: give the host's opening IDR one interval to arrive before asking.
    #expect(r.poll(nowNanos: 0).isEmpty)
    #expect(r.poll(nowNanos: 100_000_000).isEmpty)
    #expect(r.poll(nowNanos: 260_000_000) == [.requestKeyframe])
    #expect(r.poll(nowNanos: 400_000_000).isEmpty)
    #expect(r.poll(nowNanos: 520_000_000) == [.requestKeyframe])
}

@Test func lossWithKeyframeAlreadyBufferedRecoversImmediately() {
    var r = Reassembler()
    _ = feed(&r, frame(0, key: true))
    _ = feed(&r, frame(2))
    _ = feed(&r, frame(3, key: true))
    let ev = feed(&r, frame(4))          // 3 newer than missing 1 → loss; IDR 3 is ready
    #expect(ids(ev) == [3, 4])
    #expect(!ev.contains(.requestKeyframe))
}

@Test func frameIDsWrapSafely() {
    var r = Reassembler()
    var got: [UInt32] = []
    got += ids(feed(&r, frame(UInt32.max - 1, key: true)))
    got += ids(feed(&r, frame(UInt32.max)))
    got += ids(feed(&r, frame(0)))
    got += ids(feed(&r, frame(1)))
    #expect(got == [UInt32.max - 1, UInt32.max, 0, 1])
}
