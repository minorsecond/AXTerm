import XCTest
import GRDB
@testable import AXTerm

/// Reading back a message that arrived over sync.
///
/// Mail pulled from another device takes a different write path
/// (`applyContent` → `syncInsertMessage`) from mail received over the air, and
/// the mailbox only ever reads it back through `message(mid:)`. A message that
/// stores but does not load is invisible: the list shows the row, tapping it
/// selects it, and the detail pane says "Select a message" forever.
final class WinlinkSyncedMessageDisplayTests: XCTestCase {

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func makeMessage(mid: String = "SYNCMID00001",
                             subject: String = "INQUIRY: LIST",
                             body: String = "the body",
                             attachments: [WinlinkB2Message.Attachment] = []) -> WinlinkB2Message {
        WinlinkB2Message(
            mid: mid,
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 08:09")!,
            type: .privateMessage,
            from: "SERVICE",
            to: ["K0EPI"],
            cc: [],
            subject: subject,
            mbo: "",
            body: Data(body.utf8),
            attachments: attachments)
    }

    /// Round-trips one message through the sync source into a real store and
    /// back out the way the mailbox reads it.
    private func syncIn(_ message: WinlinkB2Message,
                        into store: SQLiteWinlinkStore,
                        direction: WinlinkMessageRecord.Direction = .inbound) async throws {
        let payload = WinlinkMessageContentPayload(
            direction: direction.rawValue, b2f: try message.encode())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = WinlinkSyncRecord(
            kind: .message, id: message.mid, modifiedAt: message.date,
            payload: try encoder.encode(payload))

        let source = WinlinkMessageSyncSource(
            kind: .message, store: store, deviceID: "other-device")
        _ = try await source.apply([record])
    }

    // MARK: - The thing the operator sees

    /// A synced message must be readable, or the mailbox lists a row it
    /// cannot open.
    func testASyncedMessageCanBeOpened() async throws {
        let store = try makeStore()
        try await syncIn(makeMessage(), into: store)

        let stored = try store.message(mid: "SYNCMID00001")

        XCTAssertNotNil(stored, "a synced message that cannot be loaded is invisible")
        XCTAssertEqual(stored?.message.subject, "INQUIRY: LIST")
        XCTAssertEqual(stored?.message.from, "SERVICE")
    }

    /// And its body survives, since an openable message with no text is only
    /// marginally better than none.
    func testASyncedMessageKeepsItsBody() async throws {
        let store = try makeStore()
        try await syncIn(makeMessage(body: "Colorado Traffic Net"), into: store)

        let stored = try XCTUnwrap(try store.message(mid: "SYNCMID00001"))
        XCTAssertEqual(String(decoding: stored.message.body, as: UTF8.self),
                       "Colorado Traffic Net")
    }

    /// It appears in the folder listing too — the row and the readable
    /// message have to be the same record.
    func testASyncedMessageAppearsInItsFolder() async throws {
        let store = try makeStore()
        try await syncIn(makeMessage(), into: store)

        let inbox = try store.folderID(for: .inbox)
        let summaries = try store.messages(inFolder: inbox)

        XCTAssertEqual(summaries.map(\.mid), ["SYNCMID00001"])
        XCTAssertNotNil(try store.message(mid: summaries[0].id),
                        "the id the list hands back must open the message")
    }

    /// An attachment-bearing message round-trips as well — a form or a photo
    /// is the case most likely to have a load path of its own.
    func testASyncedMessageWithAnAttachmentCanBeOpened() async throws {
        let store = try makeStore()
        let attachment = WinlinkB2Message.Attachment(
            name: "position.csv", data: Data("39.61,-104.73".utf8))
        try await syncIn(makeMessage(attachments: [attachment]), into: store)

        let stored = try XCTUnwrap(try store.message(mid: "SYNCMID00001"))
        XCTAssertEqual(stored.message.attachments.map(\.name), ["position.csv"])
    }

    /// An outbound message crosses the same way and must open in Sent.
    func testASyncedOutboundMessageCanBeOpened() async throws {
        let store = try makeStore()
        try await syncIn(makeMessage(mid: "SYNCMID00002"), into: store, direction: .outbound)

        let stored = try XCTUnwrap(try store.message(mid: "SYNCMID00002"))
        XCTAssertEqual(stored.direction, .outbound)
    }
}
