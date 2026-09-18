import XCTest
@testable import AXTerm

/// Weighing a path change against what the channel is actually doing.
///
/// The rule on its own ("fixed stations use one hop") is wrong often enough to
/// be worth measuring around: it does not know how many digipeaters can hear
/// this station, and it does not know whether anyone would notice the extra
/// copies.
final class APRSPathRecommendationTests: XCTestCase {

    private func advice(direct: [String], viaExtraHop: [String] = [],
                        frames: Int = 24, requested: Int = 2) -> APRSPathAdvice {
        var hops: [String: Set<Int>] = [:]
        for call in direct { hops[call] = [0] }
        for call in viaExtraHop { hops[call] = [1] }
        return APRSPathAdvice.from(repeatHops: hops, framesObserved: frames,
                                   hopsRequested: requested)
    }

    /// `frames` follows the occupancy claimed, because the key-up allowance is
    /// per frame: a fixture claiming 1% of the air from 300 frames describes a
    /// channel that cannot exist.
    private func load(occupancy: Double, duplicates: Double = 0.1) -> APRSChannelLoad {
        let frames = max(1, Int(occupancy * 900 / 0.35))
        return APRSChannelLoad(window: 900, frames: frames,
                               framesPerMinute: Double(frames) / 15,
                               occupancy: occupancy, duplicateShare: duplicates, baud: 1200)
    }

    // MARK: - When it suggests a change

    func testSpareCoverageOnABusyChannelIsWorthShortening() {
        let result = APRSPathRecommendation.decide(
            advice: advice(direct: ["AD1CT", "WQ8M-9", "W0NED", "K5RHD-10"]),
            load: load(occupancy: 0.18))

        XCTAssertEqual(result.verdict, .considerShortening(toHops: 1))
        XCTAssertTrue(result.isActionable)
    }

    /// The claim is still bounded by what came back, and saying so is part of
    /// the recommendation rather than a footnote somewhere else.
    func testTheSuggestionCarriesItsOwnCaveat() {
        let result = APRSPathRecommendation.decide(
            advice: advice(direct: ["AD1CT", "WQ8M-9", "W0NED"]),
            load: load(occupancy: 0.18))

        XCTAssertTrue(result.reasons.contains { $0.contains("receive range") })
    }

    // MARK: - When it leaves well alone

    func testAQuietChannelIsNoReasonToChangeAnything() {
        let result = APRSPathRecommendation.decide(
            advice: advice(direct: ["AD1CT", "WQ8M-9", "W0NED", "K5RHD-10"]),
            load: load(occupancy: 0.01))

        XCTAssertEqual(result.verdict, .keep)
        XCTAssertTrue(result.reasons.contains { $0.contains("quiet enough") })
    }

    func testThinCoverageKeepsTheSpareHopAsInsurance() {
        let result = APRSPathRecommendation.decide(
            advice: advice(direct: ["AD1CT", "WQ8M-9"]),
            load: load(occupancy: 0.30))

        XCTAssertEqual(result.verdict, .keep,
                       "two digipeaters is one power cut away from one")
        XCTAssertTrue(result.reasons.contains { $0.contains("insurance") })
    }

    /// Nothing outweighs the hop demonstrably doing work.
    func testAHopThatReachesSomethingIsKeptHoweverBusyTheChannel() {
        let result = APRSPathRecommendation.decide(
            advice: advice(direct: ["AD1CT", "WQ8M-9", "W0NED"], viaExtraHop: ["RATON"]),
            load: load(occupancy: 0.40, duplicates: 0.60))

        XCTAssertEqual(result.verdict, .keep)
        XCTAssertTrue(result.reasons.contains { $0.contains("RATON") })
    }

    func testAPathThatAlreadyFitsIsLeftAlone() {
        let result = APRSPathRecommendation.decide(
            advice: advice(direct: ["AD1CT", "WQ8M-9", "W0NED"], requested: 1),
            load: load(occupancy: 0.30))

        XCTAssertEqual(result.verdict, .keep)
    }

    // MARK: - Echo

    /// A channel can be light on airtime and still be mostly the network
    /// talking to itself, which is the same argument by a different route.
    func testAnEchoHeavyChannelCountsEvenWhenAirtimeIsLow() {
        let result = APRSPathRecommendation.decide(
            advice: advice(direct: ["AD1CT", "WQ8M-9", "W0NED"]),
            load: load(occupancy: 0.04, duplicates: 0.55))

        XCTAssertEqual(result.verdict, .considerShortening(toHops: 1))
        XCTAssertTrue(result.reasons.contains { $0.contains("repeating") })
    }

    // MARK: - Evidence

    func testThinEvidenceRecommendsNothing() {
        let result = APRSPathRecommendation.decide(
            advice: advice(direct: ["AD1CT"], frames: 4),
            load: load(occupancy: 0.30))

        XCTAssertEqual(result.verdict, .notEnough)
        XCTAssertFalse(result.isActionable)
    }
}
