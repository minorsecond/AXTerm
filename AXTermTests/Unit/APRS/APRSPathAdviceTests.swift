import XCTest
@testable import AXTerm

/// Judging whether a beacon path is longer than the network needs.
///
/// The asymmetry these tests defend: shortening is safe to advise from frames
/// that came back, lengthening is not. A digipeater that has never answered
/// looks identical whether it is out of range or switched off, and a longer
/// path would be recommended on the strength of having heard nothing.
final class APRSPathAdviceTests: XCTestCase {

    // MARK: - Counting what a path asks for

    func testHopsAreCountedFromWhatIsLeftToUse() {
        XCTAssertEqual(APRSPathAdvice.hopsRequested(in: ["WIDE1-1", "WIDE2-1"]), 2)
        XCTAssertEqual(APRSPathAdvice.hopsRequested(in: ["WIDE2-2"]), 2)
        XCTAssertEqual(APRSPathAdvice.hopsRequested(in: ["WIDE1-1"]), 1)
        XCTAssertEqual(APRSPathAdvice.hopsRequested(in: []), 0)
    }

    func testANamedDigipeaterIsOneHop() {
        XCTAssertEqual(APRSPathAdvice.hopsRequested(in: ["AD1CT"]), 1)
    }

    /// An entry marked used belongs to a frame's history rather than to a
    /// request, and counting it would inflate what the operator is asking for.
    func testAnAlreadyUsedHopIsNotARequest() {
        XCTAssertEqual(APRSPathAdvice.hopsRequested(in: ["AD1CT*", "WIDE1*", "WIDE2-1"]), 1)
    }

    // MARK: - The judgment

    /// The real shape of K0EPI-5's traffic: four digipeaters, all of which
    /// hear the station directly, and a path asking for two hops.
    func testAPathIsOverProvisionedWhenNothingNeedsTheExtraHop() {
        let advice = APRSPathAdvice.from(
            repeatHops: ["AD1CT": [0], "WQ8M-9": [0], "W0NED": [0, 1], "K5RHD-10": [0]],
            framesObserved: 24,
            hopsRequested: 2)

        XCTAssertTrue(advice.isOverProvisioned)
        XCTAssertEqual(advice.hopsNeeded, 1)
        XCTAssertTrue(advice.reachedOnlyByExtraHops.isEmpty,
                      "W0NED takes the second hop sometimes but hears the station anyway")
    }

    func testAPathIsKeptWhenSomethingIsOnlyReachableThroughIt() {
        let advice = APRSPathAdvice.from(
            repeatHops: ["AD1CT": [0], "W0NED": [1]],
            framesObserved: 24,
            hopsRequested: 2)

        XCTAssertFalse(advice.isOverProvisioned)
        XCTAssertEqual(advice.hopsNeeded, 2)
        XCTAssertEqual(advice.reachedOnlyByExtraHops.map(\.callsign), ["W0NED"])
    }

    func testAPathThatAlreadyMatchesIsLeftAlone() {
        let advice = APRSPathAdvice.from(
            repeatHops: ["AD1CT": [0], "WQ8M-9": [0]],
            framesObserved: 24,
            hopsRequested: 1)

        XCTAssertFalse(advice.isOverProvisioned)
        XCTAssertEqual(advice.hopsNeeded, 1)
    }

    /// Never the other way. Hearing nothing back through a second hop is what
    /// a station with no second-hop neighbours looks like, and also what a
    /// station whose neighbours are all switched off looks like.
    func testAShortPathIsNeverRecommendedToGrow() {
        let advice = APRSPathAdvice.from(
            repeatHops: ["AD1CT": [0]],
            framesObserved: 40,
            hopsRequested: 1)

        XCTAssertFalse(advice.isOverProvisioned)
        XCTAssertLessThanOrEqual(advice.hopsNeeded, advice.hopsRequested)
    }

    // MARK: - Evidence

    func testThinEvidenceJudgesNothing() {
        let advice = APRSPathAdvice.from(
            repeatHops: ["AD1CT": [0]],
            framesObserved: 3,
            hopsRequested: 2)

        XCTAssertFalse(advice.hasEnoughEvidence)
        XCTAssertFalse(advice.isOverProvisioned, "three frames is a hint, not a finding")
        XCTAssertTrue(advice.detail.contains("3 of your frames"))
    }

    func testAChannelThatHasNeverRepeatedUsSaysSoRatherThanAdvising() {
        let advice = APRSPathAdvice.from(
            repeatHops: [:], framesObserved: 40, hopsRequested: 2)

        XCTAssertFalse(advice.isOverProvisioned)
        XCTAssertEqual(advice.hopsNeeded, 0)
        XCTAssertTrue(advice.headline.contains("nothing to judge"))
    }

    // MARK: - Presentation

    func testDigipeatersAreListedNearestFirstAndStably() {
        let advice = APRSPathAdvice.from(
            repeatHops: ["ZZTOP": [0], "AD1CT": [0], "W0NED": [1]],
            framesObserved: 24,
            hopsRequested: 2)

        XCTAssertEqual(advice.digipeaters.map(\.callsign), ["AD1CT", "ZZTOP", "W0NED"])
    }

    func testTheHeadlineSaysWhatItWouldSave() {
        let advice = APRSPathAdvice.from(
            repeatHops: ["AD1CT": [0]], framesObserved: 24, hopsRequested: 2)

        XCTAssertTrue(advice.headline.contains("2 hops"))
        XCTAssertTrue(advice.headline.contains("1 would reach every digipeater you can hear"))
    }

    /// The claim has to stay inside what the method can see. Frames coming
    /// back only ever cover our own receive range, so a digipeater beyond it
    /// using the extra hop is invisible and must not be claimed away.
    func testTheAdviceDoesNotClaimTheExtraHopReachesNobody() {
        let advice = APRSPathAdvice.from(
            repeatHops: ["AD1CT": [0]], framesObserved: 24, hopsRequested: 2)

        XCTAssertFalse(advice.headline.contains("the same stations"))
        XCTAssertTrue(advice.detail.contains("receive range"))
    }
}
