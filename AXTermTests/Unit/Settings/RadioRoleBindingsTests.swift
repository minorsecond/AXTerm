//
//  RadioRoleBindingsTests.swift
//  AXTermTests
//
//  The controls on the APRS and Packet Node pages write one radio's
//  settings. These check each binding against a real settings store: what
//  it reads, what it writes, that it cleans up what the operator types, and
//  that a write to one radio leaves the others alone.
//

import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class RadioRoleBindingsTests: XCTestCase {

    private var settings: AppSettingsStore!
    private var first: RadioID!
    private var second: RadioID!

    override func setUp() {
        super.setUp()
        settings = AppSettingsStore(defaults: TestDefaults.make("RadioRoleBindingsTests-\(name)"))
        first = settings.activeRadios.first!.id
        second = settings.addRadio().id
    }

    override func tearDown() {
        settings = nil
        super.tearDown()
    }

    private func bindings(_ id: RadioID) -> RadioRoleBindings {
        RadioRoleBindings(radioID: id, settings: settings)
    }

    private func profile(_ id: RadioID) -> RadioProfile {
        settings.radio(id)!
    }

    // MARK: APRS path

    func testThePathIsStoredUppercase() {
        bindings(first).aprsPath.wrappedValue = "wide1-1,wide2-1"
        XCTAssertEqual(profile(first).aprsPath, "WIDE1-1,WIDE2-1")
        XCTAssertEqual(bindings(first).aprsPath.wrappedValue, "WIDE1-1,WIDE2-1")
    }

    func testAnEmptyPathIsStoredAsDirectAndNotAsMissing() {
        settings.updateRadio(first) { RadioChannel.aprs.apply(to: &$0) }
        bindings(first).aprsPath.wrappedValue = ""
        XCTAssertEqual(profile(first).aprsPath, "", "empty means direct and must survive a reload")
        XCTAssertEqual(bindings(first).aprsPath.wrappedValue, "")
    }

    func testAnOlderBuildsBeaconPathIsReadUntilAPathIsSet() {
        settings.updateRadio(first) {
            $0.aprsPath = nil
            $0.aprsEnabled = true
            $0.beacon.kind = .aprsPosition
            $0.beacon.path = "WIDE2-2"
        }
        XCTAssertEqual(bindings(first).aprsPath.wrappedValue, "WIDE2-2",
                       "an upgrade must not silently shorten the station's reach")
        bindings(first).aprsPath.wrappedValue = "WIDE1-1"
        XCTAssertEqual(bindings(first).aprsPath.wrappedValue, "WIDE1-1")
        XCTAssertEqual(profile(first).beacon.path, "WIDE2-2", "the old field is left as it was")
    }

    func testAPathForOneRadioLeavesTheOtherAlone() {
        let before = profile(second).aprsPath
        bindings(first).aprsPath.wrappedValue = "WIDE1-1"
        XCTAssertEqual(profile(second).aprsPath, before)
    }

    // MARK: Beacon

    func testBeaconFieldsWriteOnlyTheirRadio() {
        bindings(first).beacon(\.enabled).wrappedValue = true
        bindings(first).beacon(\.intervalMinutes).wrappedValue = 45
        XCTAssertTrue(profile(first).beacon.enabled)
        XCTAssertEqual(profile(first).beacon.intervalMinutes, 45)
        XCTAssertFalse(profile(second).beacon.enabled)
        XCTAssertNotEqual(profile(second).beacon.intervalMinutes, 45)
    }

    func testBeaconTextAndViaAreStoredAsTyped() {
        bindings(first).beacon(\.text).wrappedValue = "K0EPI node, Centennial"
        bindings(first).beacon(\.path).wrappedValue = "DRLNOD"
        XCTAssertEqual(profile(first).beacon.text, "K0EPI node, Centennial")
        XCTAssertEqual(profile(first).beacon.path, "DRLNOD")
    }

    func testAMissingRadioReadsDefaultsAndIgnoresWrites() {
        let ghost = RadioID(rawValue: "no-such-radio")
        let b = bindings(ghost)
        XCTAssertEqual(b.beacon(\.intervalMinutes).wrappedValue, BeaconConfig().intervalMinutes)
        XCTAssertEqual(b.aprsPath.wrappedValue, "")
        XCTAssertEqual(b.overlay.wrappedValue, "")
        XCTAssertEqual(b.digiAliases.wrappedValue, "")
        let count = settings.radios.count
        b.beacon(\.enabled).wrappedValue = true
        b.aprsPath.wrappedValue = "WIDE1-1"
        b.digiAliases.wrappedValue = "CLUB"
        XCTAssertEqual(settings.radios.count, count, "a write must not create a radio")
        XCTAssertNil(settings.radio(ghost))
    }

    // MARK: APRS position config

    func testAnUnsetPositionConfigReadsTheDefaultGiven() {
        settings.updateRadio(first) { $0.beacon.aprs = nil }
        XCTAssertEqual(bindings(first).aprs(\.comment, default: "none").wrappedValue, "none")
        XCTAssertEqual(bindings(first).aprs(\.ambiguityDigits, default: 3).wrappedValue, 3)
    }

    func testTheFirstWriteCreatesAConfigThatFollowsTheStation() {
        settings.updateRadio(first) { $0.beacon.aprs = nil }
        bindings(first).aprs(\.comment, default: "").wrappedValue = "Portable"
        let aprs = profile(first).beacon.aprs
        XCTAssertEqual(aprs?.comment, "Portable")
        XCTAssertEqual(aprs?.useGPS, APRSPositionConfig.followingStation.useGPS)
        XCTAssertEqual(aprs?.symbolCode, APRSPositionConfig.followingStation.symbolCode)
    }

    func testAPositionFieldWriteKeepsTheOtherFields() {
        settings.updateRadio(first) {
            $0.beacon.aprs = .followingStation
            $0.beacon.aprs?.comment = "Keep me"
        }
        bindings(first).aprs(\.compressed, default: false).wrappedValue = true
        XCTAssertEqual(profile(first).beacon.aprs?.comment, "Keep me")
        XCTAssertEqual(profile(first).beacon.aprs?.compressed, true)
    }

    // MARK: Overlay

    func testThePrimaryAndAlternateTablesShowNoOverlay() {
        for table in ["/", "\\"] {
            settings.updateRadio(first) {
                $0.beacon.aprs = .followingStation
                $0.beacon.aprs?.symbolTable = table
            }
            XCTAssertEqual(bindings(first).overlay.wrappedValue, "", table)
        }
    }

    func testAnOverlayIsOneUppercaseCharacter() {
        settings.updateRadio(first) { $0.beacon.aprs = .followingStation }
        bindings(first).overlay.wrappedValue = "s"
        XCTAssertEqual(profile(first).beacon.aprs?.symbolTable, "S")
        XCTAssertEqual(bindings(first).overlay.wrappedValue, "S")

        bindings(first).overlay.wrappedValue = "abc"
        XCTAssertEqual(profile(first).beacon.aprs?.symbolTable, "A", "only the first character counts")

        bindings(first).overlay.wrappedValue = "7"
        XCTAssertEqual(profile(first).beacon.aprs?.symbolTable, "7")
    }

    func testClearingTheOverlayReturnsToTheAlternateTable() {
        settings.updateRadio(first) {
            $0.beacon.aprs = .followingStation
            $0.beacon.aprs?.symbolTable = "S"
        }
        for cleared in ["", "/", "\\"] {
            bindings(first).overlay.wrappedValue = cleared
            XCTAssertEqual(profile(first).beacon.aprs?.symbolTable, "\\", "cleared with \(cleared)")
        }
    }

    // MARK: Coordinates

    func testCoordinatesParseWhatTheOperatorTypes() {
        let lat = bindings(first).coordString(\.latitude)
        lat.wrappedValue = "39.5"
        XCTAssertEqual(profile(first).beacon.aprs?.latitude, 39.5)
        lat.wrappedValue = "  -105.25  "
        XCTAssertEqual(profile(first).beacon.aprs?.latitude, -105.25)
        XCTAssertEqual(lat.wrappedValue, "-105.25")
    }

    func testAnUnreadableCoordinateClearsIt() {
        let lon = bindings(first).coordString(\.longitude)
        lon.wrappedValue = "-104.9"
        for junk in ["", "abc", "39,5", "--1"] {
            lon.wrappedValue = "-104.9"
            lon.wrappedValue = junk
            XCTAssertNil(profile(first).beacon.aprs?.longitude, "\(junk) must not keep the old value")
            XCTAssertEqual(lon.wrappedValue, "")
        }
    }

    // MARK: Services

    func testServiceSwitchesWriteTheirOwnField() {
        let b = bindings(first)
        b.service(\.announcesNode).wrappedValue = false
        b.service(\.pings).wrappedValue = true
        b.service(\.answersMailbox).wrappedValue = false
        XCTAssertFalse(profile(first).announcesNode)
        XCTAssertTrue(profile(first).pings)
        XCTAssertFalse(profile(first).answersMailbox)

        b.service(\.announcesNode).wrappedValue = true
        XCTAssertTrue(profile(first).announcesNode)
        XCTAssertTrue(profile(first).pings, "switching one service does not touch another")
        XCTAssertFalse(profile(first).answersMailbox)
    }

    func testAServiceOnAMissingRadioReadsOn() {
        XCTAssertTrue(bindings(RadioID(rawValue: "gone")).service(\.pings).wrappedValue)
    }

    func testTheNodeAliasIsStoredUppercase() {
        bindings(first).netRomAlias.wrappedValue = "epinod"
        XCTAssertEqual(profile(first).netRomAlias, "EPINOD")
        bindings(first).netRomAlias.wrappedValue = ""
        XCTAssertEqual(profile(first).netRomAlias, "", "empty falls back to the station alias")
    }

    // MARK: Digipeater

    func testDigipeaterFieldsWriteOnlyTheirRadio() {
        let b = bindings(first)
        b.digi(\.enabled).wrappedValue = true
        b.digi(\.fillIn).wrappedValue = true
        b.digi(\.wideAreaMaxHops).wrappedValue = 2
        b.digi(\.dupeSeconds).wrappedValue = 45
        let digi = profile(first).digi
        XCTAssertTrue(digi.enabled)
        XCTAssertTrue(digi.fillIn)
        XCTAssertEqual(digi.wideAreaMaxHops, 2)
        XCTAssertEqual(digi.dupeSeconds, 45)
        XCTAssertFalse(profile(second).digi.enabled, "digipeating is off unless switched on per radio")
    }

    func testDigipeaterAliasesSplitOnCommasAndSpaces() {
        let aliases = bindings(first).digiAliases
        aliases.wrappedValue = "club, wide1 ,  drl"
        XCTAssertEqual(profile(first).digi.aliases, ["CLUB", "WIDE1", "DRL"])
        XCTAssertEqual(aliases.wrappedValue, "CLUB, WIDE1, DRL")

        aliases.wrappedValue = "a b,,c"
        XCTAssertEqual(profile(first).digi.aliases, ["A", "B", "C"], "empty pieces are dropped")

        aliases.wrappedValue = "  ,  "
        XCTAssertEqual(profile(first).digi.aliases, [])
        XCTAssertEqual(aliases.wrappedValue, "")
    }

    // MARK: A radio changing channel

    func testSettingsSetOnOnePageComeBackWhenTheRadioReturnsToIt() {
        settings.updateRadio(first) { RadioChannel.aprs.apply(to: &$0) }
        bindings(first).aprsPath.wrappedValue = "WIDE2-1"
        bindings(first).aprs(\.comment, default: "").wrappedValue = "Home"

        settings.updateRadio(first) { RadioChannel.packet.apply(to: &$0) }
        bindings(first).digi(\.enabled).wrappedValue = true
        XCTAssertEqual(RadioRoleSections.radios(on: .packet, in: settings.activeRadios).map(\.id).first { $0 == first },
                       first)
        XCTAssertFalse(RadioRoleSections.radios(on: .aprs, in: settings.activeRadios).contains { $0.id == first })

        settings.updateRadio(first) { RadioChannel.aprs.apply(to: &$0) }
        XCTAssertEqual(bindings(first).aprsPath.wrappedValue, "WIDE2-1", "the path was kept")
        XCTAssertEqual(profile(first).beacon.aprs?.comment, "Home", "the beacon was kept")
        XCTAssertTrue(profile(first).digi.enabled, "packet settings are kept too, just not shown")
    }
}
