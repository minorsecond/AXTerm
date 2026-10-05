//
//  StationServicesTests.swift
//  AXTermTests
//
//  The station answers callers whether or not a window is open.
//
//  Smoke run 2026-10-03-1, issue 46: B (ID-50), relaunched with only its
//  Settings window open and the TNC4 connected, logged A (705)'s XID and
//  eight SABMs and answered none, then answered the next SABM seconds after
//  File > New opened its main window. The window built the session
//  coordinator and the mailbox, and ran the mailbox attach and the
//  service-address sync, so a launch that restored no window (test mode, or
//  a menu-bar station) heard callers and stayed silent.
//

#if os(macOS)
import XCTest
@testable import AXTerm

@MainActor
final class StationServicesTests: XCTestCase {

    private var savedCoordinator: SessionCoordinator?

    override func setUp() {
        super.setUp()
        savedCoordinator = SessionCoordinator.shared
        SessionCoordinator.shared = nil
    }

    override func tearDown() {
        SessionCoordinator.shared = savedCoordinator
        savedCoordinator = nil
        super.tearDown()
    }

    private struct Parts {
        let settings: AppSettingsStore
        let client: PacketEngine
        let winlink: WinlinkContext
        let bbsSettings: BBSSettings
    }

    private func parts(_ label: String, mailboxOnAir: Bool = false) -> Parts {
        let defaults = TestDefaults.make(label)
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "K0EPI"
        // Switched off and pointed nowhere: nothing here opens a link.
        for radio in settings.radios {
            settings.updateRadio(radio.id) {
                $0.enabled = false
                $0.host = "127.0.0.1"
                $0.port = 9
            }
        }
        let winlink = WinlinkContext(
            store: nil,
            settings: WinlinkSettings(defaults: defaults,
                                      keychain: KeychainStore(service: "test-\(UUID().uuidString)")),
            profile: StationProfile(defaults: defaults))
        let bbs = BBSSettings(defaults: defaults)
        // Its own SSID, so the station's address alone does not answer for it.
        bbs.callsign = "K0EPI-5"
        bbs.onAir = mailboxOnAir
        return Parts(settings: settings, client: PacketEngine(settings: settings),
                     winlink: winlink, bbsSettings: bbs)
    }

    private func services(_ p: Parts) -> StationServices {
        StationServices(client: p.client, settings: p.settings,
                        winlinkContext: p.winlink, bbsSettings: p.bbsSettings)
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testWithNoWindowTheStationAnswersACaller() throws {
        let p = parts("StationNoWindow")
        let station = services(p)
        defer { station.stop() }

        XCTAssertTrue(SessionCoordinator.shared === station.coordinator)
        XCTAssertTrue(station.coordinator.packetEngine === p.client, "wired to the engine's frames")
        XCTAssertEqual(station.coordinator.localCallsign, p.settings.primaryCallsign)

        let caller = AX25Address(call: "K0EPI", ssid: 2)
        let local = CallsignNormalizer.toAddress(p.settings.primaryCallsign)
        let answer = station.coordinator.sessionManager.handleInboundSABM(
            from: caller, to: local, path: DigiPath(), radio: .primary)
        XCTAssertEqual(answer?.frameType, "u", "UA")
        XCTAssertEqual(station.coordinator.connectedSessions.count, 1)
    }

    func testWithNoWindowTheMailboxAnswersOnItsAddress() {
        let p = parts("StationNoWindowMailbox", mailboxOnAir: true)
        let station = services(p)
        defer { station.stop() }
        let mailbox = CallsignNormalizer.toAddress(station.bbsService.answeringCallsign)
        XCTAssertTrue(station.coordinator.sessionManager.answers(mailbox),
                      "the mailbox's address is registered at launch")
    }

    /// Smoke run 2026-10-03-1, issue 61: B (ID-50) said "Armed" for
    /// inbound Winlink calls, accepted A (705)'s link and never greeted it,
    /// because the listener was attached by the Mail page, which had not
    /// been opened since launch. The station attaches it.
    func testWithNoWindowTheWinlinkListenerIsAttached() {
        let p = parts("StationNoWindowWinlink")
        let station = services(p)
        defer { station.stop() }
        XCTAssertNotNil(station.coordinator.onInboundSessionConnected,
                        "inbound calls reach the Winlink listener with no Mail page open")
    }

    func testWithNoWindowSettingsChangesReachTheStation() {
        let p = parts("StationNoWindowFollow")
        let station = services(p)
        defer { station.stop() }

        p.settings.myCallsign = "K0EPJ"
        spin()
        XCTAssertEqual(station.coordinator.localCallsign, p.settings.primaryCallsign)
        XCTAssertTrue(station.coordinator.localCallsign.hasPrefix("K0EPJ"))

        p.bbsSettings.onAir = true
        spin()
        let mailbox = CallsignNormalizer.toAddress(station.bbsService.answeringCallsign)
        XCTAssertTrue(station.coordinator.sessionManager.answers(mailbox),
                      "putting the mailbox on air registers its address with no window open")

        p.bbsSettings.onAir = false
        spin()
        XCTAssertFalse(station.coordinator.sessionManager.answers(mailbox))
    }
}
#endif
