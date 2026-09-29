//
//  StationAltitudeTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

/// Altitude a station transmits.
///
/// `/A=` and the Mic-E form were both parsed and then dropped — nothing
/// outside the parser ever read `altitudeFeet`. On this channel that matters:
/// WA6IFI-6 beacons from 12,349 ft and repeats stations 292 km out, and
/// judging a path without knowing that is how a horizon claim gets invented.
final class StationAltitudeTests: XCTestCase {

    func testTheParserAlreadyReadsItFromAnUncompressedBeacon() throws {
        let report = try XCTUnwrap(APRSParser.parse(
            destination: "APN391",
            info: Data("!3847.33N110459.55W#PHG3830 WA6IFI W2,COn /A=012349".utf8)))
        XCTAssertEqual(report.altitudeFeet, 12349)
    }

    func testABeaconWithNoAltitudeReportsNone() throws {
        let report = try XCTUnwrap(APRSParser.parse(
            destination: "APRX29",
            info: Data("!3933.48N/10447.65W#LSA WIDE1 DigiGate".utf8)))
        XCTAssertNil(report.altitudeFeet)
    }

    // MARK: - The operator's units

    func testFeetForAnOperatorReadingMiles() {
        XCTAssertEqual(AltitudeDisplay.string(feet: 12349, inFeet: true), "12,349 ft")
    }

    /// APRS transmits feet by definition, so metric is the conversion. Mixing
    /// the two on one card is how a terrain judgement gets made against the
    /// wrong number.
    func testMetresForAnOperatorReadingKilometres() {
        XCTAssertEqual(AltitudeDisplay.string(feet: 12349, inFeet: false), "3,764 m")
        XCTAssertEqual(AltitudeDisplay.string(feet: 0, inFeet: false), "0 m")
    }

    func testBelowSeaLevelSurvivesTheConversion() {
        XCTAssertEqual(AltitudeDisplay.string(feet: -282, inFeet: true), "-282 ft")
        XCTAssertEqual(AltitudeDisplay.string(feet: -282, inFeet: false), "-86 m")
    }
}
