import XCTest
import GRDB
@testable import AXTerm

/// The tables that hold other mailboxes' messages and callers, and the reads
/// that feed publication from this one's.
final class BBSMailboxReplicationStoreTests: XCTestCase {

    private var queue: DatabaseQueue!
    private var local: SQLiteBBSMessageStore!
    private var store: SQLiteBBSMailboxReplicationStore!
    private let t0 = Date(timeIntervalSince1970: 1_756_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    override func setUpWithError() throws {
        queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue)
        local = SQLiteBBSMessageStore(dbQueue: queue)
        store = SQLiteBBSMailboxReplicationStore(dbQueue: queue)
    }

    private func message(_ id: Int64, subject: String = "Hello", at offset: TimeInterval = 0,
                         readAt: Date? = nil, killedAt: Date? = nil) -> BBSMessage {
        BBSMessage(id: id, from: "N0CVL", to: "K0EPI", subject: subject, body: "Body\nlines",
                   receivedAt: t(offset), readAt: readAt, killedAt: killedAt)
    }

    private func payload(_ message: BBSMessage, device: String = "ipad",
                         mailbox: String = "K0EPI-9", deviceName: String? = "iPad") -> BBSMessagePayload {
        BBSMessagePayload(message: message, mailbox: mailbox,
                          provenance: WinlinkSyncProvenance(station: "K0EPI-1", deviceID: device,
                                                            gridSquare: "DM79", observedAt: message.receivedAt),
                          deviceName: deviceName)
    }

    private func callPayload(_ id: Int64, _ callsign: String, device: String = "ipad",
                             at offset: TimeInterval = 0) -> BBSCallPayload {
        BBSCallPayload(call: BBSCall(id: id, callsign: callsign, connectedAt: t(offset - 90),
                                     disconnectedAt: t(offset), actions: ["read 3", "left mail for K0EPI"],
                                     endedUnexpectedly: true),
                       mailbox: "K0EPI-9",
                       provenance: WinlinkSyncProvenance(station: "K0EPI-1", deviceID: device,
                                                         gridSquare: nil, observedAt: t(offset)),
                       deviceName: "iPad")
    }

    func testARemoteMessageSurvivesTheRoundTrip() throws {
        let original = message(12, subject: "Bulletin", readAt: t(10), killedAt: t(20))
        try store.saveRemoteMessages([payload(original)])

        let back = try XCTUnwrap(try store.remoteMessages(limit: 10).first)
        XCTAssertEqual(back.id, 12)
        XCTAssertEqual(back.subject, "Bulletin")
        XCTAssertEqual(back.body, "Body\nlines")
        XCTAssertEqual(back.receivedAt.timeIntervalSince1970, original.receivedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(back.readAt?.timeIntervalSince1970 ?? -1, t(10).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(back.killedAt?.timeIntervalSince1970 ?? -1, t(20).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(back.mailbox, "K0EPI-9")
        XCTAssertEqual(back.provenance.deviceID, "ipad")
        XCTAssertEqual(back.provenance.gridSquare, "DM79")
        XCTAssertEqual(back.deviceName, "iPad")
    }

    /// A message whose state changed on its home device — killed, read —
    /// replaces the earlier copy rather than sitting beside it.
    func testSavingAgainUpdatesRatherThanDuplicating() throws {
        var m = message(12)
        try store.saveRemoteMessages([payload(m)])
        m.killedAt = t(50)
        try store.saveRemoteMessages([payload(m)])

        let rows = try store.remoteMessages(limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].killedAt)
    }

    func testTheSameNumberFromTwoMailboxesIsTwoRows() throws {
        try store.saveRemoteMessages([payload(message(12), device: "ipad"), payload(message(12), device: "iphone")])
        XCTAssertEqual(try store.remoteMessages(limit: 10).count, 2)
    }

    func testRemoteMessagesComeBackNewestFirst() throws {
        try store.saveRemoteMessages([payload(message(1, at: -100)), payload(message(2, at: 0)), payload(message(3, at: -50))])
        XCTAssertEqual(try store.remoteMessages(limit: 10).map(\.id), [2, 3, 1])
    }

    func testARemoteCallSurvivesTheRoundTrip() throws {
        try store.saveRemoteCalls([callPayload(9, "W0ARP-10")])
        let back = try XCTUnwrap(try store.remoteCalls(limit: 10).first)
        XCTAssertEqual(back.id, 9)
        XCTAssertEqual(back.callsign, "W0ARP-10")
        XCTAssertEqual(back.actions, ["read 3", "left mail for K0EPI"])
        XCTAssertTrue(back.endedUnexpectedly)
        XCTAssertEqual(back.mailbox, "K0EPI-9")
        XCTAssertEqual(back.deviceName, "iPad")
    }

    /// The local mailbox and the remote tables never see each other.
    func testRemoteRowsAreInvisibleToTheLocalMailboxAndViceVersa() throws {
        try local.store(message(1, subject: "Local"))
        try store.saveRemoteMessages([payload(message(1, subject: "Remote"))])

        XCTAssertEqual(try local.allMessages().map(\.subject), ["Local"])
        XCTAssertEqual(try store.remoteMessages(limit: 10).map(\.subject), ["Remote"])
        XCTAssertEqual(try store.localMessagesForPublication().map(\.subject), ["Local"])
    }

    /// Publication offers finished calls inside the window only.
    func testPublicationOffersOnlyFinishedRecentCalls() throws {
        let recent = try local.beginCall(callsign: "N0CVL-7", at: t(-60))
        try local.endCall(id: recent, at: t(0), unexpected: false)
        _ = try local.beginCall(callsign: "LIVE-1", at: t(0))
        let stale = try local.beginCall(callsign: "OLD-1", at: t(-10 * 86_400))
        try local.endCall(id: stale, at: t(-10 * 86_400 + 60), unexpected: false)

        let offered = try store.localCallsForPublication(endedSince: t(-7 * 86_400))

        XCTAssertEqual(offered.map(\.callsign), ["N0CVL-7"])
    }

    func testAMailboxCanBeForgottenTogether() throws {
        try store.saveRemoteMessages([payload(message(1), device: "ipad"), payload(message(2), device: "mac")])
        try store.saveRemoteCalls([callPayload(1, "A", device: "ipad"), callPayload(2, "B", device: "mac")])

        try store.forgetRemoteMailbox(fromDevice: "ipad")

        XCTAssertEqual(try store.remoteMessages(limit: 10).map(\.id), [2])
        XCTAssertEqual(try store.remoteCalls(limit: 10).map(\.callsign), ["B"])
    }
}
