import GRDB
import XCTest
@testable import AXTerm

/// Connected-mode sessions that survive a relaunch.
///
/// The terminal kept these in `@State`, capped at twenty and gone when the
/// app closed, so "what did BBSCBH say last Tuesday" had no answer and
/// neither did "have I ever actually worked this node".
final class TerminalSessionStoreTests: XCTestCase {

    private var queue: DatabaseQueue!
    private var store: SQLiteTerminalSessionStore!
    private let t0 = Date(timeIntervalSince1970: 1_756_000_000)

    override func setUpWithError() throws {
        queue = try DatabaseQueue()
        try queue.write { try DatabaseManager.createTerminalSessions($0) }
        store = SQLiteTerminalSessionStore(dbQueue: queue)
    }

    private func session(_ remote: String, at offset: TimeInterval = 0,
                         via: [String] = [], relay: String? = nil,
                         outcome: TerminalSession.Outcome = .closed,
                         transcript: String = "", tags: [String] = [])
        -> TerminalSession {
        TerminalSession(remote: remote, via: via, relayDestination: relay,
                        startedAt: t0.addingTimeInterval(offset),
                        endedAt: t0.addingTimeInterval(offset + 120),
                        outcome: outcome, transcript: transcript, tags: tags)
    }

    func testASessionSurvivesAndComesBackWhole() throws {
        let original = session("DRLNOD", via: ["COSCO"], relay: "BBSCBH",
                               transcript: "*** CONNECTED\nBBS>", tags: ["bbs", "net"])
        try store.save(original)

        let read = try XCTUnwrap(try store.sessions(limit: 10).first)
        XCTAssertEqual(read.id, original.id)
        XCTAssertEqual(read.remote, "DRLNOD")
        XCTAssertEqual(read.via, ["COSCO"])
        XCTAssertEqual(read.relayDestination, "BBSCBH")
        XCTAssertEqual(read.transcript, "*** CONNECTED\nBBS>")
        XCTAssertEqual(read.tags, ["bbs", "net"])
        XCTAssertEqual(read.outcome, .closed)
    }

