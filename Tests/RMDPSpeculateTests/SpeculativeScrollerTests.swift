import Testing
@testable import RMDPSpeculate

private let W = 64, H = 48

@Test func interiorOfATrueScrollIsExact() {
    let doc = ScrollDoc(width: W)
    var scroller = SpeculativeScroller(width: W, height: H)
    let before = doc.viewport(offsetY: 1000, height: H)
    let dy = 8
    let shifted = scroller.shift(before, dy: dy)
    let authoritative = doc.viewport(offsetY: 1000 + dy, height: H)   // host truth after scroll
    let r = scroller.reconcile(speculative: shifted.frame, authoritative: authoritative,
                               unknownRows: shifted.unknownRows)
    #expect(r.interiorMatch == 1.0)   // interior of a pure content scroll is pixel-exact
    #expect(r.correct)
    #expect(r.confident)
}

@Test func revealedEdgeIsTheUnknownBand() {
    var scroller = SpeculativeScroller(width: W, height: H)
    let doc = ScrollDoc(width: W)
    let s = scroller.shift(doc.viewport(offsetY: 0, height: H), dy: 8)
    #expect(s.unknownRows == (H - 8)..<H)      // scroll down reveals the bottom 8 rows
    let up = scroller.shift(doc.viewport(offsetY: 100, height: H), dy: -5)
    #expect(up.unknownRows == 0..<5)           // scroll up reveals the top 5 rows
}

@Test func contentChangeIsDetectedAndBreaksConfidence() {
    let doc = ScrollDoc(width: W)
    var scroller = SpeculativeScroller(width: W, height: H)
    // establish confidence with a real scroll
    let base = doc.viewport(offsetY: 500, height: H)
    let s1 = scroller.shift(base, dy: 6)
    _ = scroller.reconcile(speculative: s1.frame,
                           authoritative: doc.viewport(offsetY: 506, height: H),
                           unknownRows: s1.unknownRows)
    #expect(scroller.confident)
    let epochBefore = scroller.epoch

    // now the "scroll" wasn't a scroll — host returns unrelated content
    let s2 = scroller.shift(doc.viewport(offsetY: 506, height: H), dy: 6)
    let r = scroller.reconcile(speculative: s2.frame,
                               authoritative: doc.scrambled(seed: 7, height: H),
                               unknownRows: s2.unknownRows)
    #expect(!r.correct)
    #expect(!scroller.confident)              // confidence dropped → stop showing speculation
    #expect(scroller.epoch == epochBefore + 1) // epoch incremented
}

@Test func compoundedScrollsStayExactInInterior() {
    // A fast flick = many deltas before the first host frame returns. Compounded shifts must
    // keep the interior exact.
    let doc = ScrollDoc(width: W)
    var scroller = SpeculativeScroller(width: W, height: H)
    var offset = 2000
    var frame = doc.viewport(offsetY: offset, height: H)
    let dy = 4
    for _ in 0..<10 {
        let s = scroller.shift(frame, dy: dy)
        offset += dy
        let auth = doc.viewport(offsetY: offset, height: H)
        let r = scroller.reconcile(speculative: s.frame, authoritative: auth,
                                   unknownRows: s.unknownRows)
        #expect(r.interiorMatch == 1.0)
        frame = auth      // adopt truth, continue the flick
    }
}
