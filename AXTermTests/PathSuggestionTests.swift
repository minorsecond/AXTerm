//
//  PathSuggestionTests.swift
//  AXTermTests
//
//  TDD tests for path suggestions based on ETX/ETT scoring.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 5.1, 8.1
//

import XCTest
@testable import AXTerm

final class PathSuggestionTests: XCTestCase {

    // MARK: - Path Score Calculation

    func testPathScoreBasicCalculation() {
        let score = PathScore(
            etx: 1.5,
            ett: 2.0,
            hops: 2,
            freshness: 0.9
        )

        XCTAssertEqual(score.etx, 1.5, accuracy: 0.01)
        XCTAssertEqual(score.ett, 2.0, accuracy: 0.01)
        XCTAssertEqual(score.hops, 2)
        XCTAssertEqual(score.freshness, 0.9, accuracy: 0.01)
    }

    func testPathScoreCompositeScore() {
        let score = PathScore(
            etx: 1.0,  // Perfect
            ett: 1.0,
            hops: 1,
            freshness: 1.0
        )

        // Perfect score should be low (good)
        XCTAssertLessThan(score.compositeScore, 2.0)

        let poorScore = PathScore(
            etx: 5.0,  // Poor
            ett: 10.0,
            hops: 4,
            freshness: 0.5
        )

        // Poor score should be high (bad)
        XCTAssertGreaterThan(poorScore.compositeScore, score.compositeScore)
    }

    func testPathScoreHopPenalty() {
        let oneHop = PathScore(etx: 1.0, ett: 1.0, hops: 1, freshness: 1.0)
        let threeHops = PathScore(etx: 1.0, ett: 1.0, hops: 3, freshness: 1.0)

        // More hops should have higher (worse) score
        XCTAssertLessThan(oneHop.compositeScore, threeHops.compositeScore)
    }

    func testPathScoreFreshnessPenalty() {
        let fresh = PathScore(etx: 1.0, ett: 1.0, hops: 1, freshness: 1.0)
        let stale = PathScore(etx: 1.0, ett: 1.0, hops: 1, freshness: 0.3)

        // Stale path should have higher (worse) score
        XCTAssertLessThan(fresh.compositeScore, stale.compositeScore)
    }

    // MARK: - Path Suggestion Tests

    func testPathSuggestionInitialization() {
        let path = DigiPath.from(["WIDE1-1", "WIDE2-1"])
        let suggestion = PathSuggestion(
            path: path,
            score: PathScore(etx: 1.3, ett: 1.8, hops: 2, freshness: 0.92),
            reason: "Best ETT (1.8s), 2 hops, fresh 92%"
        )

        XCTAssertEqual(suggestion.path.count, 2)
        XCTAssertEqual(suggestion.reason, "Best ETT (1.8s), 2 hops, fresh 92%")
    }

    func testPathSuggestionComparison() {
        let better = PathSuggestion(
            path: DigiPath(),
            score: PathScore(etx: 1.0, ett: 1.0, hops: 0, freshness: 1.0),
            reason: "Direct"
        )

        let worse = PathSuggestion(
            path: DigiPath.from(["WIDE1-1", "WIDE2-1"]),
            score: PathScore(etx: 2.0, ett: 3.0, hops: 2, freshness: 0.8),
            reason: "Via digis"
        )

        XCTAssertLessThan(better.score.compositeScore, worse.score.compositeScore)
    }

    // MARK: - Path Suggester Tests

    func testPathSuggesterReturnsDirectFirst() {
        var suggester = PathSuggester()

        // Record direct contact
        suggester.recordSuccess(
            destination: "N0CALL",
            path: DigiPath(),
            rtt: 1.0
        )

        let suggestions = suggester.suggest(for: "N0CALL", maxSuggestions: 3)

        XCTAssertFalse(suggestions.isEmpty)
        // Direct path should be first
        XCTAssertEqual(suggestions.first?.path.count, 0)
    }

    func testPathSuggesterTracksPaths() {
        var suggester = PathSuggester()

        // Record path via digis
        suggester.recordSuccess(
            destination: "K0EPI",
            path: DigiPath.from(["WIDE1-1"]),
            rtt: 2.5
        )

        let suggestions = suggester.suggest(for: "K0EPI", maxSuggestions: 3)

        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertEqual(suggestions.first?.path.count, 1)
    }

