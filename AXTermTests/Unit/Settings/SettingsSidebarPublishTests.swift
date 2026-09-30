//
//  SettingsSidebarPublishTests.swift
//  AXTermTests
//
//  Settings must not publish from inside a view update. The sidebar List
//  used to be bound straight to the router's @Published tab, and each click
//  logged "Publishing changes from within view updates is not allowed" three
//  to seven times. These host every page, the radio page on both channels
//  with one radio and with two, each step of the Add Radio sheet and each
//  step of first-run setup, off-screen, and count the runtime issues SwiftUI
//  logs for this process.
//

#if os(macOS)
import AppKit
import OSLog
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class SettingsSidebarPublishTests: XCTestCase {

    private struct Station {
        let defaults: UserDefaults
        let settings: AppSettingsStore
        let client: PacketEngine
        let winlink: WinlinkSettings
    }

    private func station(_ label: String, radios: Int = 1) -> Station {
        let defaults = TestDefaults.make(label)
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "K0EPI"
        for _ in 1..<max(1, radios) { _ = settings.addRadio() }
        // Switched off, and pointed nowhere, so no page these tests show can
        // open a link to a TNC that happens to be running on this machine.
        for radio in settings.radios {
            settings.updateRadio(radio.id) {
                $0.enabled = false
                $0.host = "127.0.0.1"
                $0.port = 9
            }
        }
        let winlink = WinlinkSettings(defaults: defaults,
                                      keychain: KeychainStore(service: "test-\(UUID().uuidString)"))
        return Station(defaults: defaults, settings: settings,
                       client: PacketEngine(settings: settings), winlink: winlink)
    }

    private func settingsView(_ station: Station) -> SettingsView {
        SettingsView(
            settings: station.settings, client: station.client,
            packetStore: nil, consoleStore: nil, rawStore: nil, eventLogger: nil,
            notificationManager: NotificationAuthorizationManager(),
            winlinkSettings: station.winlink,
            stationProfile: StationProfile(defaults: station.defaults),
            locationService: nil, winlinkSync: nil,
            bbsSettings: BBSSettings(defaults: station.defaults))
    }

    /// Never ordered front: the window only has to exist for SwiftUI to lay
    /// the view out, and a test has no business putting one on screen.
    private func host<V: View>(_ view: V, width: CGFloat = 820, height: CGFloat = 640) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    private func preservingRouter(_ body: () throws -> Void) rethrows {
        let router = SettingsRouter.shared
        let tab = router.selectedTab
        let action = router.openAction
        router.openAction = nil
        defer {
            router.selectedTab = tab
            router.openAction = action
            router.pendingRadio = nil
            router.highlightSection = nil
        }
        try body()
    }

    // MARK: - The sidebar

    func testChoosingSidebarPagesDoesNotPublishDuringViewUpdate() throws {
        try preservingRouter {
            let router = SettingsRouter.shared
            router.selectedTab = .notifications
            let station = station("SettingsSidebarPublish")
            let window = host(settingsView(station))
            defer { window.close() }
            spin(0.5)

            let table = try XCTUnwrap(Self.sidebarTable(in: window.contentView), "sidebar table")
            XCTAssertGreaterThan(table.numberOfRows, 4)

            let start = Date()
            var visited = Set<SettingsTab>()
            for row in 0..<table.numberOfRows {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                spin(0.2)
                visited.insert(router.selectedTab)
            }
            XCTAssertEqual(visited, Set(SettingsTab.sidebarOrder),
                           "every page, Packet Node included, is one click away")

            let warnings = try Self.publishWarnings(since: start)
            XCTAssertEqual(warnings, 0, "the sidebar published from inside a view update")
        }
    }

    // MARK: - Every page

    private func renderEveryPage(radios: Int) throws {
        try preservingRouter {
            let router = SettingsRouter.shared
            router.selectedTab = .general
            let station = station("SettingsEveryPage\(radios)", radios: radios)
            let window = host(settingsView(station))
            defer { window.close() }
            spin(0.5)

            let start = Date()
            for tab in SettingsTab.sidebarOrder {
                router.selectedTab = tab
                spin(0.3)
            }
            // A deep link into a section of each kind of page.
            router.navigate(to: .linkLayer)
            spin(0.3)
            router.navigate(to: .radioTiming, radio: station.settings.activeRadios.first?.id)
            spin(0.5)
            router.navigate(to: .stationPosition)
            spin(0.3)
            XCTAssertEqual(try Self.publishWarnings(since: start), 0,
                           "a page published from inside a view update (\(radios) radio(s))")
        }
    }

    func testEveryPageRendersWithOneRadio() throws {
        try renderEveryPage(radios: 1)
    }

    func testEveryPageRendersWithTwoRadios() throws {
        try renderEveryPage(radios: 2)
    }

    // MARK: - The radio page on each channel

    private func renderRadioPage(radios: Int) throws {
        try preservingRouter {
            let station = station("SettingsRadioPage\(radios)", radios: radios)
            let settings = station.settings
            let id = try XCTUnwrap(settings.activeRadios.last?.id)
            let page = NavigationStack {
                RadioDetailView(radioID: id, settings: settings, client: station.client)
            }
            .environmentObject(SettingsRouter.shared)
            let window = host(page, width: 700, height: 900)
            defer { window.close() }
            spin(0.5)

            let start = Date()
            for channel in [RadioChannel.aprs, .packet, .aprs] {
                settings.updateRadio(id) {
                    channel.apply(to: &$0)
                    $0.beacon.enabled = true
                    $0.digi.enabled = channel == .packet
                }
                spin(0.3)
            }
            for kind in RadioTransportKind.allCases {
                settings.updateRadio(id) { $0.kind = kind }
                spin(0.3)
            }
            XCTAssertEqual(try Self.publishWarnings(since: start), 0,
                           "the radio page published from inside a view update (\(radios) radio(s))")
        }
    }

    func testTheRadioPageRendersOnBothChannelsWithOneRadio() throws {
        try renderRadioPage(radios: 1)
    }

    func testTheRadioPageRendersOnBothChannelsWithTwoRadios() throws {
        try renderRadioPage(radios: 2)
    }

    // MARK: - Add Radio and first-run setup

    func testEachAddRadioStepRenders() throws {
        let station = station("SettingsAddRadio")
        for channel in RadioChannel.allCases {
            let flow = AddRadioFlow(settings: station.settings, mode: .new)
            let window = host(AddRadioSheet(flow: flow, client: station.client) { _ in },
                              width: 560, height: 580)
            spin(0.4)
            let start = Date()
            while flow.step != .done {
                if flow.step == .channel { flow.setChannel(channel) }
                flow.next()
                spin(0.3)
            }
            XCTAssertEqual(try Self.publishWarnings(since: start), 0,
                           "an Add Radio step published from inside a view update (\(channel))")
            flow.cancel()
            window.close()
            spin(0.2)
        }
        XCTAssertEqual(station.settings.activeRadios.count, 1, "cancelled sheets leave nothing behind")
    }

    func testEachFirstRunStepRenders() throws {
        let station = station("SettingsFirstRun")
        station.settings.myCallsign = ""
        for stage in [FirstRunSetupView.Stage.callsign, .position, .radio] {
            let view = FirstRunSetupView(settings: station.settings, winlinkSettings: station.winlink,
                                         locationService: nil, client: station.client,
                                         startingAt: stage) { _ in }
                .environmentObject(SettingsRouter.shared)
            let start = Date()
            let window = host(view, width: 560, height: 580)
            spin(0.5)
            XCTAssertEqual(try Self.publishWarnings(since: start), 0,
                           "first-run setup's \(stage) step published from inside a view update")
            window.close()
        }
    }

    // MARK: - Helpers

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The sidebar is the longest list on the window, headers included,
    /// against the one or two of the Notifications page.
    private static func sidebarTable(in view: NSView?) -> NSTableView? {
        var tables: [NSTableView] = []
        collectTables(in: view, into: &tables)
        return tables.max { $0.numberOfRows < $1.numberOfRows }
    }

    private static func collectTables(in view: NSView?, into tables: inout [NSTableView]) {
        guard let view else { return }
        if let table = view as? NSTableView { tables.append(table) }
        for child in view.subviews { collectTables(in: child, into: &tables) }
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
