import XCTest
@testable import AXTerm

/// The small rules behind the iOS polish pass: which SSID meanings a radio
/// shows, when timing fields can be edited, what the map centers on without
/// a position, the settings list footers, the setup sheet's height and the station
/// card.
final class IOSPolishRulesTests: XCTestCase {

    // MARK: - SSID meanings

    func testAPRSMeaningsOnlyOnAnAPRSChannel() {
        XCTAssertEqual(SSIDConvention.family(for: .aprs), .aprs)
        XCTAssertEqual(SSIDConvention.family(for: .packet), .ax25)
        XCTAssertEqual(SSIDConvention.detail(ssid: 0, family: SSIDConvention.family(for: .aprs), usage: [:]),
                       "Home station, fixed")
        // A packet radio with no neighbors' evidence gets no meaning, never
        // the APRS table.
        XCTAssertNil(SSIDConvention.detail(ssid: 0, family: SSIDConvention.family(for: .packet), usage: [:]))
        XCTAssertNil(SSIDConvention.detail(ssid: 9, family: SSIDConvention.family(for: .packet), usage: [:]))
    }

    func testAPacketRadioStillGetsItsNeighborsUsage() {
        let usage: [Int: [StationServiceParser.Service: Int]] = [7: [.node: 3]]
        let detail = SSIDConvention.detail(ssid: 7, family: SSIDConvention.family(for: .packet), usage: usage)
        XCTAssertNotNil(detail)
        XCTAssertFalse(detail?.hasPrefix("APRS") ?? true)
        XCTAssertTrue(SSIDConvention.hasLocalMeanings(usage))
        XCTAssertFalse(SSIDConvention.hasLocalMeanings([:]))
    }

    // MARK: - Timing fields

    func testTimingFieldsLockWhenNothingIsSent() {
        XCTAssertFalse(RadioTimingSection.fieldsEditable(delivery: .optional, sendsTiming: false))
        XCTAssertTrue(RadioTimingSection.fieldsEditable(delivery: .optional, sendsTiming: true))
        XCTAssertTrue(RadioTimingSection.fieldsEditable(delivery: .sentByLink, sendsTiming: false))
        XCTAssertTrue(RadioTimingSection.fieldsEditable(delivery: .modem, sendsTiming: false))
    }

    // MARK: - Map center

    func testTheMapCentersOnThisStationWhenItHasAPosition() {
        let own = GreatCircle.Point(latitude: 39.56, longitude: -104.79)
        let heard = [GreatCircle.Point(latitude: 39.9, longitude: -105.0)]
        let center = MapCenterRule.center(own: own, heard: heard)
        XCTAssertEqual(center, .ownStation(own))
        XCTAssertEqual(center?.showsDistances, true)
    }

    func testWithoutAPositionTheMapCentersOnTheHeardStationsAndHidesDistances() {
        let heard = [GreatCircle.Point(latitude: 39.0, longitude: -105.0),
                     GreatCircle.Point(latitude: 40.0, longitude: -104.0)]
        guard let center = MapCenterRule.center(own: nil, heard: heard) else {
            return XCTFail("heard stations should still be drawn")
        }
        XCTAssertFalse(center.showsDistances)
        XCTAssertEqual(center.point.latitude, 39.5, accuracy: 0.05)
        XCTAssertEqual(center.point.longitude, -104.5, accuracy: 0.05)
    }

    func testWithNeitherThereIsNothingToDraw() {
        XCTAssertNil(MapCenterRule.center(own: nil, heard: []))
    }

    func testTheCentroidDoesNotJumpAcrossTheAntimeridian() {
        let c = MapCenterRule.centroid(of: [GreatCircle.Point(latitude: 0, longitude: 179),
                                            GreatCircle.Point(latitude: 0, longitude: -179)])
        XCTAssertEqual(abs(c?.longitude ?? 0), 180, accuracy: 0.01)
    }

    // MARK: - Settings list footers

    func testTheGeneralFooterShowsTheBaseCallAndTheOnAirAddresses() {
        XCTAssertEqual(SettingsListFooter.station(callsign: "K0EPI", onAir: ["K0EPI"]), "K0EPI")
        XCTAssertEqual(SettingsListFooter.station(callsign: "K0EPI", onAir: ["K0EPI-10", "K0EPI-7"]),
                       "K0EPI \u{b7} on air as K0EPI-10, K0EPI-7")
        XCTAssertEqual(SettingsListFooter.station(callsign: "", onAir: []), "No callsign set")
    }

    func testTheRadiosFooterCarriesTheEndpoint() {
        var direwolf = RadioProfile(id: RadioID(rawValue: "a"), name: "")
        direwolf.host = "localhost"
        direwolf.port = 8001
        XCTAssertEqual(SettingsListFooter.radios([direwolf]), "Direwolf \u{b7} localhost:8001")
        let other = RadioProfile(id: RadioID(rawValue: "b"), name: "Handheld")
        XCTAssertEqual(SettingsListFooter.radios([direwolf, other]), "Direwolf, Handheld")
        XCTAssertEqual(SettingsListFooter.radios([]), "No radio set up")
    }

    // MARK: - Setup sheet height

    func testTheSetupSheetAsksForItsContentsHeight() {
        XCTAssertEqual(SetupSheetHeight.fitting(header: 120, content: 300.4, buttons: 56), 479)
        XCTAssertEqual(SetupSheetHeight.fitting(header: 0, content: 300, buttons: 56),
                       SetupSheetHeight.unmeasured)
    }

    // MARK: - Station card

    func testTheCardDetailLeavesOutTheCallsignAndQuotesMotion() {
        let entry = HeardStationMap.Entry(
            callsign: "W6AUN-9", heardCount: 3, lastHeard: nil, lastVia: [],
            position: GreatCircle.Point(latitude: 39.52, longitude: -104.93),
            positionSource: StationPlausibility.aprsSource,
            courseDegrees: 274, speedKnots: 32)
        let card = HeardStationMap.detail(for: entry, observer: nil, now: Date(),
                                          distanceInMiles: true, includesCallsign: false)
        XCTAssertFalse(card.hasPrefix("W6AUN-9"), card)
        XCTAssertTrue(card.contains("37 mph at 274\u{b0}"), card)
        XCTAssertTrue(card.contains("Beaconed position, heard over the air."), card)
        let tooltip = HeardStationMap.detail(for: entry, observer: nil, now: Date())
        XCTAssertTrue(tooltip.hasPrefix("W6AUN-9"))
    }
}
