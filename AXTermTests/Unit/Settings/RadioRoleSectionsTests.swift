//
//  RadioRoleSectionsTests.swift
//  AXTermTests
//
//  Each radio's role settings are shown on the service page for its
//  channel: which radios get a section, where a link to one lands, and the
//  line the radio's own page shows for them.
//

import XCTest
@testable import AXTerm

final class RadioRoleSectionsTests: XCTestCase {

    private func radio(_ id: String, name: String = "", channel: RadioChannel,
                       enabled: Bool = true, archived: Bool = false) -> RadioProfile {
        var radio = RadioProfile(id: RadioID(rawValue: id), name: name)
        channel.apply(to: &radio)
        radio.enabled = enabled
        radio.archived = archived
        return radio
    }

    func testEachPageListsTheRadiosOnItsChannelInListOrder() {
        let radios = [
            radio("uhf", channel: .packet),
            radio("base", channel: .aprs),
            radio("old", channel: .aprs, archived: true),
            radio("spare", channel: .aprs, enabled: false),
            radio("hf", channel: .packet),
        ]
        XCTAssertEqual(RadioRoleSections.radios(on: .aprs, in: radios).map(\.id.rawValue),
                       ["base", "spare"], "a radio switched off keeps its section; an archived one does not")
        XCTAssertEqual(RadioRoleSections.radios(on: .packet, in: radios).map(\.id.rawValue),
                       ["uhf", "hf"])
    }

    func testSectionIDsAreUniquePerRadioAndPage() {
        let base = RadioID(rawValue: "base")
        XCTAssertEqual(RadioRoleSections.anchor(base, on: .aprs), "aprs.base")
        XCTAssertEqual(RadioRoleSections.anchor(base, on: .packet), "packet.base")
        XCTAssertNotEqual(RadioRoleSections.anchor(base, on: .aprs),
                          RadioRoleSections.anchor(RadioID(rawValue: "mobile"), on: .aprs))
    }

    func testALinkLandsOnTheRadioItNames() {
        let radios = [radio("base", channel: .aprs), radio("mobile", channel: .aprs)]
        XCTAssertEqual(RadioRoleSections.landing(for: RadioID(rawValue: "mobile"), among: radios, on: .aprs),
                       AnyHashable("aprs.mobile"))
    }

    func testALinkWithNoRadioOrAnotherPagesRadioLandsOnTheFirst() {
        let radios = [radio("base", channel: .aprs), radio("mobile", channel: .aprs)]
        XCTAssertEqual(RadioRoleSections.landing(for: nil, among: radios, on: .aprs),
                       AnyHashable("aprs.base"))
        XCTAssertEqual(RadioRoleSections.landing(for: RadioID(rawValue: "uhf"), among: radios, on: .aprs),
                       AnyHashable("aprs.base"))
    }

    func testALinkToAPageWithNoRadioLandsOnItsNote() {
        XCTAssertEqual(RadioRoleSections.landing(for: RadioID(rawValue: "base"), among: [], on: .aprs),
                       AnyHashable(SettingsSection.aprsRadios))
        XCTAssertEqual(RadioRoleSections.landing(for: nil, among: [], on: .packet),
                       AnyHashable(SettingsSection.packetRadios))
    }

    func testTheHeaderNamesTheRadioAndItsCallsign() {
        XCTAssertEqual(RadioRoleSections.header(for: radio("base", name: "Base", channel: .aprs),
                                                callsign: "K0EPI-9"),
                       "Base \u{00B7} K0EPI-9")
        XCTAssertEqual(RadioRoleSections.header(for: radio("base", name: "Base", channel: .aprs),
                                                callsign: ""),
                       "Base")
        XCTAssertEqual(RadioRoleSections.header(for: radio("spare", name: "Spare", channel: .aprs,
                                                           enabled: false),
                                                callsign: "K0EPI-7"),
                       "Spare \u{00B7} K0EPI-7 \u{00B7} off")
    }

    func testTheRadioPageSummarizesAnAPRSRadio() {
        var base = radio("base", channel: .aprs)
        base.aprsPath = "WIDE1-1,WIDE2-1"
        base.beacon.enabled = true
        base.beacon.intervalMinutes = 30
        XCTAssertEqual(RadioRoleSections.summary(for: base), "Beacon every 30 min, path WIDE1-1,WIDE2-1")

        base.beacon.enabled = false
        base.aprsPath = ""
        XCTAssertEqual(RadioRoleSections.summary(for: base), "Beacon off, path direct")
    }

    func testTheRadioPageSummarizesAPacketRadio() {
        var uhf = radio("uhf", channel: .packet)
        uhf.pings = false
        uhf.digi.enabled = true
        uhf.beacon.enabled = true
        uhf.beacon.intervalMinutes = 20
        XCTAssertEqual(RadioRoleSections.summary(for: uhf),
                       "On: node, mailbox, digipeater, ID beacon every 20 min")

        uhf.announcesNode = false
        uhf.answersMailbox = false
        uhf.digi.enabled = false
        uhf.beacon.enabled = false
        XCTAssertEqual(RadioRoleSections.summary(for: uhf), "All off")
    }

    /// A beacon stored as the other channel's kind is not reported as sent.
    func testTheSummarySaysWhenTheBeaconIsTheOtherChannelsKind() {
        var uhf = radio("uhf", channel: .packet)
        uhf.beacon.kind = .aprsPosition
        uhf.beacon.enabled = true
        XCTAssertTrue(RadioRoleSections.summary(for: uhf).hasSuffix("Beacon set up for an APRS channel"))
        XCTAssertFalse(RadioRoleSections.summary(for: uhf).contains("ID beacon"))
    }
}
