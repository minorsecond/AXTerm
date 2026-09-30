//
//  RadioChannelTests.swift
//  AXTermTests
//
//  A radio's channel is APRS or Packet, one or the other, stored as
//  `aprsEnabled`. The Channel picker reads and writes that and nothing
//  else the operator did not ask for.
//

import XCTest
@testable import AXTerm

final class RadioChannelTests: XCTestCase {

    private func radio(aprs: Bool = false, kind: BeaconKind = .text) -> RadioProfile {
        var radio = RadioProfile(id: RadioID(rawValue: "r"), name: "R")
        radio.aprsEnabled = aprs
        radio.beacon.kind = kind
        return radio
    }

    func testTheChannelIsReadFromAPRSEnabled() {
        XCTAssertEqual(RadioChannel.of(radio(aprs: true)), .aprs)
        XCTAssertEqual(RadioChannel.of(radio(aprs: false)), .packet)
    }

    func testChoosingAPRSSetsAPRSEnabledAndAPositionBeacon() {
        var r = radio()
        r.beacon.enabled = true
        r.beacon.text = "K0EPI node"
        r.beacon.intervalMinutes = 20
        RadioChannel.aprs.apply(to: &r)

        XCTAssertTrue(r.aprsEnabled)
        XCTAssertEqual(r.beacon.kind, .aprsPosition)
        XCTAssertEqual(r.beacon.aprs, .followingStation,
                       "a first position beacon follows the station position")
        XCTAssertTrue(r.beacon.aprs?.useGPS ?? false)
        XCTAssertTrue(r.beacon.enabled, "the on/off switch is kept")
        XCTAssertEqual(r.beacon.intervalMinutes, 20)
        XCTAssertEqual(r.beacon.text, "K0EPI node", "the ID beacon's text is kept for later")
        XCTAssertFalse(r.runsPacketServices)
    }

    func testChoosingPacketClearsAPRSEnabledAndKeepsThePositionSettings() {
        var r = radio(aprs: true, kind: .aprsPosition)
        r.beacon.aprs = APRSPositionConfig(useGPS: false, latitude: 39.5, longitude: -105.2,
                                           symbolTable: "/", symbolCode: ">")
        r.pings = false
        RadioChannel.packet.apply(to: &r)

        XCTAssertFalse(r.aprsEnabled)
        XCTAssertEqual(r.beacon.kind, .text)
        XCTAssertEqual(r.beacon.aprs?.symbolCode, ">", "the symbol comes back if APRS is chosen again")
        XCTAssertEqual(r.beacon.aprs?.latitude, 39.5)
        XCTAssertFalse(r.pings, "packet services are the operator's, not reset by the channel")
        XCTAssertTrue(r.runsPacketServices)
    }

    func testAnExistingPositionConfigIsNotReplaced() {
        var r = radio()
        r.beacon.aprs = APRSPositionConfig(useGPS: false, latitude: 1, longitude: 2)
        RadioChannel.aprs.apply(to: &r)
        XCTAssertEqual(r.beacon.aprs?.latitude, 1)
        XCTAssertFalse(r.beacon.aprs?.useGPS ?? true)
    }

    /// Settings from before channels were one or the other stay as they
    /// were; the page reports the mismatch rather than hiding it.
    func testAMismatchedBeaconFromBeforeIsReported() {
        XCTAssertFalse(RadioChannel.beaconMatchesChannel(radio(aprs: false, kind: .aprsPosition)))
        XCTAssertFalse(RadioChannel.beaconMatchesChannel(radio(aprs: true, kind: .text)))
        XCTAssertTrue(RadioChannel.beaconMatchesChannel(radio(aprs: true, kind: .aprsPosition)))
        XCTAssertTrue(RadioChannel.beaconMatchesChannel(radio(aprs: false, kind: .text)))
    }

    /// Choosing the channel through the store is one write of `aprsEnabled`
    /// (and the beacon's kind), persisted like any other radio edit.
    @MainActor
    func testTheChannelIsStoredAsAPRSEnabled() throws {
        let defaults = TestDefaults.make("RadioChannel")
        let settings = AppSettingsStore(defaults: defaults)
        let id = try XCTUnwrap(settings.activeRadios.first?.id)
        settings.updateRadio(id) { RadioChannel.aprs.apply(to: &$0) }

        let reopened = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.radio(id)?.aprsEnabled, true)
        XCTAssertEqual(RadioChannel.of(try XCTUnwrap(reopened.radio(id))), .aprs)
        XCTAssertTrue(reopened.allRadiosOnAPRS)
    }
}
