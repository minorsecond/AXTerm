//
//  AddRadioFlowTests.swift
//  AXTermTests
//
//  The Add Radio sheet adds a real radio from its first step, so Cancel has
//  to take it away again, and setting up an existing radio has to be undone
//  exactly. First-run setup offers itself once, to a station with no
//  callsign.
//

import XCTest
@testable import AXTerm

@MainActor
final class AddRadioFlowTests: XCTestCase {

    private func store(_ label: String, callsign: String = "K0EPI") -> AppSettingsStore {
        let settings = AppSettingsStore(defaults: TestDefaults.make(label))
        settings.myCallsign = callsign
        return settings
    }

    func testANewRadioIsAddedSwitchedOffAndUnnamed() throws {
        let settings = store("AddRadioNew")
        let before = settings.activeRadios.count
        let flow = AddRadioFlow(settings: settings, mode: .new)
        XCTAssertEqual(settings.activeRadios.count, before + 1)
        let radio = try XCTUnwrap(settings.radio(flow.radioID))
        XCTAssertFalse(radio.enabled, "nothing connects while the operator is still choosing")
        XCTAssertEqual(radio.name, "", "the default name follows the transport")
    }

    func testCancelLeavesNoRadioBehind() {
        let settings = store("AddRadioCancel")
        let before = settings.radios
        let flow = AddRadioFlow(settings: settings, mode: .new)
        flow.setChannel(.aprs)
        flow.setSSID(9)
        flow.cancel()
        XCTAssertEqual(settings.radios, before)
    }

    func testCancelAfterTheLinkCameUpArchivesInstead() throws {
        let settings = store("AddRadioCancelAfterTest")
        let flow = AddRadioFlow(settings: settings, mode: .new)
        flow.observe(.connected)
        flow.cancel()
        let radio = try XCTUnwrap(settings.radio(flow.radioID),
                                  "frames heard during the test keep a radio to name")
        XCTAssertTrue(radio.archived)
        XCTAssertFalse(radio.enabled)
        XCTAssertFalse(settings.activeRadios.contains { $0.id == flow.radioID }, "and it is in no list")
    }

    func testFinishSwitchesTheRadioOnAndKeepsIt() throws {
        let settings = store("AddRadioFinish")
        let flow = AddRadioFlow(settings: settings, mode: .new)
        flow.setChannel(.aprs)
        flow.setSSID(9)
        let id = flow.finish()
        flow.cancel()
        let radio = try XCTUnwrap(settings.radio(id))
        XCTAssertTrue(radio.enabled)
        XCTAssertFalse(radio.archived, "a cancel after finishing does nothing")
        XCTAssertTrue(radio.aprsEnabled)
        XCTAssertEqual(radio.callsign, "K0EPI-9")
    }

    func testCancellingSetupOfAnExistingRadioPutsItBack() throws {
        let settings = store("AddRadioConfigure")
        let id = try XCTUnwrap(settings.activeRadios.first?.id)
        let original = try XCTUnwrap(settings.radio(id))
        let flow = AddRadioFlow(settings: settings, mode: .configure(id))
        flow.setChannel(.aprs)
        settings.updateRadio(id) { $0.host = "10.0.0.9" }
        flow.cancel()
        XCTAssertEqual(settings.radio(id), original)
        XCTAssertEqual(settings.activeRadios.count, 1, "nothing added, nothing removed")
    }

    func testFinishingSetupOfAnExistingRadioKeepsTheChanges() throws {
        let settings = store("AddRadioConfigureFinish")
        let id = try XCTUnwrap(settings.activeRadios.first?.id)
        let flow = AddRadioFlow(settings: settings, mode: .configure(id))
        settings.updateRadio(id) { $0.host = "10.0.0.9" }
        flow.finish()
        XCTAssertEqual(settings.radio(id)?.host, "10.0.0.9")
    }

    func testTheStepsRunInOrderAndBackStopsAtTheStart() {
        let settings = store("AddRadioSteps")
        let flow = AddRadioFlow(settings: settings, mode: .new)
        XCTAssertEqual(flow.step, .connect)
        XCTAssertFalse(flow.canGoBack)
        flow.next()
        XCTAssertEqual(flow.step, .channel, "the channel decides which SSIDs to suggest")
        flow.next()
        XCTAssertEqual(flow.step, .identity)
        flow.back()
        XCTAssertEqual(flow.step, .channel)
        flow.next(); flow.next(); flow.next()
        XCTAssertEqual(flow.step, .done)
        flow.next()
        XCTAssertEqual(flow.step, .done, "nothing after Done")
        XCTAssertTrue(flow.canGoBack, "the summary can send the operator back to change something")
        flow.back()
        XCTAssertEqual(flow.step, .basics)
        flow.back(); flow.back(); flow.back()
        XCTAssertEqual(flow.step, .connect)
        flow.back()
        XCTAssertEqual(flow.step, .connect, "nothing before Connect")
        flow.cancel()
    }

    func testTestingTheLinkSwitchesTheRadioOn() {
        let settings = store("AddRadioTest")
        let flow = AddRadioFlow(settings: settings, mode: .new)
        var connected = false
        flow.testLink { connected = true }
        XCTAssertTrue(connected)
        XCTAssertEqual(settings.radio(flow.radioID)?.enabled, true)
        flow.cancel()
    }

    func testNoSSIDWithoutAStationCallsign() {
        let settings = store("AddRadioNoCall", callsign: "")
        let flow = AddRadioFlow(settings: settings, mode: .new)
        flow.setSSID(5)
        XCTAssertEqual(settings.radio(flow.radioID)?.callsign, "", "\"-5\" is not a callsign")
        flow.cancel()
    }

    // MARK: - Suggested SSIDs

    func testAPRSSuggestsTheCommonRolesFirst() {
        XCTAssertEqual(SSIDSuggestion.suggest(for: .aprs, taken: []), [0, 9, 7])
        XCTAssertEqual(SSIDSuggestion.suggest(for: .aprs, taken: [0]), [9, 7, 1],
                       "an SSID another radio has is skipped")
    }

    func testPacketSuggestsTheLowestFreeSSIDs() {
        XCTAssertEqual(SSIDSuggestion.suggest(for: .packet, taken: [0, 1]), [2, 3, 4])
    }

    func testTheOtherRadiosSSIDsAreTaken() throws {
        let settings = store("AddRadioTaken")
        let first = try XCTUnwrap(settings.activeRadios.first?.id)
        settings.updateRadio(first) { $0.callsign = "K0EPI-7" }
        let flow = AddRadioFlow(settings: settings, mode: .new)
        XCTAssertEqual(SSIDSuggestion.taken(by: settings, except: flow.radioID), [7])
        flow.cancel()
    }

    // MARK: - First-run setup

    func testFirstRunSetupOffersItselfOnceToAStationWithNoCallsign() {
        XCTAssertTrue(FirstRunSetup.offersItself(callsign: "", dismissed: false, isTestInstance: false))
        XCTAssertFalse(FirstRunSetup.offersItself(callsign: "K0EPI", dismissed: false, isTestInstance: false))
        XCTAssertFalse(FirstRunSetup.offersItself(callsign: "", dismissed: true, isTestInstance: false),
                       "skipped once, not offered again")
        XCTAssertFalse(FirstRunSetup.offersItself(callsign: "", dismissed: false, isTestInstance: true),
                       "a test instance starts empty on purpose")
    }
}
