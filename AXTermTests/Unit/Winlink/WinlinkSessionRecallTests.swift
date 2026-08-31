import XCTest
import GRDB
@testable import AXTerm

/// Remembering which exchange carried a message, and being able to go back
/// to it afterwards.
///
/// The session log already records what each exchange cost — when it ran, to
/// which gateway, on what frequency, how many bytes each way, and whether it
/// worked. What it could not answer was the question an operator actually
/// asks about a message that arrived badly or late: *which* session brought
/// this one, and what did the link look like at the time.
final class WinlinkSessionRecallTests: XCTestCase {

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func makeMessage(mid: String) -> WinlinkB2Message {
        WinlinkB2Message(
            mid: mid,
            date: Date(timeIntervalSince1970: 1_788_000_000),
            type: .privateMessage,
            from: "K0EPI",
            to: ["N0CALL"],
            cc: [],
            subject: "Carried by a session",
            mbo: "K0EPI",
            body: Data("Body.\r\n".utf8),
            attachments: [])
    }

    private func makeLog(gateway: String = "W0ARP-10",
                         started: Date = Date(timeIntervalSince1970: 1_788_000_000),
                         seconds: TimeInterval = 161) -> WinlinkSessionLogRecord {
        WinlinkSessionLogRecord(
            id: nil,
            startedAt: started,
            endedAt: started.addingTimeInterval(seconds),
            gatewayCallsign: gateway,
            transport: "ax25",
            result: "success",
            messagesSent: 0,
            messagesReceived: 1,
            bytesSent: 55,
            bytesReceived: 1691,
            errorText: nil,
            frequencyHz: 145_050_000,
            obsLatitude: 39.6125,
            obsLongitude: -104.7333,
            obsGrid: "DM79po",
            obsSource: "GPS")
    }

    // MARK: - Duration

    /// The operator's question is "how long did that take", and the answer
    /// was always present in the two timestamps — it just had no name.
    func testASessionKnowsHowLongItTook() throws {
        let log = makeLog(seconds: 161)
        XCTAssertEqual(log.duration, 161, accuracy: 0.001)
    }

    // MARK: - Linking

    /// The link is recorded when the message is saved, because that is the
    /// only moment both facts are in hand.
    func testAMessageRemembersTheSessionThatCarriedIt() throws {
        let store = try makeStore()
        let logID = try store.appendSessionLogReturningID(makeLog())

        XCTAssertTrue(try store.saveInbound(makeMessage(mid: "CARRIED00001"), sessionLogID: logID))

        XCTAssertEqual(try store.sessionLogID(forMessage: "CARRIED00001"), logID)
    }

    /// A message that arrived some other way — imported, or saved before
    /// this existed — has no session, and must say so rather than pointing
    /// at an unrelated one.
    func testAMessageWithNoSessionSaysSo() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.saveInbound(makeMessage(mid: "ORPHAN000001"), sessionLogID: nil))
        XCTAssertNil(try store.sessionLogID(forMessage: "ORPHAN000001"))
    }

    /// The other direction: what did this exchange bring in? That is the
    /// question the session view answers.
    func testASessionListsWhatItCarried() throws {
        let store = try makeStore()
        let first = try store.appendSessionLogReturningID(makeLog())
        let second = try store.appendSessionLogReturningID(
            makeLog(started: Date(timeIntervalSince1970: 1_788_009_000)))

        _ = try store.saveInbound(makeMessage(mid: "FIRSTMSG0001"), sessionLogID: first)
        _ = try store.saveInbound(makeMessage(mid: "FIRSTMSG0002"), sessionLogID: first)
        _ = try store.saveInbound(makeMessage(mid: "SECONDMSG001"), sessionLogID: second)

        XCTAssertEqual(try store.messageIDs(forSessionLog: first).sorted(),
                       ["FIRSTMSG0001", "FIRSTMSG0002"])
        XCTAssertEqual(try store.messageIDs(forSessionLog: second), ["SECONDMSG001"])
    }

    /// Deleting a message must not take the session's own record with it —
    /// the exchange happened, it cost airtime, and that history is the
    /// point. (The reverse of the cascade that governs attachments.)
    func testDeletingAMessageLeavesTheSessionIntact() throws {
        let store = try makeStore()
        let logID = try store.appendSessionLogReturningID(makeLog())
        _ = try store.saveInbound(makeMessage(mid: "DOOMED000001"), sessionLogID: logID)

        _ = try store.deleteMessages(mids: ["DOOMED000001"])

        XCTAssertEqual(try store.sessionLogs(limit: 10).count, 1)
        XCTAssertTrue(try store.messageIDs(forSessionLog: logID).isEmpty)
    }

    /// Recall by id is what a link from a message needs.
    func testASessionCanBeFetchedBackById() throws {
        let store = try makeStore()
        let logID = try store.appendSessionLogReturningID(makeLog(gateway: "KB5YZB-1"))

        let recalled = try XCTUnwrap(store.sessionLog(id: logID))
        XCTAssertEqual(recalled.gatewayCallsign, "KB5YZB-1")
        XCTAssertEqual(recalled.bytesReceived, 1691)
        XCTAssertEqual(recalled.duration, 161, accuracy: 0.001)
    }

    func testAnUnknownSessionIdFetchesNothing() throws {
        let store = try makeStore()
        XCTAssertNil(try store.sessionLog(id: 9999))
    }
}
