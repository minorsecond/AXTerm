import XCTest
@testable import AXTerm

final class ConnectAttemptPlannerTests: XCTestCase {
    func testAX25AutoPlanHasMaxThreeSteps() {
        let suggestions = ConnectSuggestions(
            recommendedDigiPaths: [
                .init(digis: ["A1AAA"], score: 1.0, source: .routeDerived),
                .init(digis: ["B1BBB"], score: 0.9, source: .historicalSuccess),
                .init(digis: ["C1CCC"], score: 0.8, source: .observedForDestination),
                .init(digis: ["D1DDD"], score: 0.7, source: .neighborStrong)
            ],
            fallbackDigiPaths: [],
            recommendedNextHops: [],
            fallbackNextHops: []
        )

        let plan = ConnectAttemptPlanner.plan(mode: .ax25ViaDigi, suggestions: suggestions)
        XCTAssertEqual(plan.steps.count, 3)
    }

    func testAX25AutoPlanSkipsCandidatesWithMoreThanTwoDigis() {
        let suggestions = ConnectSuggestions(
            recommendedDigiPaths: [
                .init(digis: ["A1AAA", "B1BBB", "C1CCC"], score: 1.0, source: .routeDerived),
                .init(digis: ["D1DDD"], score: 0.9, source: .historicalSuccess),
                .init(digis: ["E1EEE", "F1FFF"], score: 0.8, source: .observedForDestination)
            ],
            fallbackDigiPaths: [],
            recommendedNextHops: [],
            fallbackNextHops: []
        )

        let plan = ConnectAttemptPlanner.plan(mode: .ax25ViaDigi, suggestions: suggestions)
        XCTAssertEqual(plan.steps, [
            .ax25ViaDigis(digis: ["D1DDD"]),
            .ax25ViaDigis(digis: ["E1EEE", "F1FFF"])
        ])
    }

    func testNETROMAutoPlanStartsWithNilOverride() {
        let suggestions = ConnectSuggestions(
            recommendedDigiPaths: [],
            fallbackDigiPaths: [],
            recommendedNextHops: [
                .init(callsign: "R1AAA", score: 1.0, source: .routePreferred),
                .init(callsign: "H1BBB", score: 0.9, source: .historicalSuccess),
                .init(callsign: "N1CCC", score: 0.8, source: .neighborStrong)
            ],
            fallbackNextHops: []
        )

        let plan = ConnectAttemptPlanner.plan(mode: .netrom, suggestions: suggestions)
        XCTAssertEqual(plan.steps.first, .netrom(nextHopOverride: nil))
    }

    func testNETROMAutoPlanHasMaxThreeSteps() {
        let suggestions = ConnectSuggestions(
            recommendedDigiPaths: [],
            fallbackDigiPaths: [],
            recommendedNextHops: [
                .init(callsign: "R1AAA", score: 1.0, source: .routePreferred),
                .init(callsign: "H1BBB", score: 0.9, source: .historicalSuccess),
                .init(callsign: "N1CCC", score: 0.8, source: .neighborStrong),
                .init(callsign: "X1DDD", score: 0.7, source: .neighborStrong)
            ],
            fallbackNextHops: []
        )

        let plan = ConnectAttemptPlanner.plan(mode: .netrom, suggestions: suggestions)
        XCTAssertEqual(plan.steps.count, 3)
        XCTAssertEqual(plan.steps, [
            .netrom(nextHopOverride: nil),
            .netrom(nextHopOverride: "H1BBB"),
            .netrom(nextHopOverride: "N1CCC")
        ])
    }
}
