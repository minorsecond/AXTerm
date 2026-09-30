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

    func testAnUnnamedRadioIsHeadedWithTheNameTheAppGivesIt() {
        var direwolf = radio("dw", channel: .packet)
        direwolf.kind = .tcp
        XCTAssertEqual(RadioRoleSections.header(for: direwolf, callsign: "K0EPI-7"),
                       "\(RadioDetailView.title(for: direwolf)) \u{00B7} K0EPI-7")
        XCTAssertFalse(RadioDetailView.title(for: direwolf).isEmpty)
    }

    /// Every combination of the four services and the ID beacon: the summary
    /// names exactly the ones that are on, in the page's order.
    func testThePacketSummaryNamesExactlyTheServicesThatAreOn() {
        let names = ["node", "ping", "mailbox", "digipeater", "ID beacon every 25 min"]
        for mask in 0..<(1 << names.count) {
            var uhf = radio("uhf", channel: .packet)
            uhf.announcesNode = mask & 1 != 0
            uhf.pings = mask & 2 != 0
            uhf.answersMailbox = mask & 4 != 0
            uhf.digi.enabled = mask & 8 != 0
            uhf.beacon.enabled = mask & 16 != 0
            uhf.beacon.intervalMinutes = 25
            let on = names.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            XCTAssertEqual(RadioRoleSections.summary(for: uhf),
                           on.isEmpty ? "All off" : "On: " + on.joined(separator: ", "), "mask \(mask)")
        }
    }

    func testAnAPRSRadioWithAPacketBeaconSaysSo() {
        var base = radio("base", channel: .aprs)
        base.aprsPath = "WIDE1-1"
        base.beacon.kind = .text
        base.beacon.enabled = true
        XCTAssertEqual(RadioRoleSections.summary(for: base),
                       "Beacon set up for a packet channel, path WIDE1-1")
    }

    func testTheSummaryShowsAnOlderBuildsBeaconPath() {
        var base = radio("base", channel: .aprs)
        base.aprsPath = nil
        base.beacon.path = "WIDE2-2"
        XCTAssertTrue(RadioRoleSections.summary(for: base).hasSuffix("path WIDE2-2"))
    }

    /// Many radios with awkward ids: every section id is distinct, and a link
    /// always lands on one of them or on the page's note.
    func testSectionIDsStayDistinctAndLinksAlwaysLand() {
        let ids = (0..<40).map { "r\($0)" } + ["", "a.b", "aprs", "packet", "\u{00E9}", "x y"]
        let radios = ids.enumerated().map { index, id in
            radio(id, channel: index % 3 == 0 ? .packet : .aprs,
                  enabled: index % 5 != 0, archived: index % 7 == 0)
        }
        for channel in RadioChannel.allCases {
            let listed = RadioRoleSections.radios(on: channel, in: radios)
            XCTAssertFalse(listed.contains { $0.archived })
            XCTAssertTrue(listed.allSatisfy { RadioChannel.of($0) == channel })
            let anchors = listed.map { RadioRoleSections.anchor($0.id, on: channel) }
            XCTAssertEqual(Set(anchors).count, anchors.count, "\(channel) ids collide")
            let valid = Set(anchors.map(AnyHashable.init))
            for target in ids.map({ RadioID(rawValue: $0) }) + [nil] {
                let landing = RadioRoleSections.landing(for: target, among: listed, on: channel)
                XCTAssertTrue(valid.contains(landing) || (listed.isEmpty
                              && landing == AnyHashable(channel == .aprs ? SettingsSection.aprsRadios
                                                                         : .packetRadios)),
                              "\(String(describing: target)) on \(channel)")
            }
        }
        let aprs = Set(RadioRoleSections.radios(on: .aprs, in: radios).map(\.id))
        let packet = Set(RadioRoleSections.radios(on: .packet, in: radios).map(\.id))
        XCTAssertTrue(aprs.isDisjoint(with: packet), "a radio is on one page, never both")
        XCTAssertEqual(aprs.count + packet.count, radios.filter { !$0.archived }.count,
                       "every radio still in use is on one page")
    }
}
