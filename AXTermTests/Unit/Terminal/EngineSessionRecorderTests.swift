//
//  EngineSessionRecorderTests.swift
//  AXTermTests
//
//  The engine owns the session recorder from the start.
//
//  Smoke run 2026-10-03-1, issue 49: a history transcript left out every
//  line the other station sent. The window created its recorder in a task
//  that ran after the terminal had wired its receive hook, and that hook
//  kept the nil it saw then; sending and the start and end of a session
//  read the recorder later and worked. A recorder that exists before any
//  view is built cannot be captured as nil.
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class EngineSessionRecorderTests: XCTestCase {

    func testAnEngineWithADatabaseRecordsFromTheStart() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let settings = AppSettingsStore(defaults: TestDefaults.make("EngineRecorder"))
        let engine = PacketEngine(settings: settings, databaseWriter: queue)

        let recorder = try XCTUnwrap(engine.sessionRecorder, "the recorder exists before any window")
        XCTAssertTrue(engine.sessionRecorder === recorder, "one recorder for the engine's life")

        recorder.began(id: "ax25|K0EPI-3", remote: "K0EPI-3", via: [], transport: "AX.25")
        recorder.recorded(line: "K0EPI-3: smoke 10.3 history reply from B", for: "ax25|K0EPI-3",
                          sent: false, bytes: 31)
        recorder.ended(id: "ax25|K0EPI-3", outcome: .closed)

        let stored = try XCTUnwrap(engine.terminalSessions?.sessions(limit: 10).first)
        XCTAssertEqual(stored.framesReceived, 1)
        XCTAssertEqual(stored.bytesReceived, 31)
        XCTAssertTrue(stored.transcript.contains("smoke 10.3 history reply from B"))
    }
}
