//
//  WatchNotificationIntegrationTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/4/26.
//

import XCTest
@testable import AXTerm

@MainActor
final class WatchNotificationIntegrationTests: XCTestCase {
    func testWatchHitPersistsEventAndSchedulesNotification() async {
        let settings = makeSettings()
        settings.watchCallsigns = ["N0CALL"]
        let eventStore = MockEventLogStore()
        let watchRecorder = EventLogWatchRecorder(store: eventStore, settings: settings)
        let scheduler = MockNotificationScheduler()
        let engine = PacketEngine(
            settings: settings,
            packetStore: nil,
            consoleStore: nil,
            rawStore: nil,
            eventLogger: nil,
            watchRecorder: watchRecorder,
            notificationScheduler: scheduler
        )

        let packet = Packet(from: AX25Address(call: "N0CALL"), to: AX25Address(call: "DEST"))
        engine.handleIncomingPacket(packet)

        await waitForEventStore(eventStore)

        XCTAssertEqual(eventStore.appendedEntries.count, 1)
        XCTAssertEqual(scheduler.scheduledPackets.count, 1)
    }

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppSettingsStore(defaults: defaults)
    }

    private func waitForEventStore(_ store: MockEventLogStore) async {
        for _ in 0..<10 {
            if !store.appendedEntries.isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
