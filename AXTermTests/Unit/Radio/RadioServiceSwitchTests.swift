//
//  RadioServiceSwitchTests.swift
//  AXTermTests
//
//  The per-radio service switches (announce the node, ping, answer the
//  mailbox, digipeat) live on the radio's page and work with one radio as
//  well as several. The service pages only say which radios they run on.
//

import XCTest
@testable import AXTerm

@MainActor
final class RadioServiceSwitchTests: XCTestCase {

    private func store(_ label: String) -> AppSettingsStore {
        AppSettingsStore(defaults: TestDefaults.make(label))
    }

    func testASingleRadioCanSwitchEachServiceOff() throws {
        let settings = store("SingleRadioServices")
        XCTAssertFalse(settings.hasMultipleRadios)
        let id = try XCTUnwrap(settings.activeRadios.first?.id)
        let fresh = try XCTUnwrap(settings.radio(id))
        XCTAssertTrue(fresh.mayPing && fresh.mayAnnounceNode && fresh.mayAnswerMailbox,
                      "one radio runs everything until told otherwise, as it always did")

        settings.updateRadio(id) {
            $0.pings = false
            $0.announcesNode = false
            $0.answersMailbox = false
            $0.digi.enabled = true
        }
        let radio = try XCTUnwrap(settings.radio(id))
        XCTAssertFalse(radio.mayPing)
        XCTAssertFalse(radio.mayAnnounceNode)
        XCTAssertFalse(radio.mayAnswerMailbox)
        XCTAssertTrue(radio.digi.enabled)
    }

    /// Ping stations switched off on the only radio means no pinging. The
    /// switch used to be ignored with one radio, when it was not shown.
    func testASingleRadiosPingSwitchIsObeyed() throws {
        let settings = store("SingleRadioPing")
        let id = try XCTUnwrap(settings.activeRadios.first?.id)
        let coordinator = SessionCoordinator()
        coordinator.appSettings = settings

        XCTAssertEqual(coordinator.serviceRadios(\.mayPing), [id])
        settings.updateRadio(id) { $0.pings = false }
        XCTAssertEqual(coordinator.serviceRadios(\.mayPing), [])
        settings.updateRadio(id) {
            $0.pings = true
            RadioChannel.aprs.apply(to: &$0)
        }
        XCTAssertEqual(coordinator.serviceRadios(\.mayPing), [], "an APRS channel is no place for ping")
    }

    /// APRS messages go out on the one radio a single-radio station has,
    /// whatever its channel, as they always did; with several, only on APRS
    /// channels. The engine and the APRS page read the same rule.
    func testWhichRadiosCarryAPRSMessages() {
        let base = RadioProfile(id: RadioID(rawValue: "a"), name: "Base")
        var v8 = RadioProfile(id: RadioID(rawValue: "b"), name: "IC-V8")
        v8.aprsEnabled = true
        XCTAssertEqual(RadioChannel.aprsRadios(in: [base]).map(\.id), [base.id])
        XCTAssertEqual(ServiceRadios.aprs([base]), ["Base"])
        XCTAssertEqual(RadioChannel.aprsRadios(in: [base, v8]).map(\.id), [v8.id])
        XCTAssertEqual(ServiceRadios.aprs([base, v8]), ["IC-V8"])
    }

    func testTheServicePagesNameTheRadiosTheyRunOn() {
        var base = RadioProfile(id: RadioID(rawValue: "a"), name: "Base")
        var aprs = RadioProfile(id: RadioID(rawValue: "b"), name: "IC-705")
        var off = RadioProfile(id: RadioID(rawValue: "c"), name: "Spare")
        base.pings = true
        aprs.aprsEnabled = true
        off.enabled = false

        let radios = [base, aprs, off]
        XCTAssertEqual(ServiceRadios.names(radios) { $0.mayPing }, ["Base"],
                       "an APRS radio and a radio that is off ping nobody")
        XCTAssertEqual(ServiceRadios.aprs(radios), ["IC-705"])
        XCTAssertEqual(ServiceRadios.mailbox(radios), ["Base"])
        XCTAssertEqual(ServiceRadios.names([base]) { $0.mayAnnounceNode }, ["Base"],
                       "one radio is named too")
    }

    func testAnUnnamedRadioIsNamedForItsTransport() {
        var radio = RadioProfile(id: RadioID(rawValue: "a"), name: "")
        radio.kind = .tcp
        XCTAssertEqual(ServiceRadios.names([radio]) { _ in true }, ["Direwolf"])
    }

    func testTheFooterSaysWhenTheStationHasAServiceOff() {
        let radio = RadioProfile(id: RadioID(rawValue: "a"), name: "Base")
        let allOn = RadioServiceNotes.packetFooter(radio: radio, advertises: true, pingEnabled: true)
        XCTAssertFalse(allOn.contains("Packet Node"))

        let bothOff = RadioServiceNotes.packetFooter(radio: radio, advertises: false, pingEnabled: false)
        XCTAssertTrue(bothOff.contains("does not announce"), bothOff)
        XCTAssertTrue(bothOff.contains("ping is off"), bothOff)
        XCTAssertTrue(bothOff.contains("Packet Node"), bothOff)

        var quiet = radio
        quiet.pings = false
        let pingOffHere = RadioServiceNotes.packetFooter(radio: quiet, advertises: true, pingEnabled: false)
        XCTAssertFalse(pingOffHere.contains("ping is off"),
                       "nothing to warn about when this radio does not ping either")
    }
}
