//
//  NativeCircuitHoldTests.swift
//  AXTermTests
//
//  The hour-long hold on native circuits after a failure ends early when the
//  station is heard announcing itself again.
//
//  The hold exists because a circuit cannot complete where nothing routes
//  back, and paying 30 s to relearn that on every connect is wasteful; its
//  own note says nodes come back. Smoke run 2026-10-03-1, issue 82: a circuit
//  to EPINDB failed at 08:19 because of a bug on B (issue 81), B was rebuilt
//  and announced itself again, and every Connect for the rest of the hour did
//  nothing at all: the native attempt was skipped quietly and nothing else
//  could reach the station.
//

import XCTest
@testable import AXTerm

@MainActor
final class NativeCircuitHoldTests: XCTestCase {

    private func aliases(_ name: String) -> (NodeAliasStore, UserDefaults) {
        let suite = "NativeCircuitHoldTests-\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return (NodeAliasStore(defaults: defaults), defaults)
    }

    private func nodes(from call: String, ssid: Int, alias: String, at time: Date) -> Packet {
        Packet(timestamp: time, from: AX25Address(call: call, ssid: ssid), to: AX25Address(call: "NODES"),
               frameType: .ui, control: 0x03, pid: NetRomBroadcastParser.netromPID,
               info: Data([0xFF] + Array(alias.utf8)), rawAx25: Data([0x01]))
    }

    func testAFailureHoldsNativeCircuitsToThatStation() {
        let coordinator = SessionCoordinator()
        coordinator.noteNativeNetRomFailed(to: "EPINDB")
        XCTAssertFalse(coordinator.shouldTryNativeNetRom(to: "EPINDB"))
        XCTAssertTrue(coordinator.shouldTryNativeNetRom(to: "COSCO"), "other stations are not held")
    }

    func testHearingTheStationAnnounceItselfAgainEndsTheHold() {
        let coordinator = SessionCoordinator()
        let (store, _) = aliases("again")
        coordinator.nodeAliases = store
        store.ingest(packets: [nodes(from: "K0EPI", ssid: 3, alias: "EPINDB", at: Date().addingTimeInterval(-600))])

        coordinator.noteNativeNetRomFailed(to: "EPINDB")
        XCTAssertFalse(coordinator.shouldTryNativeNetRom(to: "EPINDB"), "heard before the failure: no news")

        store.ingest(packets: [nodes(from: "K0EPI", ssid: 3, alias: "EPINDB", at: Date().addingTimeInterval(1))])
        XCTAssertTrue(coordinator.shouldTryNativeNetRom(to: "EPINDB"), "heard since the failure: try again")
        XCTAssertTrue(coordinator.shouldTryNativeNetRom(to: "K0EPI-3"), "by callsign too")
    }

    func testTheHoldSaysWhenItBeganWithoutEndingIt() {
        let coordinator = SessionCoordinator()
        XCTAssertNil(coordinator.nativeNetRomHold(to: "EPINDB"))
        coordinator.noteNativeNetRomFailed(to: "EPINDB")
        let began = coordinator.nativeNetRomHold(to: "epindb")
        XCTAssertNotNil(began)
        XCTAssertEqual(coordinator.nativeNetRomHold(to: "EPINDB"), began, "asking does not end the hold")
        coordinator.noteNativeNetRomSucceeded(to: "EPINDB")
        XCTAssertNil(coordinator.nativeNetRomHold(to: "EPINDB"))
    }

    /// A held destination used to be skipped with nothing but a debug log,
    /// so a connect that had nowhere else to go did nothing visible at all.
    func testSkippingAHeldCircuitTellsTheOperatorWhyAndUntilWhen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let failedAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 8, minute: 19))!
        let notice = NetRomRelayPlan.nativeHoldNotice(
            destination: "EPINDB", failedAt: failedAt, timeZone: calendar.timeZone)
        XCTAssertTrue(notice.contains("EPINDB"), notice)
        XCTAssertTrue(notice.contains("08:19"), notice)
        XCTAssertTrue(notice.contains("09:19"), notice)
        XCTAssertTrue(notice.contains("heard"), "says what ends it early: \(notice)")
        XCTAssertTrue(notice.contains("NET/ROM"), "names the mode that ignores it: \(notice)")
    }
}
