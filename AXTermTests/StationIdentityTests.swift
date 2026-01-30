import Foundation
import XCTest
@testable import AXTerm

final class StationIdentityTests: XCTestCase {

    // MARK: - CallsignParser Tests

    func testParseSimpleCallsign() {
        let parsed = CallsignParser.parse("W6ANH")
        XCTAssertEqual(parsed.base, "W6ANH")
        XCTAssertNil(parsed.ssid)
        XCTAssertEqual(parsed.full, "W6ANH")
    }

    func testParseCallsignWithSSID() {
        let parsed = CallsignParser.parse("W6ANH-15")
        XCTAssertEqual(parsed.base, "W6ANH")
        XCTAssertEqual(parsed.ssid, 15)
        XCTAssertEqual(parsed.full, "W6ANH-15")
    }

    func testParseCallsignWithSSIDZero() {
        // SSID-0 is equivalent to no SSID
        let parsed = CallsignParser.parse("W6ANH-0")
        XCTAssertEqual(parsed.base, "W6ANH")
        XCTAssertNil(parsed.ssid)
        XCTAssertEqual(parsed.full, "W6ANH")
    }

    func testParseCallsignNormalizesCase() {
        let parsed = CallsignParser.parse("w6anh-15")
        XCTAssertEqual(parsed.base, "W6ANH")
        XCTAssertEqual(parsed.ssid, 15)
        XCTAssertEqual(parsed.full, "W6ANH-15")
    }

    func testParseCallsignTrimsWhitespace() {
        let parsed = CallsignParser.parse("  W6ANH-1  ")
        XCTAssertEqual(parsed.base, "W6ANH")
        XCTAssertEqual(parsed.ssid, 1)
        XCTAssertEqual(parsed.full, "W6ANH-1")
    }

    func testParseCallsignWithInvalidSSID() {
        // SSIDs must be 0-15, anything else is not a valid SSID
        let parsed = CallsignParser.parse("W6ANH-99")
        XCTAssertEqual(parsed.base, "W6ANH-99")
        XCTAssertNil(parsed.ssid)
        XCTAssertEqual(parsed.full, "W6ANH-99")
    }

    func testParseCallsignWithDashInBase() {
        // Some callsigns have dashes (e.g., "WIDE1-1")
        // This is valid if the suffix is a valid SSID
        let parsed = CallsignParser.parse("WIDE1-1")
        XCTAssertEqual(parsed.base, "WIDE1")
        XCTAssertEqual(parsed.ssid, 1)
        XCTAssertEqual(parsed.full, "WIDE1-1")
    }

    // MARK: - Identity Key Tests

    func testIdentityKeyStationMode() {
        XCTAssertEqual(CallsignParser.identityKey(for: "W6ANH", mode: .station), "W6ANH")
        XCTAssertEqual(CallsignParser.identityKey(for: "W6ANH-1", mode: .station), "W6ANH")
        XCTAssertEqual(CallsignParser.identityKey(for: "W6ANH-15", mode: .station), "W6ANH")
    }

    func testIdentityKeySSIDMode() {
        XCTAssertEqual(CallsignParser.identityKey(for: "W6ANH", mode: .ssid), "W6ANH")
        XCTAssertEqual(CallsignParser.identityKey(for: "W6ANH-1", mode: .ssid), "W6ANH-1")
        XCTAssertEqual(CallsignParser.identityKey(for: "W6ANH-15", mode: .ssid), "W6ANH-15")
    }

    // MARK: - StationKey Tests

    func testStationKeyIDInStationMode() {
        let key = StationKey(callsign: "W6ANH-15", mode: .station)
        XCTAssertEqual(key.id, "W6ANH")  // Base callsign only
        XCTAssertEqual(key.base, "W6ANH")
        XCTAssertEqual(key.ssid, 15)
        XCTAssertEqual(key.fullCallsign, "W6ANH-15")
    }

    func testStationKeyIDInSSIDMode() {
        let key = StationKey(callsign: "W6ANH-15", mode: .ssid)
        XCTAssertEqual(key.id, "W6ANH-15")  // Full callsign with SSID
        XCTAssertEqual(key.base, "W6ANH")
        XCTAssertEqual(key.ssid, 15)
        XCTAssertEqual(key.fullCallsign, "W6ANH-15")
    }

    func testStationKeyHashableByIDNotMode() {
        // Keys with same ID in same mode should be equal
        let key1 = StationKey(callsign: "W6ANH-1", mode: .station)
        let key2 = StationKey(callsign: "W6ANH-15", mode: .station)

        // In station mode, both resolve to "W6ANH" as ID
        XCTAssertEqual(key1.id, key2.id)

        // But they have different ssid values
        XCTAssertNotEqual(key1.ssid, key2.ssid)
    }

    // MARK: - StationIdentityMode Tests

    func testStationIdentityModeRawValues() {
        XCTAssertEqual(StationIdentityMode.station.rawValue, "station")
        XCTAssertEqual(StationIdentityMode.ssid.rawValue, "ssid")
    }

    func testStationIdentityModeDisplayNames() {
        XCTAssertEqual(StationIdentityMode.station.displayName, "Group by Station")
        XCTAssertEqual(StationIdentityMode.ssid.displayName, "Split by SSID")
    }

    func testStationIdentityModeShortNames() {
        XCTAssertEqual(StationIdentityMode.station.shortName, "Station")
        XCTAssertEqual(StationIdentityMode.ssid.shortName, "SSID")
    }

    // MARK: - Edge Cases

    func testParseEmptyCallsign() {
        let parsed = CallsignParser.parse("")
        XCTAssertEqual(parsed.base, "")
        XCTAssertNil(parsed.ssid)
        XCTAssertEqual(parsed.full, "")
    }

    func testParseOnlyWhitespace() {
        let parsed = CallsignParser.parse("   ")
        XCTAssertEqual(parsed.base, "")
        XCTAssertNil(parsed.ssid)
    }
}
