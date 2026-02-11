import XCTest
@testable import AXTerm

final class ConnectSuggestionEngineTests: XCTestCase {
    func testRouteDerivedOutranksObservedAndNeighborStrong() {
        let now = Date()
        let destination = "K0DST-7"

        let suggestions = ConnectSuggestionEngine.build(
            to: destination,
            mode: .ax25ViaDigi,
            routes: [
                RouteInfo(
                    destination: destination,
                    origin: "DRLAAA",
                    quality: 230,
                    path: ["DRLAAA", "DRLBBB", destination],
                    lastUpdated: now,
                    sourceType: "classic"
                )
            ],
            neighbors: [
                NeighborInfo(call: "NBRAAA", quality: 210, lastSeen: now, sourceType: "classic")
            ],
            observedPaths: [
                ObservedPath(peer: destination, digis: ["OBSAAA"], lastSeen: now, count: 2)
            ],
            attemptHistory: []
        )

        XCTAssertEqual(suggestions.recommendedDigiPaths.first?.source, .routeDerived)
        XCTAssertEqual(suggestions.recommendedDigiPaths.first?.digis, ["DRLAAA", "DRLBBB"])
    }

    func testHistoricalSuccessOutranksObservedAndNeighborStrong() {
        let now = Date()
        let destination = "K0HST-7"

        let suggestions = ConnectSuggestionEngine.build(
            to: destination,
            mode: .ax25ViaDigi,
            routes: [],
            neighbors: [
                NeighborInfo(call: "NBRHIS", quality: 200, lastSeen: now, sourceType: "classic")
            ],
            observedPaths: [
                ObservedPath(peer: destination, digis: ["OBSAAA"], lastSeen: now, count: 1)
            ],
            attemptHistory: [
                ConnectAttemptRecord(
                    to: destination,
                    mode: .ax25ViaDigi,
                    timestamp: now.addingTimeInterval(-120),
                    success: true,
                    digis: ["HSTAAA"],
                    nextHopOverride: nil
                )
            ]
        )

        XCTAssertEqual(suggestions.recommendedDigiPaths.first?.source, .historicalSuccess)
        XCTAssertEqual(suggestions.recommendedDigiPaths.first?.digis, ["HSTAAA"])
    }

    func testDedupesIdenticalPathsWithSSIDNormalization() {
        let now = Date()
        let destination = "K0DUP-7"

        let suggestions = ConnectSuggestionEngine.build(
            to: destination,
            mode: .ax25ViaDigi,
            routes: [],
            neighbors: [],
            observedPaths: [
                ObservedPath(peer: destination, digis: ["W0TX"], lastSeen: now, count: 1)
            ],
            attemptHistory: [
                ConnectAttemptRecord(
                    to: destination,
                    mode: .ax25ViaDigi,
                    timestamp: now,
                    success: true,
                    digis: ["W0TX-0"],
                    nextHopOverride: nil
                )
            ]
        )

        let allPaths = suggestions.recommendedDigiPaths + suggestions.fallbackDigiPaths
        XCTAssertEqual(allPaths.count, 1)
        XCTAssertEqual(allPaths.first?.digis, ["W0TX"])
    }

    func testLimitsRecommendedToFourAndNetRomOptionsToTen() {
        let now = Date()
        let destination = "K0LIM-7"
        let neighbors: [NeighborInfo] = (1...20).map { idx in
            NeighborInfo(call: String(format: "NBR%03d", idx), quality: 200, lastSeen: now, sourceType: "classic")
        }

        let suggestions = ConnectSuggestionEngine.build(
            to: destination,
            mode: .netrom,
            routes: [],
            neighbors: neighbors,
            observedPaths: [],
            attemptHistory: []
        )

        XCTAssertEqual(suggestions.recommendedNextHops.count, 4)
        XCTAssertLessThanOrEqual(suggestions.recommendedNextHops.count + suggestions.fallbackNextHops.count, 10)
    }

    func testRouteDerivedTruncatesToFirstTwoDigis() {
        let destination = "K0TRN-7"
        let now = Date()

        let suggestions = ConnectSuggestionEngine.build(
            to: destination,
            mode: .ax25ViaDigi,
            routes: [
                RouteInfo(
                    destination: destination,
                    origin: "AAA111",
                    quality: 220,
                    path: ["AAA111", "BBB222", "CCC333", "DDD444", destination],
                    lastUpdated: now,
                    sourceType: "classic"
                )
            ],
            neighbors: [],
            observedPaths: [],
            attemptHistory: []
        )

        XCTAssertEqual(suggestions.recommendedDigiPaths.first?.digis, ["AAA111", "BBB222"])
    }
}
