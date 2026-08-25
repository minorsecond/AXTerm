//
//  PredictedPathTests.swift
//  AXTermTests
//
//  The one thing that says something about a path *before* the first
//  transmission. Everything else AXTerm knows is a record of what already
//  happened.
//

import XCTest
@testable import AXTerm

/// Synthetic terrain, so the physics is tested against known ground rather
/// than whatever a download happened to return.
private struct FlatGround: ElevationSampling {
    let metres: Double
    func elevation(at point: GreatCircle.Point) -> Double? { metres }
}

private struct RidgeInTheMiddle: ElevationSampling {
    let base: Double
    let peak: Double
    let origin: GreatCircle.Point
    let destination: GreatCircle.Point

    func elevation(at point: GreatCircle.Point) -> Double? {
        let total = GreatCircle.kilometres(from: origin, to: destination)
        let along = GreatCircle.kilometres(from: origin, to: point)
        let fraction = total > 0 ? along / total : 0
        // A single peak halfway.
        return fraction > 0.45 && fraction < 0.55 ? peak : base
    }
}

private struct NoData: ElevationSampling {
    func elevation(at point: GreatCircle.Point) -> Double? { nil }
}

final class PredictedPathTests: XCTestCase {

    private let denver = GreatCircle.Point(latitude: 39.74, longitude: -104.99)
    private let nearby = GreatCircle.Point(latitude: 39.85, longitude: -105.05)
    private let vhf = 145_030_000.0

    private func predictions(_ sampler: ElevationSampling,
                             positions: [String: GreatCircle.Point],
                             observed: [NetworkPath] = [],
                             antennaMetres: Double = 10) -> [PredictedPath] {
        PredictedPath.predictions(
            between: positions, alreadyObserved: observed,
            sampler: sampler, frequencyHz: vhf,
            defaultHeightMetres: antennaMetres)
    }

    // MARK: - Verdicts

    func testHilltopStationsOverFlatGroundAreClear() {
        // 60 m above ground at both ends over 13 km. Sixty percent of the
        // first Fresnel zone needs roughly 49 m of clearance at 145 MHz over
        // this distance, so this is the geometry that actually qualifies.
        let paths = predictions(FlatGround(metres: 1600),
                                positions: ["A": denver, "B": nearby],
                                antennaMetres: 60)
        XCTAssertEqual(paths.count, 1)
        if case .promising = paths[0].outlook {} else {
            XCTFail("hilltop antennas over flat ground should be clear, got \(paths[0].outlook)")
        }
    }

    func testModestAntennasOverFlatGroundAreOnlyMarginal() {
        // Not a bug — the physics. Two 10 m antennas 13 km apart at 145 MHz
        // clear about 9% of the first Fresnel zone against the 60% a path
        // needs to behave like an open one. This is exactly why VHF packet
        // lives on hilltops, and why a link can be "line of sight" on a map
        // and still struggle.
        let paths = predictions(FlatGround(metres: 1600),
                                positions: ["A": denver, "B": nearby],
                                antennaMetres: 10)
        if case .marginal(let ratio) = paths[0].outlook {
            XCTAssertLessThan(ratio, 0.6)
        } else {
            XCTFail("expected marginal, got \(paths[0].outlook)")
        }
    }

    func testARidgeAcrossTheLineBlocksIt() {
        let sampler = RidgeInTheMiddle(base: 1600, peak: 3600,
                                       origin: denver, destination: nearby)
        let paths = predictions(sampler, positions: ["A": denver, "B": nearby])
        if case .blocked(let metres, _) = paths[0].outlook {
            XCTAssertGreaterThan(metres, 0)
        } else {
            XCTFail("a 2 km ridge halfway should block, got \(paths[0].outlook)")
        }
    }

    func testAGrazingRidgeIsMarginalRatherThanClear() {
        // A path that clears the ground by a metre is not a clear path — the
        // Fresnel zone has to be open too, and this is exactly the "answers
        // but struggles" signature.
        let sampler = RidgeInTheMiddle(base: 1600, peak: 1650,
                                       origin: denver, destination: nearby)
        let paths = predictions(sampler, positions: ["A": denver, "B": nearby],
                                antennaMetres: 60)
        switch paths[0].outlook {
        case .marginal, .blocked: break
        case .promising:
            XCTFail("a ridge grazing the line must not read as clear")
        }
    }

    // MARK: - Restraint

    func testMissingElevationDataProducesNoPrediction() {
        // A gap read as "clear" would draw an encouraging line across a
        // mountain — the most dangerous possible way to be wrong.
        XCTAssertTrue(predictions(NoData(), positions: ["A": denver, "B": nearby]).isEmpty)
    }

    func testAPathAlreadyObservedIsNotForecast() {
        let observed = NetworkPath(
            from: "A", to: "B", via: [], evidence: .heardDirect, observations: 1,
            firstSeen: Date(), lastSeen: Date(), unansweredAttempts: 0)
        let paths = predictions(FlatGround(metres: 1600),
                                positions: ["A": denver, "B": nearby],
                                observed: [observed])
        XCTAssertTrue(paths.isEmpty, "a path carrying frames is not a forecast")
    }

    func testTwoSSIDsAtOneCoordinateAreNotAPath() {
        let paths = predictions(FlatGround(metres: 1600),
                                positions: ["K0NTS-1": denver, "K0NTS-10": denver])
        XCTAssertTrue(paths.isEmpty)
    }

