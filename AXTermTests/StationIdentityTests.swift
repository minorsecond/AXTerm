import Foundation
import Testing
@testable import AXTerm

struct StationIdentityTests {

    // MARK: - CallsignParser Tests

    @Test
    func parseSimpleCallsign() {
        let parsed = CallsignParser.parse("ANH")
        #expect(parsed.base == "ANH")
        #expect(parsed.ssid == nil)
        #expect(parsed.full == "ANH")
    }

    @Test
    func parseCallsignWithSSID() {
        let parsed = CallsignParser.parse("ANH-15")
        #expect(parsed.base == "ANH")
        #expect(parsed.ssid == 15)
        #expect(parsed.full == "ANH-15")
    }

    @Test
    func parseCallsignWithSSIDZero() {
        // SSID-0 is equivalent to no SSID
        let parsed = CallsignParser.parse("ANH-0")
        #expect(parsed.base == "ANH")
        #expect(parsed.ssid == nil)
        #expect(parsed.full == "ANH")
    }

    @Test
    func parseCallsignNormalizesCase() {
        let parsed = CallsignParser.parse("anh-15")
        #expect(parsed.base == "ANH")
        #expect(parsed.ssid == 15)
        #expect(parsed.full == "ANH-15")
    }

    @Test
    func parseCallsignTrimsWhitespace() {
        let parsed = CallsignParser.parse("  ANH-1  ")
        #expect(parsed.base == "ANH")
        #expect(parsed.ssid == 1)
        #expect(parsed.full == "ANH-1")
    }

    @Test
    func parseCallsignWithInvalidSSID() {
        // SSIDs must be 0-15, anything else is not a valid SSID
        let parsed = CallsignParser.parse("ANH-99")
        #expect(parsed.base == "ANH-99")
        #expect(parsed.ssid == nil)
        #expect(parsed.full == "ANH-99")
    }

    @Test
    func parseCallsignWithDashInBase() {
        // Some callsigns have dashes (e.g., "WIDE1-1")
        // This is valid if the suffix is a valid SSID
        let parsed = CallsignParser.parse("WIDE1-1")
        #expect(parsed.base == "WIDE1")
        #expect(parsed.ssid == 1)
        #expect(parsed.full == "WIDE1-1")
    }

    // MARK: - Identity Key Tests

    @Test
    func identityKeyStationMode() {
        #expect(CallsignParser.identityKey(for: "ANH", mode: .station) == "ANH")
        #expect(CallsignParser.identityKey(for: "ANH-1", mode: .station) == "ANH")
        #expect(CallsignParser.identityKey(for: "ANH-15", mode: .station) == "ANH")
    }

    @Test
    func identityKeySSIDMode() {
        #expect(CallsignParser.identityKey(for: "ANH", mode: .ssid) == "ANH")
        #expect(CallsignParser.identityKey(for: "ANH-1", mode: .ssid) == "ANH-1")
        #expect(CallsignParser.identityKey(for: "ANH-15", mode: .ssid) == "ANH-15")
    }

    // MARK: - StationKey Tests

    @Test
    func stationKeyIDInStationMode() {
        let key = StationKey(callsign: "ANH-15", mode: .station)
        #expect(key.id == "ANH")  // Base callsign only
        #expect(key.base == "ANH")
        #expect(key.ssid == 15)
        #expect(key.fullCallsign == "ANH-15")
    }

    @Test
    func stationKeyIDInSSIDMode() {
        let key = StationKey(callsign: "ANH-15", mode: .ssid)
        #expect(key.id == "ANH-15")  // Full callsign with SSID
        #expect(key.base == "ANH")
        #expect(key.ssid == 15)
        #expect(key.fullCallsign == "ANH-15")
    }

    @Test
    func stationKeyHashableByIDNotMode() {
        // Keys with same ID in same mode should be equal
        let key1 = StationKey(callsign: "ANH-1", mode: .station)
        let key2 = StationKey(callsign: "ANH-15", mode: .station)

        // In station mode, both resolve to "ANH" as ID
        #expect(key1.id == key2.id)

        // But they have different ssid values
        #expect(key1.ssid != key2.ssid)
    }

    // MARK: - StationIdentityMode Tests

    @Test
    func stationIdentityModeRawValues() {
        #expect(StationIdentityMode.station.rawValue == "station")
        #expect(StationIdentityMode.ssid.rawValue == "ssid")
    }

    @Test
    func stationIdentityModeDisplayNames() {
        #expect(StationIdentityMode.station.displayName == "Group by Station")
        #expect(StationIdentityMode.ssid.displayName == "Split by SSID")
    }

    @Test
    func stationIdentityModeShortNames() {
        #expect(StationIdentityMode.station.shortName == "Station")
        #expect(StationIdentityMode.ssid.shortName == "SSID")
    }

    // MARK: - Edge Cases

    @Test
    func parseEmptyCallsign() {
        let parsed = CallsignParser.parse("")
        #expect(parsed.base == "")
        #expect(parsed.ssid == nil)
        #expect(parsed.full == "")
    }

    @Test
    func parseOnlyWhitespace() {
        let parsed = CallsignParser.parse("   ")
        #expect(parsed.base == "")
        #expect(parsed.ssid == nil)
    }
}
