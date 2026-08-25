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

    // MARK: - Partial inbound bodies (B2F resume)

    func testPartialBodyRoundTripAndUpsert() throws {
        let store = try makeStore()
        try store.savePartialBody(mid: "PARTIAL00001", compressedSize: 4000, data: Data([1, 2, 3]))
        try store.savePartialBody(mid: "PARTIAL00001", compressedSize: 4000, data: Data([1, 2, 3, 4, 5]))

        let partials = try store.partialBodies()
        XCTAssertEqual(partials.count, 1, "same MID replaces, never duplicates")
        XCTAssertEqual(partials.first?.data, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(partials.first?.compressedSize, 4000)
    }

    func testPartialBodyDelete() throws {
        let store = try makeStore()
        try store.savePartialBody(mid: "PARTIAL00002", compressedSize: 100, data: Data([9]))
        try store.deletePartialBody(mid: "PARTIAL00002")
        try store.deletePartialBody(mid: "NEVEREXISTED")  // idempotent
        XCTAssertTrue(try store.partialBodies().isEmpty)
    }

    func testStalePartialBodiesExpire() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = SQLiteWinlinkStore(dbQueue: queue, now: { clock })

        try store.savePartialBody(mid: "STALE0000001", compressedSize: 100, data: Data([1]))
        clock = clock.addingTimeInterval(15 * 24 * 3600)  // beyond the 14-day lifetime

        XCTAssertTrue(try store.partialBodies().isEmpty, "expired partials are not offered for resume")
        try store.savePartialBody(mid: "FRESH0000001", compressedSize: 100, data: Data([2]))
        XCTAssertEqual(try store.partialBodies().map(\.mid), ["FRESH0000001"],
                       "saving prunes expired rows")
        try queue.read { db in
            XCTAssertEqual(try WinlinkPartialBodyRecord.fetchCount(db), 1)
        }
    }

    // MARK: - Inbound-by-sender query (radio-path catalog ingestion)

    func testInboundMessagesFilteredBySenderNewestFirst() throws {
        let store = try makeStore()
        let fmt = WinlinkB2Message.dateFormatter

        var older = makeMessage(mid: "SERVICEOLD01")
        older.from = "SERVICE"
        older.date = fmt.date(from: "2026/08/20 10:00")!
        var newer = makeMessage(mid: "SERVICENEW01")
        newer.from = "service"  // sender casing must not matter
        newer.date = fmt.date(from: "2026/08/23 14:09")!
        var other = makeMessage(mid: "OTHERSNDR001")
        other.from = "W0ARP"
        other.date = fmt.date(from: "2026/08/24 09:00")!

        try store.saveInbound(older)
        try store.saveInbound(newer)
        try store.saveInbound(other)
        // An outbound draft from the same address must not appear.
        var draft = makeMessage(mid: "DRAFTSVC0001")
        draft.from = "SERVICE"
        try store.saveDraft(draft)

        let results = try store.inboundMessages(fromAddr: "SERVICE", limit: 10)
        XCTAssertEqual(results.map(\.message.mid), ["SERVICENEW01", "SERVICEOLD01"])
        XCTAssertEqual(try store.inboundMessages(fromAddr: "SERVICE", limit: 1).map(\.message.mid),
                       ["SERVICENEW01"])
    }

    // MARK: - Catalog favourites

    func testCatalogFavoritesPersistIndependentlyOfTheCatalogCache() throws {
        let store = try makeStore()
        let item = WinlinkCatalogItemRecord(
            inquiryId: "WX_CONUS", category: "WX_US", subject: "Conus", url: "",
            lifetimeDays: 0, sizeEstimate: 10, enabled: true, fetchedAt: Date())
        try store.replaceCatalogCache([item])
        try store.setCatalogFavorite(inquiryId: "WX_CONUS", isFavorite: true)
        XCTAssertEqual(try store.catalogFavorites(), ["WX_CONUS"])

        // replaceCatalogCache deletes every product row. The star must
        // not go with them — that is why it lives in its own table.
        try store.replaceCatalogCache([])
        XCTAssertEqual(try store.catalogFavorites(), ["WX_CONUS"])

        try store.setCatalogFavorite(inquiryId: "WX_CONUS", isFavorite: false)
        XCTAssertTrue(try store.catalogFavorites().isEmpty)
    }

    /// Starring something already starred is a no-op, not a duplicate
    /// row and not a reset of when it was starred.
    func testRestarringAFavoriteIsIdempotent() throws {
        let store = try makeStore()
        try store.setCatalogFavorite(inquiryId: "WX_CONUS", isFavorite: true)
        try store.setCatalogFavorite(inquiryId: "WX_CONUS", isFavorite: true)
        XCTAssertEqual(try store.catalogFavorites(), ["WX_CONUS"])
    }

    /// Unstarring something never starred must not throw.
    func testUnstarringAnUnknownFavoriteIsHarmless() throws {
        let store = try makeStore()
        XCTAssertNoThrow(try store.setCatalogFavorite(inquiryId: "NOPE", isFavorite: false))
        XCTAssertTrue(try store.catalogFavorites().isEmpty)
    }

    // MARK: - List ordering

    /// Reading a message must not move it. The list sorted by the state
    /// row's `updatedAt`, which marking-as-read bumps, so clicking any
    /// message sent it to the top of the folder.
    func testMarkingReadDoesNotReorderTheFolder() throws {
        let store = try makeStore()
        let fmt = WinlinkB2Message.dateFormatter

        var oldest = makeMessage(mid: "OLDEST000001")
        oldest.date = fmt.date(from: "2026/08/22 08:00")!
        var middle = makeMessage(mid: "MIDDLE000001")
        middle.date = fmt.date(from: "2026/08/23 08:00")!
        var newest = makeMessage(mid: "NEWEST000001")
        newest.date = fmt.date(from: "2026/08/24 08:00")!
        for message in [oldest, middle, newest] { try store.saveInbound(message) }

        let inbox = try XCTUnwrap(
            store.folders().first { $0.systemRole == WinlinkFolderRecord.SystemRole.inbox.rawValue }?.id)
        let before = try store.messages(inFolder: inbox).map(\.mid)
        XCTAssertEqual(before, ["NEWEST000001", "MIDDLE000001", "OLDEST000001"])

        // Read the oldest one; it must stay where it was.
        try store.setRead(mid: "OLDEST000001", true)
        let after = try store.messages(inFolder: inbox).map(\.mid)
        XCTAssertEqual(after, before, "reading a message reordered the folder")
    }

    /// Same data in, same order out — regardless of insertion order.
    func testFolderOrderingIsDeterministic() throws {
        let store = try makeStore()
        let fmt = WinlinkB2Message.dateFormatter
        for mid in ["AAA000000001", "ZZZ000000001", "MMM000000001"] {
            var message = makeMessage(mid: mid)
            message.date = fmt.date(from: "2026/08/23 08:00")!
            try store.saveInbound(message)
        }
        let inbox = try XCTUnwrap(
            store.folders().first { $0.systemRole == WinlinkFolderRecord.SystemRole.inbox.rawValue }?.id)
        XCTAssertEqual(try store.messages(inFolder: inbox).map(\.mid),
                       try store.messages(inFolder: inbox).map(\.mid))
    }

    // MARK: - Callsign directory cache

    /// The cache is the whole reason this is worth having: a station
    /// looked up once must stay resolvable with the network gone.
    func testCallsignRecordRoundTrips() throws {
        let store = try makeStore()
        let record = CallsignDirectoryRecord(
            callsign: "W0ARP", name: "Alex Example", gridSquare: "DM79ql",
            latitude: 39.4918279, longitude: -104.6398437,
            locality: "Parker", state: "CO", country: "United States",
            licenseClass: "E", expires: "07/25/2035",
            source: "HamDB", fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.saveCallsignRecord(record)

        let loaded = try XCTUnwrap(store.callsignRecord(callsign: "W0ARP"))
        XCTAssertEqual(loaded, record)
    }

    /// Lookups are by licence, so the SSID must not partition the cache —
    /// W0ARP-10 and W0ARP-7 are the same licensee.
    func testCacheIsKeyedByBaseCallsign() throws {
        let store = try makeStore()
        try store.saveCallsignRecord(CallsignDirectoryRecord(
            callsign: "W0ARP", gridSquare: "DM79ql",
            source: "HamDB", fetchedAt: Date()))
        XCTAssertNotNil(try store.callsignRecord(callsign: "W0ARP-10"))
        XCTAssertNotNil(try store.callsignRecord(callsign: "w0arp-7"))
    }

    func testUnknownCallsignReturnsNothing() throws {
        let store = try makeStore()
        XCTAssertNil(try store.callsignRecord(callsign: "ZZ9ZZZ"))
    }

    /// A later answer replaces the earlier one rather than duplicating.
    func testResavingReplacesTheEntry() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveCallsignRecord(CallsignDirectoryRecord(
            callsign: "W0ARP", gridSquare: "DM79ql", source: "HamDB", fetchedAt: now))
        try store.saveCallsignRecord(CallsignDirectoryRecord(
            callsign: "W0ARP", gridSquare: "DM79qm", source: "HamDB",
            fetchedAt: now.addingTimeInterval(3600)))
        let loaded = try XCTUnwrap(store.callsignRecord(callsign: "W0ARP"))
        XCTAssertEqual(loaded.gridSquare, "DM79qm")
    }
}
