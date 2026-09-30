//
//  MainWindowServicesTests.swift
//  AXTermTests
//
//  The main window's services are built once per window. ContentView's
//  initializer runs every time AXTermApp's body does, which is every time a
//  setting publishes, and it used to build a new BBS file library, callsign
//  lookup service and mailbox each time and re-wire the session coordinator:
//  new packet subscription, restarted APRS retry timer, re-armed NET/ROM
//  broadcast timer. These count the builds.
//

#if os(macOS)
import AppKit
import OSLog
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class MainWindowServicesTests: XCTestCase {

    private struct Station {
        let defaults: UserDefaults
        let settings: AppSettingsStore
        let client: PacketEngine
        let winlink: WinlinkContext
        let bbsSettings: BBSSettings
        let router: PacketInspectionRouter
    }

    private var savedCoordinator: SessionCoordinator?
    private var savedOpenAction: (() -> Void)?

    override func setUp() {
        super.setUp()
        // A window installed here must build its own coordinator, not wire
        // up whatever another test left in `shared`.
        savedCoordinator = SessionCoordinator.shared
        SessionCoordinator.shared = nil
        savedOpenAction = SettingsRouter.shared.openAction
    }

    override func tearDown() {
        SessionCoordinator.shared = savedCoordinator
        SettingsRouter.shared.openAction = savedOpenAction
        savedCoordinator = nil
        savedOpenAction = nil
        super.tearDown()
    }

    private func station(_ label: String) -> Station {
        let defaults = TestDefaults.make(label)
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "K0EPI"
        // Switched off and pointed nowhere, so nothing the window starts can
        // open a link to a TNC running on this machine.
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
        return Station(defaults: defaults, settings: settings,
                       client: PacketEngine(settings: settings), winlink: winlink,
                       bbsSettings: BBSSettings(defaults: defaults),
                       router: PacketInspectionRouter())
    }

    private func contentView(_ station: Station) -> ContentView {
        ContentView(client: station.client, settings: station.settings,
                    inspectionRouter: station.router, winlinkContext: station.winlink,
                    bbsSettings: station.bbsSettings)
    }

    // MARK: - The box

    func testTheBoxBuildsOnceHoweverOftenItIsRead() {
        let station = station("MainWindowServicesBox")
        var builds = 0
        let box = MainWindowServicesBox {
            builds += 1
            let coordinator = SessionCoordinator()
            let library = BBSFileLibrary(store: nil)
            let lookup = CallsignLookupService(store: nil)
            return MainWindowServices(
                coordinator: coordinator, bbsLibrary: library, callsignLookup: lookup,
                bbsService: BBSService(store: nil, settings: station.bbsSettings,
                                       coordinator: coordinator, sendFrames: { _ in },
                                       stationCallsign: { "K0EPI" },
                                       isWinlinkP2PArmed: { false },
                                       winlinkP2PCallsign: { "" }, library: library))
        }
        XCTAssertEqual(builds, 0, "nothing is built until something asks")

        let first = box.services
        let second = box.services
        _ = box.services.bbsService

        XCTAssertEqual(builds, 1)
        XCTAssertTrue(first.coordinator === second.coordinator)
        XCTAssertTrue(first.bbsLibrary === second.bbsLibrary)
        XCTAssertTrue(first.callsignLookup === second.callsignLookup)
        XCTAssertTrue(first.bbsService === second.bbsService)
    }

    /// What AXTermApp's body does on every settings change: make a new
    /// ContentView value. Making one must not build anything.
    func testMakingContentViewValuesBuildsNothing() {
        let station = station("MainWindowServicesValues")
        let before = MainWindowServicesBox.buildCount

        _ = contentView(station)
        _ = contentView(station)
        _ = contentView(station)

        XCTAssertEqual(MainWindowServicesBox.buildCount, before,
                       "the services belong to the installed window, not to each view value")
        XCTAssertNil(SessionCoordinator.shared,
                     "no coordinator is made until a window is installed")
    }

    // MARK: - A hosted window

    /// Stands in for AXTermApp's body: it observes the settings store, so it
    /// runs again whenever a setting publishes, and it makes a new
    /// ContentView each time.
    private final class InitCounter { var count = 0 }

    private struct AppBodyStandIn: View {
        @ObservedObject var settings: AppSettingsStore
        let station: Station
        let counter: InitCounter

        var body: some View {
            counter.count += 1
            return ContentView(client: station.client, settings: settings,
                               inspectionRouter: station.router,
                               winlinkContext: station.winlink,
                               bbsSettings: station.bbsSettings)
                .defaultAppStorage(station.defaults)
        }
    }

    func testAHostedWindowBuildsItsServicesOnceAcrossSettingsChanges() throws {
        let station = station("MainWindowServicesHosted")
        let counter = InitCounter()
        let before = MainWindowServicesBox.buildCount

        let start = Date()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: AppBodyStandIn(settings: station.settings, station: station, counter: counter))
        defer { window.close() }
        spin(1.0)

        XCTAssertEqual(MainWindowServicesBox.buildCount - before, 1, "installing the window builds once")
        let coordinator = try XCTUnwrap(SessionCoordinator.shared, "the window made a coordinator")
        XCTAssertEqual(coordinator.localCallsign, station.settings.primaryCallsign,
                       "a new coordinator is seeded with the primary radio's address")
        let initsAtInstall = counter.count

        // Settings that publish without touching a radio or the network.
        station.settings.showConsoleDaySeparators.toggle()
        spin(0.3)
        station.settings.terminalFontSize += 1
        spin(0.3)
        station.settings.notifyPlaySound.toggle()
        spin(0.3)
        station.settings.myCallsign = "K0EPJ"
        spin(0.5)

        XCTAssertGreaterThan(counter.count, initsAtInstall,
                             "the stand-in re-ran its body, so ContentView.init ran again")
        XCTAssertEqual(MainWindowServicesBox.buildCount - before, 1,
                       "later initializers must not build the services again")
        XCTAssertTrue(SessionCoordinator.shared === coordinator, "still the same coordinator")
        XCTAssertEqual(coordinator.localCallsign, station.settings.primaryCallsign,
                       "the coordinator follows a callsign change")
        XCTAssertTrue(coordinator.localCallsign.hasPrefix("K0EPJ"))
        XCTAssertEqual(try Self.publishWarnings(since: start), 0,
                       "the main window published from inside a view update")
    }

    // MARK: - Helpers

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// SwiftUI reports the problem as a runtime issue in this process's log.
    private static func publishWarnings(since start: Date) throws -> Int {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(date: start.addingTimeInterval(-1)),
            matching: NSPredicate(format: "subsystem == %@", "com.apple.runtime-issues"))
        return entries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= start && $0.composedMessage.contains("Publishing changes from within view updates") }
            .count
    }
}
#endif