    func testPathSuggesterRecordsFailures() {
        var suggester = PathSuggester()

        // Record some successes
        for _ in 0..<5 {
            suggester.recordSuccess(
                destination: "N0CALL",
                path: DigiPath.from(["WIDE1-1"]),
                rtt: 2.0
            )
        }

        // Record failures
        for _ in 0..<3 {
            suggester.recordFailure(
                destination: "N0CALL",
                path: DigiPath.from(["WIDE1-1"])
            )
        }

        let suggestions = suggester.suggest(for: "N0CALL", maxSuggestions: 3)

        // Should still have suggestion but with worse score
        XCTAssertFalse(suggestions.isEmpty)
        // ETX should be higher due to failures
        XCTAssertGreaterThan(suggestions.first?.score.etx ?? 0, 1.0)
    }

    func testPathSuggesterLimitsSuggestions() {
        var suggester = PathSuggester()

        // Record multiple paths
        suggester.recordSuccess(destination: "N0CALL", path: DigiPath(), rtt: 1.0)
        suggester.recordSuccess(destination: "N0CALL", path: DigiPath.from(["WIDE1-1"]), rtt: 2.0)
        suggester.recordSuccess(destination: "N0CALL", path: DigiPath.from(["WIDE1-1", "WIDE2-1"]), rtt: 3.0)
        suggester.recordSuccess(destination: "N0CALL", path: DigiPath.from(["LOCAL"]), rtt: 1.5)

        let suggestions = suggester.suggest(for: "N0CALL", maxSuggestions: 2)

        XCTAssertEqual(suggestions.count, 2)
    }

    func testPathSuggesterReturnsEmptyForUnknown() {
        let suggester = PathSuggester()

        let suggestions = suggester.suggest(for: "UNKNOWN", maxSuggestions: 3)

        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: - Path Mode Tests

    func testPathModeDefault() {
        let mode = PathMode.suggested
        XCTAssertEqual(mode, .suggested)
    }

    func testPathModeManualLocked() {
        var settings = DestinationPathSettings(destination: "N0CALL")
        settings.mode = .manual
        settings.lockedPath = DigiPath.from(["WIDE1-1"])

        XCTAssertEqual(settings.mode, .manual)
        XCTAssertEqual(settings.lockedPath?.count, 1)
    }

    func testPathModeSuggested() {
        var settings = DestinationPathSettings(destination: "N0CALL")
        settings.mode = .suggested

        // In suggested mode, path is not locked
        XCTAssertNil(settings.lockedPath)
    }

    // MARK: - Recent Paths Tests

    func testRecentPathsTracking() {
        var suggester = PathSuggester()

        // Use the same path multiple times
        for _ in 0..<3 {
            suggester.recordSuccess(
                destination: "N0CALL",
                path: DigiPath.from(["WIDE1-1"]),
                rtt: 2.0
            )
        }

        let recent = suggester.recentPaths(for: "N0CALL", limit: 5)

        XCTAssertFalse(recent.isEmpty)
        XCTAssertEqual(recent.first?.count, 1)
    }

    func testRecentPathsDeduplication() {
        var suggester = PathSuggester()

        // Use same path multiple times
        suggester.recordSuccess(destination: "N0CALL", path: DigiPath.from(["WIDE1-1"]), rtt: 2.0)
        suggester.recordSuccess(destination: "N0CALL", path: DigiPath.from(["WIDE1-1"]), rtt: 2.1)
        suggester.recordSuccess(destination: "N0CALL", path: DigiPath.from(["WIDE1-1"]), rtt: 1.9)

        let recent = suggester.recentPaths(for: "N0CALL", limit: 5)

        // Should deduplicate
        XCTAssertEqual(recent.count, 1)
    }

    // MARK: - Reason Generation Tests

    func testReasonGenerationBestETT() {
        let score = PathScore(etx: 1.2, ett: 1.8, hops: 2, freshness: 0.92)
        let reason = PathSuggestion.generateReason(for: score, category: .bestETT)

        XCTAssertTrue(reason.contains("1.8"))
        XCTAssertTrue(reason.contains("2 hops"))
        XCTAssertTrue(reason.contains("92%"))
    }

    func testReasonGenerationMostReliable() {
        let score = PathScore(etx: 1.1, ett: 2.5, hops: 3, freshness: 0.85)
        let reason = PathSuggestion.generateReason(for: score, category: .mostReliable)

        XCTAssertTrue(reason.contains("ETX"))
        XCTAssertTrue(reason.contains("1.1"))
    }

    func testReasonGenerationDirect() {
        let score = PathScore(etx: 1.0, ett: 0.5, hops: 0, freshness: 1.0)
        let reason = PathSuggestion.generateReason(for: score, category: .direct)

        XCTAssertTrue(reason.lowercased().contains("direct"))
    }
}
