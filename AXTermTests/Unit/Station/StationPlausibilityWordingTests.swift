//
//  StationPlausibilityWordingTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

/// The card must not claim a station was heard over the air when the app has
/// already judged that it could not have been.
///
/// KC0AUH-2, 2026-09-10: 394 km away, counted in the sidebar's "4 too far to
/// have been heard", while its own card read "Position from APRS position
/// (heard over the air)." Both statements came from the same app.
final class StationPlausibilityWordingTests: XCTestCase {

    private let home = GreatCircle.Point(latitude: 39.6117, longitude: -104.7317)
    /// KC0AUH-2, Finney Co. digi, Dodge City KS — from the prod database.
    private let dodgeCity = GreatCircle.Point(latitude: 37.7567, longitude: -100.8680)
    /// WQ8M-9, 9 km away, heard direct every few minutes.
    private let nearby = GreatCircle.Point(latitude: 39.5580, longitude: -104.7942)

    private func verdict(for station: GreatCircle.Point?) -> StationPlausibility.Verdict {
        StationPlausibility.verdict(observer: home, station: station, confidence: .exact)
    }

    // MARK: - The claim is made only when it holds

    func testAStationInRangeIsStillSaidToHaveBeenHeard() {
        let line = StationPlausibility.positionSourceLine(
            source: "APRS position", verdict: verdict(for: nearby))
        XCTAssertEqual(line, "Position from APRS position (heard over the air).")
    }

    func testAStationBeyondRangeIsNotSaidToHaveBeenHeard() {
        let v = verdict(for: dodgeCity)
        XCTAssertTrue(v.isImplausible, "394 km is past the 300 km threshold")

        let line = StationPlausibility.positionSourceLine(source: "APRS position", verdict: v)
        XCTAssertFalse(line.contains("heard over the air"),
                       "the card must not contradict the list it was hidden from")
        XCTAssertTrue(line.contains("this map treats as directly hearable"), line)
        XCTAssertFalse(line.contains("beyond radio range"),
                       "naming a display rule is honest; asserting propagation is not")
        // And it stops there. How it did arrive is not distance's to say.
        XCTAssertFalse(line.contains("relayed"), line)
    }

    /// The distance is the certain part, so it is the part that gets stated —
    /// in the operator's own units.
    func testTheDistanceIsQuotedInTheOperatorsUnits() {
        let v = verdict(for: dodgeCity)
        XCTAssertTrue(StationPlausibility.positionSourceLine(
            source: "APRS position", verdict: v, inMiles: false).contains("km"))
        XCTAssertTrue(StationPlausibility.positionSourceLine(
            source: "APRS position", verdict: v, inMiles: true).contains("mi"))
    }

    /// Distance says the frame did not arrive directly. It does not say how
    /// it did — a relay, an igate and a genuinely long RF path are all
    /// consistent with it, and the frame names none of them. Nor does it say
    /// the path was impossible: WA6IFI-6 sits at 12,349 ft and repeats
    /// stations 292 km out, which a flat threshold would call unhearable.
    func testItDoesNotGuessAtAMechanism() {
        let line = StationPlausibility.positionSourceLine(
            source: "APRS position", verdict: verdict(for: dodgeCity))
        for guess in ["internet", "igate", "APRS-IS", "relay", "gateway"] {
            XCTAssertFalse(line.lowercased().contains(guess.lowercased()),
                           "the line should not claim \(guess): \(line)")
        }
    }

    // MARK: - No position, no judgement

    func testAStationWithNoPositionKeepsItsPlainWording() {
        let line = StationPlausibility.positionSourceLine(
            source: "licence address", verdict: verdict(for: nil))
        XCTAssertEqual(line, "Position from licence address (heard over the air).")
    }

    /// A position inferred from the operator's licence is about the person,
    /// not the radio, so distance says nothing and nothing is claimed against
    /// it — the existing rule, restated here because the wording depends on it.
    func testAnOperatorInferredPositionIsNeverCalledOutOfRange() {
        let v = StationPlausibility.verdict(observer: home, station: dodgeCity,
                                            confidence: .inferredFromOperator)
        XCTAssertFalse(v.isImplausible)
        XCTAssertTrue(StationPlausibility.positionSourceLine(source: "licence address", verdict: v)
            .contains("heard over the air"))
    }
}
