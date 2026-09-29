import XCTest
@testable import AXTerm

/// What the SSID picker tells the operator, and where each half of it comes
/// from. APRS has a published convention; packet does not, and the difference
/// is the whole point of this type.
final class SSIDConventionTests: XCTestCase {

    private func entry(_ callsign: String,
                       _ service: StationServiceParser.Service) -> StationServiceEntry {
        StationServiceEntry(callsign: callsign, service: service, alias: nil,
                            confidence: .declared, firstHeard: .distantPast,
                            lastHeard: .distantPast, timesHeard: 1, sourceText: "")
    }

    // MARK: - Parsing

    func testABareCallsignHasNoSSID() {
        XCTAssertNil(SSIDConvention.ssid(of: "K0EPI"))
    }

    func testAnSSIDIsRead() {
        XCTAssertEqual(SSIDConvention.ssid(of: "K0EPI-7"), 7)
        XCTAssertEqual(SSIDConvention.ssid(of: "K0EPI-0"), 0)
        XCTAssertEqual(SSIDConvention.ssid(of: "K0EPI-15"), 15)
    }

    func testAnSSIDOutsideTheFourBitsIsNotAnSSID() {
        XCTAssertNil(SSIDConvention.ssid(of: "K0EPI-16"))
        XCTAssertNil(SSIDConvention.ssid(of: "K0EPI--1"))
        XCTAssertNil(SSIDConvention.ssid(of: "DWARC"))
    }

    // MARK: - The published APRS table

    func testEveryAPRSSSIDIsNamed() {
        for ssid in SSIDConvention.range {
            XCTAssertNotNil(SSIDConvention.aprsMeaning(ssid), "no APRS meaning for -\(ssid)")
        }
    }

    func testTheAPRSMeaningsPeopleActuallyLookUp() {
        XCTAssertEqual(SSIDConvention.aprsMeaning(9), "Mobile, in a vehicle")
        XCTAssertEqual(SSIDConvention.aprsMeaning(13), "Weather station")
        XCTAssertEqual(SSIDConvention.aprsMeaning(7), "Handheld")
    }

    // MARK: - Local evidence

    func testUsageCountsStationsRatherThanClaims() {
        // One node repeating its ID must not outvote two quieter ones.
        let entries = [entry("KB5YZB-7", .node), entry("KB5YZB-7", .node),
                       entry("KD0SSP-7", .node), entry("W0TX-7", .node)]
        let usage = SSIDConvention.localUsage(from: entries)
        XCTAssertEqual(usage[7]?[.node], 3)
    }

    func testBareCallsignsContributeNothing() {
        XCTAssertTrue(SSIDConvention.localUsage(from: [entry("DWARC", .node)]).isEmpty)
    }

    func testOneStationIsAnecdoteNotAdvice() {
        let usage = SSIDConvention.localUsage(from: [entry("W0TX-7", .node)])
        XCTAssertNil(SSIDConvention.localMeaning(7, usage: usage))
    }

    func testTwoStationsAgreeingIsAMeaning() {
        let usage = SSIDConvention.localUsage(from: [entry("W0TX-7", .node),
                                                    entry("N0BN-7", .node)])
        let meaning = SSIDConvention.localMeaning(7, usage: usage)
        XCTAssertEqual(meaning, "Here: net/rom node (2)")
    }

    func testTheCommonestUseIsNamedFirst() {
        let entries = [entry("ECRA-1", .digipeater), entry("K5KTI-1", .digipeater),
                       entry("W3OO-1", .digipeater),
                       entry("AB0VZ-1", .bbs), entry("N0BN-1", .bbs)]
        let meaning = SSIDConvention.localMeaning(1, usage: SSIDConvention.localUsage(from: entries))
        XCTAssertEqual(meaning, "Here: digipeater (3), bulletin board (2)")
    }

    // MARK: - Which advice each channel gets

    func testAnAPRSRadioIsToldThePublishedConvention() {
        let usage = SSIDConvention.localUsage(from: [entry("W0TX-9", .node),
                                                    entry("N0BN-9", .node)])
        // The local habit does not override what other people's software reads.
        XCTAssertEqual(SSIDConvention.detail(ssid: 9, family: .aprs, usage: usage),
                       "Mobile, in a vehicle")
    }

    func testAPacketRadioIsToldWhatItsOwnNeighboursDo() {
        let usage = SSIDConvention.localUsage(from: [entry("W0TX-7", .node),
                                                    entry("N0BN-7", .node)])
        XCTAssertEqual(SSIDConvention.detail(ssid: 7, family: .ax25, usage: usage),
                       "Here: net/rom node (2)")
    }

    func testAPacketRadioWithNoEvidenceIsToldNothingRatherThanTheAPRSTable() {
        XCTAssertNil(SSIDConvention.detail(ssid: 9, family: .ax25, usage: [:]))
    }

    func testAnUnsettledRadioPrefersEvidenceAndFallsBackToTheTable() {
        let usage = SSIDConvention.localUsage(from: [entry("W0TX-7", .node),
                                                    entry("N0BN-7", .node)])
        XCTAssertEqual(SSIDConvention.detail(ssid: 7, family: nil, usage: usage),
                       "Here: net/rom node (2)")
        // Nothing heard for -9, so the published meaning is offered, labelled.
        XCTAssertEqual(SSIDConvention.detail(ssid: 9, family: nil, usage: usage),
                       "APRS: Mobile, in a vehicle")
    }
}

/// Mapping a stored callsign back onto the SSID picker. A club call or a
/// tactical alias is its own identity and must not be shown as an SSID of the
/// station callsign.
final class IdentityPickerMappingTests: XCTestCase {

    private func ssid(_ call: String, station: String = "K0EPI") -> Int? {
        RadioDetailView.ssidUnderStation(call, station: station)
    }

    func testAnEmptyCallsignIsTheStationItself() {
        XCTAssertEqual(ssid(""), 0)
    }

    func testTheStationCallsignWithNoSSIDIsZero() {
        XCTAssertEqual(ssid("K0EPI"), 0)
        XCTAssertEqual(ssid("k0epi"), 0)
    }

    func testAnSSIDUnderTheStationCallsignMapsBack() {
        XCTAssertEqual(ssid("K0EPI-5"), 5)
        XCTAssertEqual(ssid("K0EPI-15"), 15)
    }

    func testAnotherOperatorsCallIsItsOwnIdentity() {
        XCTAssertNil(ssid("W0ARP-1"))
        XCTAssertNil(ssid("W0ARP"))
    }

    func testATacticalAliasIsItsOwnIdentity() {
        XCTAssertNil(ssid("DWARC"))
        XCTAssertNil(ssid("EPINOD"))
    }
}
