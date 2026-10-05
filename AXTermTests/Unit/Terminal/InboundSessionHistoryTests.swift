//
//  InboundSessionHistoryTests.swift
//  AXTermTests
//
//  A session someone opens to this station goes into the history.
//
//  Smoke run 2026-10-03-1, issue 48: history recorded only connects made
//  from the connect bar, so a caller's session (B (ID-50) answering A (705),
//  08:09 to 08:27) left nothing. The coordinator answers every inbound call
//  and now records it, with or without a window.
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class InboundSessionHistoryTests: XCTestCase {

    private let caller = AX25Address(call: "K0EPI", ssid: 2)
    private let local = AX25Address(call: "K0EPI", ssid: 3)

    private func station() throws -> (SessionCoordinator, PacketEngine) {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let settings = AppSettingsStore(defaults: TestDefaults.make("InboundHistory"))
        let engine = PacketEngine(settings: settings, databaseWriter: queue)
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "K0EPI-3"
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: engine)
        return (coordinator, engine)
    }

    func testACallersSessionIsRecordedFromConnectToDisconnect() throws {
        let (coordinator, engine) = try station()
        defer { SessionCoordinator.shared = nil }

        _ = coordinator.sessionManager.handleInboundSABM(from: caller, to: local,
                                                         path: DigiPath(), radio: .primary)
        let id = try XCTUnwrap(coordinator.inboundRecordID(for: caller), "a live record while connected")
        coordinator.packetEngine?.sessionRecorder?.recorded(
            line: "K0EPI-2: smoke 10.1 line mode from A", for: id, sent: false, bytes: 27)
        _ = coordinator.sessionManager.handleInboundDISC(from: caller, path: DigiPath(), radio: .primary)
        XCTAssertNil(coordinator.inboundRecordID(for: caller))

        let sessions = try XCTUnwrap(engine.terminalSessions?.sessions(limit: 10))
        XCTAssertEqual(sessions.count, 1)
        let stored = try XCTUnwrap(sessions.first)
        XCTAssertEqual(stored.remote, "K0EPI-2")
        XCTAssertEqual(stored.outcome, .closed)
        XCTAssertNotNil(stored.endedAt)
        XCTAssertEqual(stored.framesReceived, 1)
    }

    /// A session this station opened is the connect bar's to record.
    func testASessionWeOpenedIsNotRecordedHereToo() throws {
        let (coordinator, engine) = try station()
        defer { SessionCoordinator.shared = nil }

        _ = coordinator.sessionManager.connect(to: caller)
        _ = coordinator.sessionManager.handleInboundUA(from: caller, path: DigiPath(), radio: .primary)
        XCTAssertNil(coordinator.inboundRecordID(for: caller))
        XCTAssertEqual(try engine.terminalSessions?.sessions(limit: 10).count, 0)
    }
}
