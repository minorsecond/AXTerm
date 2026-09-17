import GRDB
import XCTest
@testable import AXTerm

/// A session that was interrupted is still a session.
///
/// The row is written the moment the session begins, carrying `.live`, so a
/// crash leaves evidence rather than nothing. What was missing was the other
/// end of that: nothing ever took `.live` off a session whose process did
/// not come back, so the history said "Still connected" about a contact that
/// ended days ago, and the transcript held nothing because it was only
/// written at close.
final class InterruptedSessionTests: XCTestCase {

    private func makeStore() throws -> SQLiteTerminalSessionStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteTerminalSessionStore(dbQueue: queue)
    }

    private func recorder(_ store: SQLiteTerminalSessionStore) -> TerminalSessionRecorder {
        TerminalSessionRecorder(store: store)
    }

    // MARK: Written from the start

    func testASessionIsOnDiskBeforeItEnds() throws {
        let store = try makeStore()
        recorder(store).began(id: "s1", remote: "KB5YZB-7", via: ["WIDE1-1"], transport: "AX.25")

        let stored = try store.sessions(limit: 10)
        XCTAssertEqual(stored.count, 1, "a crash now would still leave a record")
        XCTAssertEqual(stored.first?.outcome, .live)
        XCTAssertEqual(stored.first?.remote, "KB5YZB-7")
        XCTAssertNil(stored.first?.endedAt)
    }

    // MARK: Capping what did not come back

    func testLaunchCapsASessionLeftLive() throws {
        let store = try makeStore()
        recorder(store).began(id: "s1", remote: "KB5YZB-7", via: [], transport: "AX.25")

        // The process dies here. Nothing calls ended().
        let when = Date()
        XCTAssertEqual(try store.capInterruptedSessions(at: when), 1)

        let capped = try XCTUnwrap(try store.sessions(limit: 10).first)
        XCTAssertEqual(capped.outcome, .lost,
                       "a controller that vanished is, from the far end, a link that dropped")
        XCTAssertEqual(capped.endedAt?.timeIntervalSince1970 ?? 0,
                       when.timeIntervalSince1970, accuracy: 1)
    }

    /// Only the live ones. A session that ended properly keeps what it said
    /// about itself.
    func testCappingLeavesFinishedSessionsAlone() throws {
        let store = try makeStore()
        let rec = recorder(store)
        rec.began(id: "done", remote: "W0NED", via: [], transport: "AX.25")
        rec.ended(id: "done", outcome: .closed)
        rec.began(id: "open", remote: "WQ8M-9", via: [], transport: "AX.25")

        XCTAssertEqual(try store.capInterruptedSessions(at: Date()), 1)

        let byRemote = Dictionary(uniqueKeysWithValues:
            try store.sessions(limit: 10).map { ($0.remote, $0.outcome) })
        XCTAssertEqual(byRemote["W0NED"], .closed)
        XCTAssertEqual(byRemote["WQ8M-9"], .lost)
    }

    /// Running it twice must not re-cap, or a session closed since the last
    /// launch would be reopened and capped again.
    func testCappingIsIdempotent() throws {
        let store = try makeStore()
        recorder(store).began(id: "s1", remote: "K5RHD-10", via: [], transport: "AX.25")

        XCTAssertEqual(try store.capInterruptedSessions(at: Date()), 1)
        XCTAssertEqual(try store.capInterruptedSessions(at: Date()), 0,
                       "nothing is left live the second time")
    }

    func testNothingToCapIsNotAnError() throws {
        XCTAssertEqual(try makeStore().capInterruptedSessions(at: Date()), 0)
    }

    // MARK: The transcript survives too

    func testTheTranscriptIsFlushedBeforeTheSessionEnds() throws {
        let store = try makeStore()
        let rec = recorder(store)
        rec.began(id: "s1", remote: "KB5YZB-7", via: [], transport: "AX.25")

        for i in 0..<TerminalSessionRecorder.linesBetweenFlushes {
            rec.recorded(line: "line \(i)", for: "s1", sent: i.isMultiple(of: 2), bytes: 8)
        }

        // Still open, never ended: what is on disk is what a crash here
        // would leave behind.
        let mid = try XCTUnwrap(try store.sessions(limit: 10).first)
        XCTAssertEqual(mid.outcome, .live)
        XCTAssertTrue(mid.transcript.contains("line 0"), "the start of the exchange is kept")
        XCTAssertTrue(mid.transcript.contains("line \(TerminalSessionRecorder.linesBetweenFlushes - 1)"))
        XCTAssertGreaterThan(mid.framesSent + mid.framesReceived, 0, "counters land with it")
    }

    /// A handful of lines must not write on every one of them. The flush
    /// exists to bound the loss, not to put disk I/O on the frame path.
    func testAShortExchangeDoesNotWriteOnEveryLine() throws {
        let store = try makeStore()
        let rec = recorder(store)
        rec.began(id: "s1", remote: "KB5YZB-7", via: [], transport: "AX.25")
        rec.recorded(line: "hello", for: "s1", sent: true, bytes: 5)

        let stored = try XCTUnwrap(try store.sessions(limit: 10).first)
        XCTAssertTrue(stored.transcript.isEmpty,
                      "one line stays in memory until the next flush or the close")
    }

    func testClosingWritesWhateverIsLeft() throws {
        let store = try makeStore()
        let rec = recorder(store)
        rec.began(id: "s1", remote: "KB5YZB-7", via: [], transport: "AX.25")
        rec.recorded(line: "hello", for: "s1", sent: true, bytes: 5)
        rec.ended(id: "s1", outcome: .closed)

        let stored = try XCTUnwrap(try store.sessions(limit: 10).first)
        XCTAssertEqual(stored.outcome, .closed)
        XCTAssertTrue(stored.transcript.contains("hello"))
    }
}
