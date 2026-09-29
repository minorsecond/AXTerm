import XCTest
import GRDB
@testable import AXTerm

/// The table that holds other devices' sessions, and the reads that feed
/// publication from this one's.
///
/// Two tables, one type: the remote rows are unreachable from the local
/// queries because they are a different table, not because anyone
/// remembers to filter.
final class TerminalSessionReplicationStoreTests: XCTestCase {

    private var queue: DatabaseQueue!
    private var local: SQLiteTerminalSessionStore!
    private var store: SQLiteTerminalSessionReplicationStore!
    private let t0 = Date(timeIntervalSince1970: 1_756_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    override func setUpWithError() throws {
        queue = try DatabaseQueue()
        try queue.write {
            try DatabaseManager.createTerminalSessions($0)
            try DatabaseManager.createRemoteTerminalSessions($0)
        }
        local = SQLiteTerminalSessionStore(dbQueue: queue)
        store = SQLiteTerminalSessionReplicationStore(dbQueue: queue)
    }

    private func session(_ remote: String, endedAt: Date? = nil,
                         outcome: TerminalSession.Outcome = .closed,
                         transcript: String = "hello") -> TerminalSession {
        TerminalSession(remote: remote, via: ["DRLNOD", "K0EPI-7"],
                        startedAt: t(-120), endedAt: endedAt ?? t(0),
                        outcome: outcome, framesSent: 1, framesReceived: 2,
                        bytesSent: 10, bytesReceived: 20, transcript: transcript)
    }

    private func payload(_ session: TerminalSession, device: String = "ipad",
                         station: String = "K0EPI-1", deviceName: String? = "iPad") -> TerminalSessionPayload {
        TerminalSessionPayload(
            session: session,
            provenance: WinlinkSyncProvenance(station: station, deviceID: device,
                                              gridSquare: "DM79", observedAt: session.endedAt ?? session.startedAt),
            deviceName: deviceName)
    }

    func testARemoteSessionSurvivesTheRoundTrip() throws {
        let original = session("N0CVL-10", transcript: "K0EPI-1: hi\nN0CVL-10: hello")
        try store.saveRemoteSessions([payload(original)])

        let back = try XCTUnwrap(try store.remoteSessions(limit: 10).first)
        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.remote, "N0CVL-10")
        XCTAssertEqual(back.via, ["DRLNOD", "K0EPI-7"])
        XCTAssertEqual(back.startedAt.timeIntervalSince1970,
                       original.startedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(back.endedAt.timeIntervalSince1970,
                       original.endedAt?.timeIntervalSince1970 ?? -1, accuracy: 0.001)
        XCTAssertEqual(back.outcome, .closed)
        XCTAssertEqual(back.framesSent, 1)
        XCTAssertEqual(back.framesReceived, 2)
        XCTAssertEqual(back.bytesSent, 10)
        XCTAssertEqual(back.bytesReceived, 20)
        XCTAssertEqual(back.transcript, "K0EPI-1: hi\nN0CVL-10: hello")
        XCTAssertFalse(back.transcriptTruncated)
        XCTAssertEqual(back.provenance.station, "K0EPI-1")
        XCTAssertEqual(back.provenance.deviceID, "ipad")
        XCTAssertEqual(back.provenance.gridSquare, "DM79")
        XCTAssertEqual(back.deviceName, "iPad")
    }

    /// The same session arriving twice — a re-pull after a token reset —
    /// is one row, holding the latest copy.
    func testSavingAgainUpdatesRatherThanDuplicating() throws {
        var session = session("N0CVL-10", transcript: "first")
        try store.saveRemoteSessions([payload(session)])
        session.transcript = "first\nsecond"
        try store.saveRemoteSessions([payload(session)])

        let rows = try store.remoteSessions(limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.transcript, "first\nsecond")
    }

    /// Two devices that both worked the same session ID cannot happen, but
    /// two devices are two rows for any ID: the key is device and session.
    func testTheSameSessionFromTwoDevicesIsTwoRows() throws {
        let one = session("N0CVL-10")
        try store.saveRemoteSessions([payload(one, device: "ipad"), payload(one, device: "iphone")])
        XCTAssertEqual(try store.remoteSessions(limit: 10).count, 2)
    }

    func testRemoteSessionsComeBackNewestFirst() throws {
        try store.saveRemoteSessions([
            payload(session("OLD", endedAt: t(-1_000))),
            payload(session("NEW", endedAt: t(0))),
            payload(session("MID", endedAt: t(-500))),
        ])
        XCTAssertEqual(try store.remoteSessions(limit: 10).map(\.remote), ["NEW", "MID", "OLD"])
        XCTAssertEqual(try store.remoteSessions(limit: 2).map(\.remote), ["NEW", "MID"])
    }

    /// The two tables never see each other: a remote row is not a local
    /// session, and a local session is not offered back as remote.
    func testRemoteRowsAreInvisibleToTheLocalStoreAndViceVersa() throws {
        try local.save(session("LOCAL-1"))
        try store.saveRemoteSessions([payload(session("REMOTE-1"))])

        XCTAssertEqual(try local.sessions(limit: 10).map(\.remote), ["LOCAL-1"])
        XCTAssertEqual(try store.remoteSessions(limit: 10).map(\.remote), ["REMOTE-1"])
    }

    /// Publication reads this device's finished sessions inside the window,
    /// and nothing live, nothing older, and nothing remote.
    func testPublicationOffersOnlyFinishedRecentLocalSessions() throws {
        try local.save(session("RECENT", endedAt: t(0)))
        try local.save(session("LIVE", endedAt: nil, outcome: .live))
        try local.save(session("STALE", endedAt: t(-10 * 86_400)))
        try store.saveRemoteSessions([payload(session("REMOTE-1"))])

        let offered = try store.localSessionsForPublication(endedSince: t(-7 * 86_400))

        XCTAssertEqual(offered.map(\.remote), ["RECENT"])
    }

    /// Forgetting a device takes every session it published and nothing
    /// else — the operator retired a radio, not the history it saw.
    func testADevicesSessionsCanBeForgottenTogether() throws {
        try store.saveRemoteSessions([
            payload(session("A"), device: "ipad"),
            payload(session("B"), device: "ipad"),
            payload(session("C"), device: "iphone"),
        ])

        let removed = try store.forgetRemoteSessions(fromDevice: "ipad")

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(try store.remoteSessions(limit: 10).map(\.remote), ["C"])
    }
}