    func testDistantPairsAreNotEvaluated() {
        let farAway = GreatCircle.Point(latitude: 45.0, longitude: -110.0)
        let paths = predictions(FlatGround(metres: 1600),
                                positions: ["A": denver, "B": farAway])
        // Beyond a certain range the curvature decides the answer, and the
        // elevation data is not needed to say no.
        XCTAssertTrue(paths.isEmpty)
    }

    func testTheResultIsCapped() {
        var positions: [String: GreatCircle.Point] = [:]
        for i in 0..<40 {
            positions["S\(i)"] = GreatCircle.Point(
                latitude: 39.7 + Double(i) * 0.002, longitude: -105.0)
        }
        let paths = PredictedPath.predictions(
            between: positions, alreadyObserved: [],
            sampler: FlatGround(metres: 1600), frequencyHz: vhf, limit: 25)
        XCTAssertLessThanOrEqual(paths.count, 25)
    }

    // MARK: - Presentation

    func testBlockedPathsAreNotDrawn() {
        let blocked = PredictedPath(from: "A", to: "B",
                                    outlook: .blocked(byMetres: 300, atMetres: 8000),
                                    distanceKilometres: 20)
        // A real finding, but a mesh of lines saying "no" is not a map.
        XCTAssertFalse(blocked.isWorthDrawing)
    }

    func testPromisingAndMarginalAreDrawn() {
        XCTAssertTrue(PredictedPath(from: "A", to: "B",
                                    outlook: .promising(worstFresnelRatio: 1.2),
                                    distanceKilometres: 20).isWorthDrawing)
        XCTAssertTrue(PredictedPath(from: "A", to: "B",
                                    outlook: .marginal(worstFresnelRatio: 0.3),
                                    distanceKilometres: 20).isWorthDrawing)
    }

    func testEveryOutlookExplainsItsGeometry() {
        let outlooks: [PredictedPath.Outlook] = [
            .promising(worstFresnelRatio: 1.1),
            .marginal(worstFresnelRatio: 0.3),
            .blocked(byMetres: 120, atMetres: 9000),
        ]
        for outlook in outlooks {
            XCTAssertFalse(outlook.label.isEmpty)
            // An operator who disagrees should be able to see what was measured.
            XCTAssertTrue(outlook.explanation.count > 40, "\(outlook) explains too little")
        }
    }

    func testUnknownTerrainMapsToNoOutlook() {
        XCTAssertNil(PredictedPath.outlook(for: .unknown("no tiles")))
    }

    // MARK: - Antenna heights

    /// The whole reason to ask the operator for a height: a real one turns a
    /// verdict from "marginal" into "clear" on ground that never changed.
    func testARecordedHeightChangesTheVerdict() {
        let positions = ["A": denver, "B": nearby]
        let assumed = PredictedPath.predictions(
            between: positions, alreadyObserved: [],
            sampler: FlatGround(metres: 1600), frequencyHz: vhf,
            defaultHeightMetres: 10)
        if case .promising = assumed[0].outlook {
            XCTFail("10 m each should not clear the zone over this distance")
        }

        let recorded = PredictedPath.predictions(
            between: positions, alreadyObserved: [],
            sampler: FlatGround(metres: 1600), frequencyHz: vhf,
            heights: ["A": 60, "B": 60], defaultHeightMetres: 10)
        if case .promising = recorded[0].outlook {} else {
            XCTFail("60 m each should clear it, got \(recorded[0].outlook)")
        }
    }

    func testForecastIsMarkedAssumedUntilBothEndsAreRecorded() {
        let positions = ["A": denver, "B": nearby]
        func path(_ heights: [String: Double]) -> PredictedPath {
            PredictedPath.predictions(
                between: positions, alreadyObserved: [],
                sampler: FlatGround(metres: 1600), frequencyHz: vhf,
                heights: heights, defaultHeightMetres: 60)[0]
        }
        XCTAssertTrue(path([:]).assumedHeights)
        XCTAssertTrue(path(["A": 60]).assumedHeights, "one end is still a guess")
        XCTAssertFalse(path(["A": 60, "B": 60]).assumedHeights)
    }

    /// A recorded zero is a handheld at street level, not a missing value.
    func testRecordedZeroIsUsedRatherThanFallingBackToTheDefault() {
        let positions = ["A": denver, "B": nearby]
        let path = PredictedPath.predictions(
            between: positions, alreadyObserved: [],
            sampler: FlatGround(metres: 1600), frequencyHz: vhf,
            heights: ["A": 0, "B": 0], defaultHeightMetres: 300)[0]
        XCTAssertFalse(path.assumedHeights)
        if case .promising = path.outlook {
            XCTFail("two antennas on the ground cannot be a clear path")
        }
    }

    // MARK: - Blocked paths

    /// Rolling ground at modest antenna heights blocks everything, and the
    /// height that would clear it is the useful part of that answer.
    func testABlockedPathReportsHowMuchHeightItWants() {
        let sampler = RidgeInTheMiddle(base: 1600, peak: 1700,
                                       origin: denver, destination: nearby)
        let paths = predictions(sampler, positions: ["A": denver, "B": nearby],
                                antennaMetres: 10)
        guard let metres = paths[0].blockedByMetres else {
            return XCTFail("expected a blocked path, got \(paths[0].outlook)")
        }
        XCTAssertGreaterThan(metres, 0)
        XCTAssertFalse(paths[0].isWorthDrawing)
    }

    func testAClearPathHasNoBlockingHeight() {
        let paths = predictions(FlatGround(metres: 1600),
                                positions: ["A": denver, "B": nearby],
                                antennaMetres: 60)
        XCTAssertNil(paths[0].blockedByMetres)
    }
}