    /// A session is written when it opens and again as it runs, so saving
    /// twice has to update rather than duplicate or fail.
    func testSavingAgainUpdatesRatherThanDuplicating() throws {
        var live = session("KB5YZB-7", outcome: .live)
        live.endedAt = nil
        try store.save(live)

        live.outcome = .closed
        live.endedAt = t0.addingTimeInterval(300)
        live.framesReceived = 42
        try store.save(live)

        let all = try store.sessions(limit: 10)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.outcome, .closed)
        XCTAssertEqual(all.first?.framesReceived, 42)
    }

    /// Newest first: the session an operator wants is nearly always the last
    /// one.
    func testSessionsComeBackNewestFirst() throws {
        try store.save(session("A", at: 0))
        try store.save(session("B", at: 3_600))
        try store.save(session("C", at: 7_200))
        XCTAssertEqual(try store.sessions(limit: 10).map(\.remote), ["C", "B", "A"])
    }

    /// KB5YZB-1 and KB5YZB-7 are one operator's mailbox and node. Someone
    /// asking what they have done with KB5YZB means both.
    func testHistoryForAStationSpansItsSSIDs() throws {
        try store.save(session("KB5YZB-1", at: 0))
        try store.save(session("KB5YZB-7", at: 60))
        try store.save(session("DRLNOD", at: 120))

        XCTAssertEqual(try store.sessions(withRemote: "KB5YZB").count, 2)
        XCTAssertEqual(try store.sessions(withRemote: "kb5yzb-7").count, 2)
        XCTAssertEqual(try store.sessions(withRemote: "DRLNOD").count, 1)
    }

    // MARK: - Deleting

    func testOneSessionCanBeDeletedWithoutTouchingTheRest() throws {
        let doomed = session("A", at: 0)
        try store.save(doomed)
        try store.save(session("B", at: 60))

        try store.delete(id: doomed.id)
        XCTAssertEqual(try store.sessions(limit: 10).map(\.remote), ["B"])
    }

    /// "Forget what happened with this node", which is what the operator
    /// asked for, and only that node.
    func testEveryTraceOfOneStationCanGoAtOnce() throws {
        try store.save(session("KB5YZB-1", at: 0, tags: ["bbs"]))
        try store.save(session("KB5YZB-7", at: 60, tags: ["bbs"]))
        try store.save(session("DRLNOD", at: 120, tags: ["bbs"]))

        XCTAssertEqual(try store.deleteAll(forRemote: "KB5YZB"), 2)
        XCTAssertEqual(try store.sessions(limit: 10).map(\.remote), ["DRLNOD"])
    }

    /// Tags go with the session they belong to. A tag row left behind would
    /// keep counting toward a filter that can no longer find anything.
    func testDeletingASessionTakesItsTagsWithIt() throws {
        let doomed = session("A", at: 0, tags: ["portable"])
        try store.save(doomed)
        try store.save(session("B", at: 60, tags: ["portable", "net"]))

        try store.delete(id: doomed.id)
        XCTAssertEqual(try store.tagCounts(), ["portable": 1, "net": 1])
    }

    // MARK: - Tags and notes

    func testTagsAreCaseInsensitiveAndDeduplicated() throws {
        let one = session("A", at: 0)
        try store.save(one)
        try store.setTags(["Winlink", "winlink", " NET ", ""], for: one.id)

        let read = try XCTUnwrap(try store.sessions(limit: 1).first)
        XCTAssertEqual(read.tags.sorted(), ["net", "winlink"])
    }

    /// Setting tags replaces them. Otherwise removing one is impossible.
    func testSettingTagsReplacesWhatWasThere() throws {
        let one = session("A", at: 0, tags: ["old"])
        try store.save(one)
        try store.setTags(["new"], for: one.id)

        XCTAssertEqual(try store.sessions(limit: 1).first?.tags, ["new"])
        XCTAssertEqual(try store.tagCounts(), ["new": 1])
    }

    func testANoteCanBeAddedAndCleared() throws {
        let one = session("A", at: 0)
        try store.save(one)

        try store.setNote("asked about the net schedule", for: one.id)
        XCTAssertEqual(try store.sessions(limit: 1).first?.note,
                       "asked about the net schedule")

        try store.setNote(nil, for: one.id)
        XCTAssertNil(try store.sessions(limit: 1).first?.note)
    }

    // MARK: - Searching

    func testSearchLooksAtEverythingWorthSearching() throws {
        var one = session("DRLNOD", via: ["COSCO"], relay: "BBSCBH",
                          transcript: "Mail for KC0GIS", tags: ["bbs"])
        one.note = "checked the mailbox"

        for needle in ["drlnod", "cosco", "bbscbh", "bbs", "mailbox", "kc0gis", "closed"] {
            XCTAssertTrue(one.matches(needle), "should match \"\(needle)\"")
        }
        XCTAssertFalse(one.matches("w0tx"))
        XCTAssertTrue(one.matches("   "), "an empty query is not a filter")
    }

    /// A refusal is the far end answering; a timeout is nothing answering at
    /// all. Only one of those says the station is there.
    func testOnlyAnAnsweredSessionProvesTheFarEndHeardUs() {
        XCTAssertTrue(TerminalSession.Outcome.closed.provesTheFarEndHeardUs)
        XCTAssertTrue(TerminalSession.Outcome.refused.provesTheFarEndHeardUs)
        XCTAssertFalse(TerminalSession.Outcome.timedOut.provesTheFarEndHeardUs)
        XCTAssertFalse(TerminalSession.Outcome.lost.provesTheFarEndHeardUs)
        XCTAssertFalse(TerminalSession.Outcome.live.provesTheFarEndHeardUs)
    }
}
