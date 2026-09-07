import XCTest
@testable import AXTerm

/// APRS receive parsing, pinned against real frames heard on the operator's
/// 144.390 channel plus a compressed round-trip and a Mic-E sanity check.
final class APRSParserTests: XCTestCase {

    private func parse(_ info: String, dest: String = "APRS") -> APRSReport? {
        APRSParser.parse(destination: dest, info: Data(info.utf8))
    }

    // MARK: - Uncompressed

    func testDigiPositionNoTimestamp() {
        let r = parse("!3933.48N/10447.65W#LSA WIDE1 DigiGate")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.latitude ?? 0, 39.558, accuracy: 0.001)
        XCTAssertEqual(r?.longitude ?? 0, -104.7942, accuracy: 0.001)
        XCTAssertEqual(r?.symbolTable, "/")
        XCTAssertEqual(r?.symbolCode, "#")
        XCTAssertEqual(r?.hasTimestamp, false)
    }

    func testMobileWithCourseSpeedAndAltitude() {
        let r = parse("!3851.33N/10452.70Wj001/000/A=006092Anytone 578UVII Plus")
        XCTAssertEqual(r?.latitude ?? 0, 38.8555, accuracy: 0.001)
        XCTAssertEqual(r?.longitude ?? 0, -104.8783, accuracy: 0.001)
        XCTAssertEqual(r?.symbolCode, "j")
        XCTAssertEqual(r?.courseDegrees, 1)
        XCTAssertEqual(r?.speedKnots, 0)
        XCTAssertEqual(r?.altitudeFeet, 6092)
        XCTAssertEqual(r?.comment, "Anytone 578UVII Plus")
    }

    func testTimestampedPosition() {
        let r = parse("@072235z3934.15N/10455.05W-WX3in1Mini U=12.4V")
        XCTAssertEqual(r?.hasTimestamp, true)
        XCTAssertEqual(r?.latitude ?? 0, 39.5692, accuracy: 0.001)
        XCTAssertEqual(r?.longitude ?? 0, -104.9175, accuracy: 0.001)
        XCTAssertEqual(r?.symbolCode, "-")
        XCTAssertEqual(r?.comment, "WX3in1Mini U=12.4V")
    }

    func testPositionWithMessagingAndAltitudeInComment() {
        let r = parse("=3953.29N/10500.26Wr146.415MHz/A=005397")
        XCTAssertEqual(r?.latitude ?? 0, 39.8882, accuracy: 0.001)
        XCTAssertEqual(r?.longitude ?? 0, -105.0043, accuracy: 0.001)
        XCTAssertEqual(r?.symbolCode, "r")
        XCTAssertEqual(r?.altitudeFeet, 5397)
    }

    func testSouthernEasternHemispheres() {
        let r = parse("!3351.90S/15112.54E-")
        XCTAssertEqual(r?.latitude ?? 0, -33.865, accuracy: 0.001)
        XCTAssertEqual(r?.longitude ?? 0, 151.209, accuracy: 0.001)
    }

    func testNonPositionPayloadsAreIgnored() {
        XCTAssertNil(parse(":WU2Z     :Testing message"))   // message
        XCTAssertNil(parse(">Just a status text"))          // status
        XCTAssertNil(parse("T#005,199,000,255,073,123,01101001"))  // telemetry
    }

    // MARK: - Compressed (round-trip against the formatter)

    func testCompressedRoundTrip() {
        var report = APRSBeacon.PositionReport(
            latitude: 39.5, longitude: -105.25, symbolTable: "/", symbolCode: "-")
        report.compressed = true
        let info = APRSBeacon.infoField(report)      // "!/YYYYXXXX-  T"
        let r = parse(info)
        XCTAssertEqual(r?.kind, .compressed)
        XCTAssertEqual(r?.latitude ?? 0, 39.5, accuracy: 0.01)
        XCTAssertEqual(r?.longitude ?? 0, -105.25, accuracy: 0.01)
        XCTAssertEqual(r?.symbolTable, "/")
        XCTAssertEqual(r?.symbolCode, "-")
    }

    // MARK: - Mic-E (real Colorado frame heard on 144.390)

    func testMicEDecodesToAPlausibleColoradoPosition() {
        // Destination "SYSQSQ" carries the latitude; the info the longitude.
        let info = "\u{60}pEzn6cR/\u{60}\"Hd]_4"
        let r = APRSParser.parse(destination: "SYSQSQ", info: Data(info.utf8))
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.kind, .micE)
        XCTAssertEqual(r?.latitude ?? 0, 39.52, accuracy: 0.1)
        XCTAssertEqual(r?.longitude ?? 0, -104.70, accuracy: 0.1)
        XCTAssertEqual(r?.symbolTable, "/")
    }
}
