import XCTest
@testable import AXTerm

/// Whether a radio carries APRS is the operator's switch, not a side effect of
/// the beacon's Type.
///
/// `handlesAPRS` used to read `aprsEnabled || beacon.kind == .aprsPosition`.
/// The inference was convenient and invisible: switching the beacon back to
/// text silently stopped scoping APRS messaging and the reachability flood to
/// the radio, from a control that says nothing about either. It survives as a
/// one-time seed so the switch still lands in the right place by itself.
@MainActor
final class APRSChannelSeedTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AXTermTests.APRSSeed.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func radio(aprsEnabled: Bool, beacon kind: BeaconKind) -> RadioProfile {
        var profile = RadioProfile(id: RadioID(rawValue: UUID().uuidString), name: "r")
        profile.aprsEnabled = aprsEnabled
        profile.beacon.kind = kind
        return profile
    }

    // MARK: - The coupling is gone

    func testAnAPRSBeaconNoLongerDecidesTheChannel() {
        XCTAssertFalse(radio(aprsEnabled: false, beacon: .aprsPosition).handlesAPRS)
    }

    func testTheSwitchAloneDecidesIt() {
        XCTAssertTrue(radio(aprsEnabled: true, beacon: .text).handlesAPRS)
        XCTAssertFalse(radio(aprsEnabled: false, beacon: .text).handlesAPRS)
    }

    // MARK: - The seed that replaces it

    func testAStationAlreadyBeaconingAPRSKeepsItsChannelOnUpgrade() {
        var radios = [radio(aprsEnabled: false, beacon: .aprsPosition)]
        XCTAssertTrue(AppSettingsStore.seedAPRSFromBeacon(&radios, defaults: defaults))
        XCTAssertTrue(radios[0].aprsEnabled)
        XCTAssertTrue(radios[0].handlesAPRS)
    }

    func testARadioWithATextBeaconIsLeftAlone() {
        var radios = [radio(aprsEnabled: false, beacon: .text)]
        XCTAssertFalse(AppSettingsStore.seedAPRSFromBeacon(&radios, defaults: defaults))
        XCTAssertFalse(radios[0].aprsEnabled)
    }

    func testTheSeedRunsOnce() {
        var radios = [radio(aprsEnabled: false, beacon: .aprsPosition)]
        XCTAssertTrue(AppSettingsStore.seedAPRSFromBeacon(&radios, defaults: defaults))

        // The operator's later decision must survive a relaunch.
        radios[0].aprsEnabled = false
        XCTAssertFalse(AppSettingsStore.seedAPRSFromBeacon(&radios, defaults: defaults))
        XCTAssertFalse(radios[0].aprsEnabled,
                       "the seed reached back over a choice the operator had made")
    }

    func testSeedingReportsNoChangeWhenTheSwitchIsAlreadyOn() {
        var radios = [radio(aprsEnabled: true, beacon: .aprsPosition)]
        XCTAssertFalse(AppSettingsStore.seedAPRSFromBeacon(&radios, defaults: defaults))
        XCTAssertTrue(radios[0].aprsEnabled)
    }

    func testEachRadioIsSeededOnItsOwnEvidence() {
        var radios = [radio(aprsEnabled: false, beacon: .aprsPosition),
                      radio(aprsEnabled: false, beacon: .text)]
        XCTAssertTrue(AppSettingsStore.seedAPRSFromBeacon(&radios, defaults: defaults))
        XCTAssertTrue(radios[0].handlesAPRS)
        XCTAssertFalse(radios[1].handlesAPRS)
    }
}

/// What may not run on an APRS channel. A shared beacon frequency carries every
/// position report for hundreds of miles; a node broadcast, a mailbox answering
/// calls, a ping or a probe for a protocol nobody else implements all take
/// airtime from the one thing the channel is for.
final class APRSChannelServiceGuardTests: XCTestCase {

    private func packetRadio() -> RadioProfile {
        var profile = RadioProfile(id: RadioID(rawValue: UUID().uuidString), name: "r")
        profile.pings = true
        profile.announcesNode = true
        profile.answersMailbox = true
        return profile
    }

    func testAPacketRadioRunsItsServices() {
        let radio = packetRadio()
        XCTAssertTrue(radio.runsPacketServices)
        XCTAssertTrue(radio.mayPing)
        XCTAssertTrue(radio.mayAnnounceNode)
        XCTAssertTrue(radio.mayAnswerMailbox)
    }

    func testAnAPRSRadioRunsNoneOfThem() {
        var radio = packetRadio()
        radio.aprsEnabled = true
        XCTAssertFalse(radio.runsPacketServices)
        XCTAssertFalse(radio.mayPing)
        XCTAssertFalse(radio.mayAnnounceNode)
        XCTAssertFalse(radio.mayAnswerMailbox)
    }

    func testTheSwitchesAreGuardedRatherThanCleared() {
        var radio = packetRadio()
        radio.aprsEnabled = true
        // The operator's choices are still on record...
        XCTAssertTrue(radio.pings)
        XCTAssertTrue(radio.announcesNode)
        XCTAssertTrue(radio.answersMailbox)
        // ...and come back when the radio leaves the APRS channel.
        radio.aprsEnabled = false
        XCTAssertTrue(radio.mayPing)
        XCTAssertTrue(radio.mayAnnounceNode)
        XCTAssertTrue(radio.mayAnswerMailbox)
    }

    func testAServiceSwitchedOffStaysOffWhenAPRSIsSwitchedOff() {
        var radio = packetRadio()
        radio.answersMailbox = false
        radio.aprsEnabled = true
        radio.aprsEnabled = false
        XCTAssertFalse(radio.mayAnswerMailbox)
    }

    func testDigipeatingIsNotGuarded() {
        // Fill-in digipeating is ordinary and wanted on APRS; it is the one
        // packet-shaped service that belongs on a beacon channel.
        var radio = packetRadio()
        radio.aprsEnabled = true
        radio.digi.enabled = true
        XCTAssertTrue(radio.digi.enabled)
    }
}
