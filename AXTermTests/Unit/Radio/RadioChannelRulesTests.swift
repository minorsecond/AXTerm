import XCTest
@testable import AXTerm

/// A radio is on APRS or on Packet, and only that channel's settings act.
///
/// Settings are stored per radio and kept across a switch, so a digipeater
/// set up for APRS (fill-in WIDE1-1) kept answering WIDE1-1 after the IC-705
/// moved to the packet test frequency, and the Packet Node page showed the
/// fill-in switch (operator, 2026-10-10).
final class RadioChannelRulesTests: XCTestCase {

    private func radio(_ channel: RadioChannel, id: String = "r") -> RadioProfile {
        var r = RadioProfile(id: RadioID(rawValue: id), name: id)
        r.enabled = true
        r.callsign = "K0EPI-2"
        r.digi = DigiConfig(enabled: true, fillIn: true, wideAreaMaxHops: 2,
                            aliases: ["EPINOD"], dupeSeconds: 30)
        channel.apply(to: &r)
        return r
    }

    // MARK: Digipeater

    /// On Packet the digipeater repeats by call or alias only: no WIDEn-N,
    /// and no dupe window, which would drop a connected station's retry of a
    /// frame its peer did not acknowledge.
    func testAPacketDigipeaterRepeatsOnlyByCall() {
        let digi = radio(.packet).effectiveDigi
        XCTAssertTrue(digi.enabled)
        XCTAssertEqual(digi.aliases, ["EPINOD"])
        XCTAssertFalse(digi.fillIn)
        XCTAssertEqual(digi.wideAreaMaxHops, 0)
        XCTAssertEqual(digi.dupeSeconds, 0)
    }

    func testAnAPRSDigipeaterKeepsItsRules() {
        XCTAssertEqual(radio(.aprs).effectiveDigi, radio(.aprs).digi)
    }

    /// Nothing is thrown away: switching back to APRS brings the APRS rules
    /// back as they were.
    func testTheStoredRulesSurviveASwitch() {
        var r = radio(.aprs)
        RadioChannel.packet.apply(to: &r)
        XCTAssertTrue(r.digi.fillIn)
        RadioChannel.aprs.apply(to: &r)
        XCTAssertTrue(r.effectiveDigi.fillIn)
        XCTAssertEqual(r.effectiveDigi.wideAreaMaxHops, 2)
    }

    /// End to end through the repeat rule: on Packet a WIDE1-1 frame is left
    /// alone and a frame sent via our call is repeated.
    func testThePacketDigipeaterOnTheAir() {
        let digi = radio(.packet).effectiveDigi
        let me = AX25Address(call: "K0EPI", ssid: 2)
        func address(_ call: String, ssid: UInt8, last: Bool) -> Data {
            var bytes = Data(call.padding(toLength: 6, withPad: " ", startingAt: 0).utf8.map { $0 << 1 })
            bytes.append(0x60 | (ssid << 1) | (last ? 0x01 : 0))
            return bytes
        }
        func frame(via call: String, ssid: UInt8) -> Data {
            var raw = address("APRS", ssid: 0, last: false)
            raw.append(address("K0PWO", ssid: 0, last: false))
            raw.append(address(call, ssid: ssid, last: true))
            raw.append(contentsOf: [0x03, 0xF0])
            raw.append(Data("!3953.70N/10505.14W>x".utf8))
            return raw
        }
        XCTAssertNil(AX25Digipeater.repeatFrame(frame(via: "WIDE1", ssid: 1),
                                                myCall: me, aliases: digi.aliases,
                                                fillIn: digi.fillIn, wideAreaMaxHops: digi.wideAreaMaxHops))
        XCTAssertNotNil(AX25Digipeater.repeatFrame(frame(via: "K0EPI", ssid: 2), myCall: me, aliases: digi.aliases,
                                                   fillIn: digi.fillIn, wideAreaMaxHops: digi.wideAreaMaxHops))
    }

    /// What the digipeater section shows for each channel.
    func testTheDigipeaterSectionShowsOnlyItsChannelsRows() {
        XCTAssertEqual(DigipeaterRows.rows(for: .packet), [.enabled, .aliases])
        XCTAssertEqual(DigipeaterRows.rows(for: .aprs), [.enabled, .fillIn, .wideArea, .aliases, .dupeWindow])
    }

    // MARK: APRS transmissions

    /// A lone radio on Packet sends nothing APRS. It used to carry APRS
    /// messages whatever its channel.
    func testALonePacketRadioCarriesNoAPRS() {
        XCTAssertTrue(RadioChannel.aprsRadios(in: [radio(.packet)]).isEmpty)
        XCTAssertEqual(RadioChannel.aprsRadios(in: [radio(.aprs)]).map(\.id.rawValue), ["r"])
    }

    func testOnlyAPRSRadiosCarryAPRS() {
        let radios = [radio(.packet, id: "705"), radio(.aprs, id: "id50")]
        XCTAssertEqual(RadioChannel.aprsRadios(in: radios).map(\.id.rawValue), ["id50"])
    }

    /// An ack or answer goes out the radio that heard the message only when
    /// that radio is on APRS; a message heard on a packet channel gets none.
    func testARepliesOnlyOnAnAPRSRadio() {
        let aprs = [RadioID(rawValue: "id50")]
        XCTAssertEqual(APRSRadioChoice.replyRadio(named: "id50", aprsRadios: aprs)?.rawValue, "id50")
        XCTAssertNil(APRSRadioChoice.replyRadio(named: "705", aprsRadios: aprs))
    }

    // MARK: Beacons

    /// A beacon set up for the other channel is not sent: no position report
    /// on Packet, no ID beacon to BEACON on APRS.
    func testABeaconGoesOutOnlyOnItsChannel() {
        var packet = radio(.packet)
        packet.beacon.enabled = true
        XCTAssertTrue(packet.sendsBeacon)
        packet.beacon.kind = .aprsPosition
        XCTAssertFalse(packet.sendsBeacon)

        var aprs = radio(.aprs)
        aprs.beacon.enabled = true
        XCTAssertTrue(aprs.sendsBeacon)
        aprs.beacon.kind = .text
        XCTAssertFalse(aprs.sendsBeacon)
    }

    // MARK: ID beacon

    /// An empty ID beacon offers words built from the station, rather than a
    /// warning: the station's call, its node alias and its mailbox.
    func testTheIDBeaconSuggestsWhatTheStationIs() {
        XCTAssertEqual(IDBeaconSuggestion.text(callsign: "K0EPI-2", nodeAlias: "EPINOD", mailbox: "K0EPI-4"),
                       "K0EPI-2 \u{00B7} node EPINOD \u{00B7} mailbox K0EPI-4")
        XCTAssertEqual(IDBeaconSuggestion.text(callsign: "K0EPI-2", nodeAlias: "", mailbox: nil), "K0EPI-2")
    }
}
