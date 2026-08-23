import XCTest
import GRDB
@testable import AXTerm

final class SQLiteWinlinkStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func makeMessage(mid: String = "TESTMID00001",
                             attachments: [WinlinkB2Message.Attachment] = []) -> WinlinkB2Message {
        WinlinkB2Message(
            mid: mid,
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 12:00")!,
            type: .privateMessage,
            from: "K0EPI",
            to: ["N0CALL"],
            cc: ["W1AW"],
            subject: "Store test",
            mbo: "K0EPI",
            body: Data("Body text.\r\n".utf8),
            attachments: attachments)
    }

    // MARK: - Folders

    func testSystemFoldersAreSeeded() throws {
        let store = try makeStore()
        let folders = try store.folders()
        XCTAssertEqual(folders.count, 6)
        let roles = folders.compactMap(\.role)
        XCTAssertEqual(Set(roles), Set(WinlinkFolderRecord.SystemRole.allCases))
        // Every system folder resolves by role.
        for role in WinlinkFolderRecord.SystemRole.allCases {
            XCTAssertNoThrow(try store.folderID(for: role))
        }
    }

    func testCreateRenameDeleteUserFolder() throws {
        let store = try makeStore()
        let folder = try store.createFolder(name: "ARES")
        XCTAssertNotNil(folder.id)
        XCTAssertNil(folder.systemRole)

        try store.renameFolder(id: folder.id!, name: "ARES Traffic")
        XCTAssertTrue(try store.folders().contains { $0.name == "ARES Traffic" })

        try store.deleteFolder(id: folder.id!)
        XCTAssertFalse(try store.folders().contains { $0.name == "ARES Traffic" })
    }

    func testSystemFoldersCannotBeRenamedOrDeleted() throws {
        let store = try makeStore()
        let inboxID = try store.folderID(for: .inbox)
        XCTAssertThrowsError(try store.renameFolder(id: inboxID, name: "X")) {
            XCTAssertEqual($0 as? WinlinkStoreError, .cannotModifySystemFolder)
        }
        XCTAssertThrowsError(try store.deleteFolder(id: inboxID)) {
            XCTAssertEqual($0 as? WinlinkStoreError, .cannotModifySystemFolder)
        }
    }

    func testDeleteFolderMovesMessagesToArchive() throws {
        let store = try makeStore()
        let folder = try store.createFolder(name: "Temp")
        try store.saveInbound(makeMessage(mid: "ARCHIVETEST1"))
        try store.move(mid: "ARCHIVETEST1", toFolder: folder.id!)

        try store.deleteFolder(id: folder.id!)
        let stored = try XCTUnwrap(try store.message(mid: "ARCHIVETEST1"))
        XCTAssertEqual(stored.state.folderId, try store.folderID(for: .archive))
    }

    // MARK: - Drafts

    func testDraftLifecycle() throws {
        let store = try makeStore()
        var message = makeMessage(mid: "DRAFT0000001")
        try store.saveDraft(message)

        let draftsID = try store.folderID(for: .drafts)
        XCTAssertEqual(try store.messages(inFolder: draftsID).map(\.mid), ["DRAFT0000001"])

        // Drafts are mutable.
        message.subject = "Edited subject"
        try store.updateDraft(message)
        XCTAssertEqual(try store.message(mid: "DRAFT0000001")?.message.subject, "Edited subject")

        // Queueing freezes and moves to Outbox.
        try store.queueDraft(mid: "DRAFT0000001")
        let outboxID = try store.folderID(for: .outbox)
        XCTAssertEqual(try store.messages(inFolder: outboxID).map(\.mid), ["DRAFT0000001"])
        XCTAssertEqual(try store.message(mid: "DRAFT0000001")?.state.state, .queued)

        // Frozen messages reject further edits — the append-only rule.
        XCTAssertThrowsError(try store.updateDraft(message)) {
            XCTAssertEqual($0 as? WinlinkStoreError, .notADraft("DRAFT0000001"))
        }
        XCTAssertThrowsError(try store.queueDraft(mid: "DRAFT0000001")) {
            XCTAssertEqual($0 as? WinlinkStoreError, .notADraft("DRAFT0000001"))
        }
    }

    func testDraftAttachmentsSurviveUpdate() throws {
        let store = try makeStore()
        var message = makeMessage(
            mid: "DRAFTATTACH1",
            attachments: [.init(name: "a.bin", data: Data([1, 2, 3]))])
        try store.saveDraft(message)

        message.attachments = [
            .init(name: "b.bin", data: Data([4, 5])),
            .init(name: "c.bin", data: Data([6])),
        ]
        try store.updateDraft(message)

        let stored = try XCTUnwrap(try store.message(mid: "DRAFTATTACH1"))
        XCTAssertEqual(stored.message.attachments.map(\.name), ["b.bin", "c.bin"])
    }

    // MARK: - Exchange lifecycle

    func testQueuedMessagesRoundTripForExchange() throws {
        let store = try makeStore()
        let message = makeMessage(
            mid: "QUEUED000001",
            attachments: [.init(name: "photo.jpg", data: Data(repeating: 0xab, count: 500))])
        try store.saveDraft(message)
        try store.queueDraft(mid: "QUEUED000001")

        let queued = try store.queuedOutboundMessages()
        XCTAssertEqual(queued, [message], "reconstructed message must be identical for compression")
    }

    func testSentFlowMovesToSentFolder() throws {
        let store = try makeStore()
        try store.saveDraft(makeMessage(mid: "SENDME000001"))
        try store.queueDraft(mid: "SENDME000001")
        try store.markSending(mid: "SENDME000001")
        XCTAssertEqual(try store.message(mid: "SENDME000001")?.state.state, .sending)

        try store.markSent(mid: "SENDME000001")
        let stored = try XCTUnwrap(try store.message(mid: "SENDME000001"))
        XCTAssertEqual(stored.state.state, .sent)
        XCTAssertEqual(stored.state.folderId, try store.folderID(for: .sent))
        XCTAssertTrue(try store.queuedOutboundMessages().isEmpty)
    }

    func testFailedStaysInOutboxWithError() throws {
        let store = try makeStore()
        try store.saveDraft(makeMessage(mid: "FAILME000001"))
        try store.queueDraft(mid: "FAILME000001")
        try store.markFailed(mid: "FAILME000001", error: "rejected by gateway")

        let stored = try XCTUnwrap(try store.message(mid: "FAILME000001"))
        XCTAssertEqual(stored.state.state, .failed)
        XCTAssertEqual(stored.state.lastError, "rejected by gateway")
        XCTAssertEqual(stored.state.folderId, try store.folderID(for: .outbox))
    }

    func testRevertSendingToQueued() throws {
        let store = try makeStore()
        for mid in ["REVERT000001", "REVERT000002"] {
            try store.saveDraft(makeMessage(mid: mid))
            try store.queueDraft(mid: mid)
            try store.markSending(mid: mid)
        }
        try store.revertSendingToQueued()
        XCTAssertEqual(try store.queuedOutboundMessages().count, 2)
    }

    // MARK: - Inbound

    func testSaveInboundLandsUnreadInInbox() throws {
        let store = try makeStore()
        let message = makeMessage(mid: "INBOUND00001")
        XCTAssertTrue(try store.saveInbound(message))

        let inboxID = try store.folderID(for: .inbox)
        let summaries = try store.messages(inFolder: inboxID)
        XCTAssertEqual(summaries.map(\.mid), ["INBOUND00001"])
        XCTAssertFalse(summaries[0].isRead)
        XCTAssertEqual(summaries[0].deliveryState, .received)
        XCTAssertEqual(try store.unreadInboxCount(), 1)

        try store.setRead(mid: "INBOUND00001", true)
        XCTAssertEqual(try store.unreadInboxCount(), 0)
    }

    func testDuplicateMIDKeepsFirstCopy() throws {
        let store = try makeStore()
        var message = makeMessage(mid: "DUPMSG000001")
        XCTAssertTrue(try store.saveInbound(message))

        message.subject = "Different content, same MID"
        XCTAssertFalse(try store.saveInbound(message), "gateway re-send must not duplicate")
        XCTAssertEqual(try store.message(mid: "DUPMSG000001")?.message.subject, "Store test")
        XCTAssertEqual(try store.messages(inFolder: try store.folderID(for: .inbox)).count, 1)
    }

    // MARK: - Moving / trash

    func testMoveAndTrash() throws {
        let store = try makeStore()
        try store.saveInbound(makeMessage(mid: "MOVEME000001"))
        let folder = try store.createFolder(name: "Keep")
        try store.move(mid: "MOVEME000001", toFolder: folder.id!)
        XCTAssertEqual(try store.messages(inFolder: folder.id!).count, 1)

        try store.moveToTrash(mid: "MOVEME000001")
        XCTAssertEqual(try store.messages(inFolder: try store.folderID(for: .trash)).count, 1)
        // Content is untouched by moves — append-only.
        XCTAssertEqual(try store.message(mid: "MOVEME000001")?.message.subject, "Store test")
    }

    func testMoveToUnknownFolderThrows() throws {
        let store = try makeStore()
        try store.saveInbound(makeMessage(mid: "MOVEFAIL0001"))
        XCTAssertThrowsError(try store.move(mid: "MOVEFAIL0001", toFolder: 9999)) {
            XCTAssertEqual($0 as? WinlinkStoreError, .folderNotFound(9999))
        }
    }

    // MARK: - Caches

    func testStationCacheReplace() throws {
        let store = try makeStore()
        let station = WinlinkRMSStationRecord(
            callsign: "KE7XO-10", gridSquare: "DM79", frequencyHz: 145_050_000,
            modeName: "Packet", baud: "1200", serviceCode: "PUBLIC",
            distanceMiles: 12.5, headingDegrees: 210,
            lastSeenAt: Date(timeIntervalSince1970: 1_000), fetchedAt: Date(timeIntervalSince1970: 2_000))
        try store.replaceStationCache([station])
        XCTAssertEqual(try store.stations(), [station])

        // Replacement fully swaps the cache.
        var newer = station
        newer.callsign = "W0XYZ-10"
        try store.replaceStationCache([newer])
        XCTAssertEqual(try store.stations().map(\.callsign), ["W0XYZ-10"])
    }

    func testCatalogCacheReplace() throws {
        let store = try makeStore()
        let item = WinlinkCatalogItemRecord(
            inquiryId: "WX_CONUS", category: "Weather", subject: "CONUS forecast",
            url: "", lifetimeDays: 1, sizeEstimate: 4000, enabled: true,
            fetchedAt: Date(timeIntervalSince1970: 3_000))
        try store.replaceCatalogCache([item])
        XCTAssertEqual(try store.catalogItems(), [item])
    }

    // MARK: - Session log

    func testSessionLogAppendAndFetch() throws {
        let store = try makeStore()
        let log = WinlinkSessionLogRecord(
            id: nil, startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 200),
            gatewayCallsign: "KE7XO-10", transport: "ax25", result: "success",
            messagesSent: 1, messagesReceived: 2, bytesSent: 300, bytesReceived: 4000, errorText: nil)
        try store.appendSessionLog(log)
        let logs = try store.sessionLogs(limit: 10)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].gatewayCallsign, "KE7XO-10")
        XCTAssertNotNil(logs[0].id)
    }

    // MARK: - Cascade

    func testDeletingMessageRowCascades() throws {
        let store = try makeStore()
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let cascadeStore = SQLiteWinlinkStore(dbQueue: queue)
        _ = store  // silence unused warning; cascade test uses its own queue

        try cascadeStore.saveInbound(makeMessage(
            mid: "CASCADE00001",
            attachments: [.init(name: "x.bin", data: Data([1]))]))

        try queue.write { db in
            try WinlinkMessageRecord.deleteOne(db, key: "CASCADE00001")
        }
        try queue.read { db in
            XCTAssertEqual(try WinlinkMessageStateRecord.fetchCount(db), 0)
            XCTAssertEqual(try WinlinkAttachmentRecord.fetchCount(db), 0)
        }
    }
}
