//
//  SettingsSidebarPublishTests.swift
//  AXTermTests
//
//  Choosing a page in the Settings sidebar must not publish from inside a
//  view update. The List used to be bound straight to the router's
//  @Published tab, and each click logged "Publishing changes from within
//  view updates is not allowed" three to seven times.
//

#if os(macOS)
import AppKit
import OSLog
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class SettingsSidebarPublishTests: XCTestCase {

    func testChoosingSidebarPagesDoesNotPublishDuringViewUpdate() throws {
        let router = SettingsRouter.shared
        let originalTab = router.selectedTab
        defer { router.selectedTab = originalTab }
        router.selectedTab = .notifications

        let defaults = TestDefaults.make("SettingsSidebarPublish")
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        let client = PacketEngine(settings: settings)
        let view = SettingsView(
            settings: settings, client: client,
            packetStore: nil, consoleStore: nil, rawStore: nil, eventLogger: nil,
            notificationManager: NotificationAuthorizationManager(),
            winlinkSettings: WinlinkSettings(
                defaults: defaults,
                keychain: KeychainStore(service: "test-\(UUID().uuidString)")),
            stationProfile: StationProfile(defaults: defaults),
            locationService: nil, winlinkSync: nil,
            bbsSettings: BBSSettings(defaults: defaults))

        // Never ordered front: the window only has to exist for the List to
        // lay out, and a test has no business putting one on screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
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
        XCTAssertGreaterThan(visited.count, 2, "selecting rows should move between pages")

        let warnings = try Self.publishWarnings(since: start)
        XCTAssertEqual(warnings, 0, "the sidebar published from inside a view update")
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The sidebar is the longest list on the window: thirteen rows,
    /// headers included, against the one or two of the Notifications page.
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
