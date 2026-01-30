//
//  WatchRulesTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/4/26.
//

import XCTest
@testable import AXTerm

@MainActor
final class WatchRulesTests: XCTestCase {
    func testCallsignMatchesFromToVia() {
        let settings = makeSettings()
        settings.watchCallsigns = ["N0CALL", "WIDE1-1"]
        let matcher = WatchRuleMatcher(settings: settings)

        let packet = Packet(
            from: AX25Address(call: "N0CALL"),
            to: AX25Address(call: "DEST"),
            via: [AX25Address(call: "WIDE1", ssid: 1)]
        )

        let match = matcher.match(packet: packet)
        XCTAssertEqual(match.matchedCallsigns, ["N0CALL", "WIDE1-1"])
        XCTAssertTrue(match.matchedKeywords.isEmpty)
    }

    func testKeywordMatchesPayload() {
        let settings = makeSettings()
        settings.watchKeywords = ["storm", "qrp"]
        let matcher = WatchRuleMatcher(settings: settings)

        let packet = Packet(info: Data("Storm warning at 7pm".utf8))
        let match = matcher.match(packet: packet)

        XCTAssertEqual(match.matchedKeywords, ["storm"])
        XCTAssertTrue(match.matchedCallsigns.isEmpty)
    }

    func testNotificationHonorsFrontmostRule() {
        let settings = makeSettings()
        settings.notifyOnWatchHits = true
        settings.notifyOnlyWhenInactive = true
        let center = MockNotificationCenter()
        let appState = MockAppState(isFrontmost: true)
        let scheduler = UserNotificationScheduler(center: center, settings: settings, appState: appState)

        let packet = Packet(from: AX25Address(call: "N0CALL"), info: Data("Test".utf8))
        let match = WatchMatch(matchedCallsigns: ["N0CALL"], matchedKeywords: [])
        scheduler.scheduleWatchNotification(packet: packet, match: match)

        XCTAssertTrue(center.requests.isEmpty)
    }

    func testNotificationSchedulesWhenBackgrounded() {
        let settings = makeSettings()
        settings.notifyOnWatchHits = true
        settings.notifyOnlyWhenInactive = true
        let center = MockNotificationCenter()
        let appState = MockAppState(isFrontmost: false)
        let scheduler = UserNotificationScheduler(center: center, settings: settings, appState: appState)

        let packet = Packet(from: AX25Address(call: "N0CALL"), info: Data("Test".utf8))
        let match = WatchMatch(matchedCallsigns: ["N0CALL"], matchedKeywords: [])
        scheduler.scheduleWatchNotification(packet: packet, match: match)

        XCTAssertEqual(center.requests.count, 1)
    }

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppSettingsStore(defaults: defaults)
    }
}
