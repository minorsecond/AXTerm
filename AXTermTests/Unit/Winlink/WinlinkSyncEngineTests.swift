import XCTest
@testable import AXTerm

// MARK: - Fake store

/// One device's mailbox, in memory.
///
/// Two of these plus one `WinlinkInMemorySyncTransport` is a faithful model
/// of an operator's Mac and iPhone sharing an iCloud account, which is the
/// only way to test the merge rules end to end without two machines.
private final class FakeSyncStore: WinlinkSyncStore, @unchecked Sendable {

    /// Rowids deliberately differ between instances so a test that syncs a
    /// folder by its number instead of its identity fails loudly.
    var folderRows: [WinlinkFolderRecord]
    var messages: [String: (message: WinlinkB2Message, direction: WinlinkMessageRecord.Direction)] = [:]
    var states: [String: WinlinkMessageStateRecord] = [:]
    private var nextFolderID: Int64

    init(folderIDBase: Int64) {
        nextFolderID = folderIDBase + 6
        folderRows = WinlinkFolderRecord.SystemRole.allCases.enumerated().map { index, role in
            WinlinkFolderRecord(id: folderIDBase + Int64(index),
                                name: role.rawValue.capitalized,
                                systemRole: role.rawValue,
                                sortOrder: index)
        }
    }

    func folders() throws -> [WinlinkFolderRecord] { folderRows }

    func folderID(for role: WinlinkFolderRecord.SystemRole) throws -> Int64 {
        guard let id = folderRows.first(where: { $0.role == role })?.id else {
            throw WinlinkStoreError.missingSystemFolder(role.rawValue)
        }
        return id
    }

    @discardableResult
    func createFolder(name: String) throws -> WinlinkFolderRecord {
        let folder = WinlinkFolderRecord(id: nextFolderID, name: name,
                                         systemRole: nil, sortOrder: 99)
        nextFolderID += 1
        folderRows.append(folder)
        return folder
    }

    func syncMessageStates() throws -> [WinlinkMessageStateRecord] {
        states.values.sorted { $0.messageId < $1.messageId }
    }

    func syncStoredMessage(mid: String) throws -> WinlinkStoredMessage? {
        guard let entry = messages[mid], let state = states[mid] else { return nil }
        return WinlinkStoredMessage(message: entry.message,
                                    direction: entry.direction,
                                    state: state)
    }

    func syncInsertMessage(_ message: WinlinkB2Message,
                           direction: WinlinkMessageRecord.Direction,
                           state: WinlinkMessageStateRecord) throws {
        guard messages[message.mid] == nil else { return }
        messages[message.mid] = (message, direction)
        states[message.mid] = state
    }

    func syncUpdateState(_ state: WinlinkMessageStateRecord) throws {
        guard states[state.messageId] != nil else { return }
        states[state.messageId] = state
    }

    // Deletion

    var tombstones: [String: Date] = [:]

    func syncTombstones() throws -> [WinlinkMessageTombstoneRecord] {
        tombstones
            .map { WinlinkMessageTombstoneRecord(messageId: $0.key, deletedAt: $0.value) }
            .sorted { $0.messageId < $1.messageId }
    }

    func syncIsDeleted(mid: String) throws -> Bool { tombstones[mid] != nil }

    @discardableResult
    func syncApplyDeletion(mid: String, at deletedAt: Date) throws -> Bool {
        let removed = messages.removeValue(forKey: mid) != nil
        states.removeValue(forKey: mid)
        let stamp = min(deletedAt, tombstones[mid] ?? deletedAt)
        let changed = removed || tombstones[mid] != stamp
        tombstones[mid] = stamp
        return changed
    }

    /// What moving a message to the Trash does on this device.
    func trash(_ mid: String, at when: Date) throws {
        guard var state = states[mid] else { return }
        state.trashedFromFolderId = state.folderId
        state.trashedAt = when
        state.folderId = try folderID(for: .trash)
        state.updatedAt = when
        states[mid] = state
    }

    /// What the UI's permanent delete does on this device.
    func deleteForever(_ mid: String, at when: Date) {
        messages.removeValue(forKey: mid)
        states.removeValue(forKey: mid)
        tombstones[mid] = when
    }

    // Test helpers

    func insert(_ message: WinlinkB2Message,
                direction: WinlinkMessageRecord.Direction = .inbound,
                folder: WinlinkFolderRecord.SystemRole = .inbox,
                delivery: WinlinkMessageStateRecord.DeliveryState = .received,
                isRead: Bool = false,
                updatedAt: Date) throws {
        messages[message.mid] = (message, direction)
        states[message.mid] = WinlinkMessageStateRecord(
            messageId: message.mid,
            folderId: try folderID(for: folder),
            isRead: isRead,
            deliveryState: delivery.rawValue,
            sentOffset: 0,
            lastError: nil,
            updatedAt: updatedAt)
    }

    func folderName(ofMID mid: String) -> String? {
        guard let id = states[mid]?.folderId else { return nil }
        return folderRows.first { $0.id == id }?.name
    }
}

/// A source that claims a kind the policy forbids, to prove the engine
/// enforces the policy rather than trusting its sources.
private struct RogueSource: WinlinkSyncSource {
    let kind: WinlinkSyncPolicy.Kind = .sessionLog
    func localRecords() throws -> [WinlinkSyncRecord] {
        [WinlinkSyncRecord(kind: .sessionLog, id: "1",
                           modifiedAt: Date(), payload: Data("leak".utf8))]
    }
    func apply(_ records: [WinlinkSyncRecord]) throws -> Int { 0 }
}

// MARK: - Tests

final class WinlinkSyncEngineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func message(_ mid: String, subject: String = "Net check-in",
                         attachments: [WinlinkB2Message.Attachment] = []) -> WinlinkB2Message {
        WinlinkB2Message(
            mid: mid,
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 12:00")!,
            type: .privateMessage,
            from: "K0EPI",
            to: ["N0CALL"],
            cc: [],
            subject: subject,
            mbo: "K0EPI",
            body: Data("Body text.\r\n".utf8),
            attachments: attachments)
    }

    /// Home Mac and handheld. Rowid bases differ on purpose.
    private func pair() -> (home: FakeSyncStore, handheld: FakeSyncStore,
                            transport: WinlinkInMemorySyncTransport) {
        (FakeSyncStore(folderIDBase: 1),
         FakeSyncStore(folderIDBase: 100),
         WinlinkInMemorySyncTransport())
    }

    private func engine(_ store: FakeSyncStore,
                        _ transport: WinlinkInMemorySyncTransport,
                        device: String,
                        at time: @escaping @Sendable () -> Date) -> WinlinkSyncEngine {
        WinlinkSyncEngine(
            transport: transport,
            sources: WinlinkMessageSyncSource.sources(store: store, deviceID: device, now: time),
            tokenStore: WinlinkMemoryTokenStore())
    }

    // MARK: The headline behaviour

    /// Mail received on the home rig appears on the handheld.
    func testMailCrossesBetweenDevices() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000001"), updatedAt: t(0))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()

        XCTAssertEqual(handheld.messages.count, 1)
        XCTAssertEqual(handheld.messages["MID000000001"]?.message.subject, "Net check-in")
        XCTAssertEqual(handheld.folderName(ofMID: "MID000000001"), "Inbox")
    }

    /// The Trash has to read the same on both devices: same date, and the
    /// same idea of where the message came from, so Put Back works from
    /// either one.
    func testTrashDateAndOriginCrossBetweenDevices() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000020"), folder: .archive, updatedAt: t(0))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()
        XCTAssertEqual(handheld.folderName(ofMID: "MID000000020"), "Archive")

        try home.trash("MID000000020", at: t(200))
        let later = { self.t(300) }
        try await engine(home, transport, device: "home", at: later).sync()
        try await engine(handheld, transport, device: "ht", at: later).sync()

        XCTAssertEqual(handheld.folderName(ofMID: "MID000000020"), "Trash")
        XCTAssertEqual(handheld.states["MID000000020"]?.trashedAt, t(200))
        // The origin travels as a folder *identity*, so it resolves to the
        // handheld's own Archive rowid rather than the Mac's.
        XCTAssertEqual(handheld.states["MID000000020"]?.trashedFromFolderId,
                       try handheld.folderID(for: .archive))
    }

    /// A message that is not in the Trash must not carry a deletion date —
    /// that is what showing "Deleted 3 Aug" beside an Inbox message looks
    /// like.
    func testAMessageOutsideTheTrashCarriesNoDeletionDate() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000021"), updatedAt: t(0))
        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()

        XCTAssertNil(handheld.states["MID000000021"]?.trashedAt)
    }

    // MARK: Deletion

    /// The reason tombstones exist.
    ///
    /// Without one, the handheld still holds the message, sees a MID the Mac
    /// lacks, and helpfully sends it back — so deleting mail on one device
    /// would be undone by the next sync, forever.
    func testADeletedMessageIsNotResurrectedByTheOtherDevice() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000010"), updatedAt: t(0))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()
        XCTAssertEqual(handheld.messages.count, 1, "precondition: it crossed")

        home.deleteForever("MID000000010", at: t(200))

        // The handheld, which still holds it, pushes it back up.
        let later = { self.t(300) }
        try await engine(handheld, transport, device: "ht", at: later).sync()
        try await engine(home, transport, device: "home", at: later).sync()

        XCTAssertTrue(home.messages.isEmpty, "the Mac resurrected a message it deleted")
    }

    /// And the deletion travels the other way: the handheld must lose it too,
    /// or the mailboxes disagree about what exists.
    func testADeletionPropagatesToTheOtherDevice() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000011"), updatedAt: t(0))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()

        home.deleteForever("MID000000011", at: t(200))
        let later = { self.t(300) }
        try await engine(home, transport, device: "home", at: later).sync()
        try await engine(handheld, transport, device: "ht", at: later).sync()

        XCTAssertTrue(handheld.messages.isEmpty)
        XCTAssertNotNil(handheld.tombstones["MID000000011"])
    }

    /// A device that never held the message still has to record the
    /// deletion, or a content record arriving later — from a third device,
    /// or from a slow round — files it as new mail.
    func testADeletionIsRecordedEvenWithNothingToDelete() async throws {
        let (home, handheld, transport) = pair()
        home.deleteForever("MID000000012", at: t(50))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()

        XCTAssertEqual(handheld.tombstones["MID000000012"], t(50))
        XCTAssertTrue(handheld.messages.isEmpty)
    }

    /// Repeated syncs must not keep re-deciding. Convergence is the point.
    func testDeletionConvergesAndStaysConverged() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000013"), updatedAt: t(0))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()
        home.deleteForever("MID000000013", at: t(200))

        for round in 0..<4 {
            let when = { self.t(300 + Double(round) * 10) }
            try await engine(home, transport, device: "home", at: when).sync()
            try await engine(handheld, transport, device: "ht", at: when).sync()
        }

        XCTAssertTrue(home.messages.isEmpty)
        XCTAssertTrue(handheld.messages.isEmpty)
        // Both sides settle on the same instant, so neither keeps
        // re-publishing a "newer" deletion at the other.
        XCTAssertEqual(home.tombstones["MID000000013"], t(200))
        XCTAssertEqual(handheld.tombstones["MID000000013"], t(200))
    }

    /// Two devices deleting the same message independently must agree, and
    /// the earlier stamp is the one both can reach without another round.
    func testIndependentDeletionsConvergeOnTheEarlierStamp() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000014"), updatedAt: t(0))
        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()

        home.deleteForever("MID000000014", at: t(200))
        handheld.deleteForever("MID000000014", at: t(250))

        let later = { self.t(400) }
        try await engine(home, transport, device: "home", at: later).sync()
        try await engine(handheld, transport, device: "ht", at: later).sync()
        try await engine(home, transport, device: "home", at: later).sync()

        XCTAssertEqual(home.tombstones["MID000000014"], t(200))
        XCTAssertEqual(handheld.tombstones["MID000000014"], t(200))
    }

    /// Attachments survive the crossing. The mailbox carries ICS forms and
    /// photos, and mail that arrives without them is not the same mail.
    func testAttachmentsSurvive() async throws {
        let (home, handheld, transport) = pair()
        let attachment = WinlinkB2Message.Attachment(name: "ICS213.txt",
                                                     data: Data("form body".utf8))
        try home.insert(message("MID000000002", attachments: [attachment]), updatedAt: t(0))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()

        XCTAssertEqual(handheld.messages["MID000000002"]?.message.attachments, [attachment])
    }

    /// Reading on one device clears the badge on the other.
    func testReadFlagPropagates() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000003"), updatedAt: t(0))
        let clock = { self.t(100) }

        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()
        XCTAssertEqual(handheld.states["MID000000003"]?.isRead, false)

        // Read it on the handheld, sync both ways.
        handheld.states["MID000000003"]?.isRead = true
        handheld.states["MID000000003"]?.updatedAt = t(200)
        let later = { self.t(300) }
        try await engine(handheld, transport, device: "ht", at: later).sync()
        try await engine(home, transport, device: "home", at: later).sync()

        XCTAssertEqual(home.states["MID000000003"]?.isRead, true)
    }

    // MARK: Folder identity

    /// The bug this design exists to avoid: folder rowids are local. The two
    /// stores here number their folders differently on purpose, so a sync
    /// that shipped the raw id would file the message into whatever folder
    /// occupied that row on the other device.
    func testFoldersCrossByIdentityNotByRowID() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000004"), folder: .archive, updatedAt: t(0))
        XCTAssertNotEqual(try home.folderID(for: .archive), try handheld.folderID(for: .archive))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()

        XCTAssertEqual(handheld.states["MID000000004"]?.folderId,
                       try handheld.folderID(for: .archive))
        XCTAssertEqual(handheld.folderName(ofMID: "MID000000004"), "Archive")
    }

    /// A user folder that exists on only one device is created on the other,
    /// rather than the message landing in an arbitrary system folder.
    func testUserFolderIsCreatedOnArrival() async throws {
        let (home, handheld, transport) = pair()
        let field = try home.createFolder(name: "Field Day")
        try home.insert(message("MID000000005"), updatedAt: t(0))
        home.states["MID000000005"]?.folderId = field.id!
        home.states["MID000000005"]?.updatedAt = t(10)

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()

        XCTAssertEqual(handheld.folderName(ofMID: "MID000000005"), "Field Day")
        XCTAssertTrue(handheld.folderRows.contains { $0.name == "Field Day" && $0.role == nil })
    }

    // MARK: What must not sync

    /// A draft is still being typed. Syncing one lets two devices overwrite
    /// each other mid-sentence, and the immutability everything else here
    /// leans on does not hold until the message is queued.
    func testDraftsDoNotSync() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000006"), direction: .outbound,
                        folder: .drafts, delivery: .draft, updatedAt: t(0))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await engine(handheld, transport, device: "ht", at: clock).sync()

        XCTAssertTrue(handheld.messages.isEmpty)
        XCTAssertTrue(transport.allRecords.isEmpty)
    }

    /// The engine enforces the policy itself rather than trusting sources.
    /// A source that tried to replicate this station's session log — the
    /// measurement `WinlinkLinkQuality.appliesHere` refuses to move — is
    /// stopped, and the refusal is counted rather than hidden.
    func testDeviceLocalKindsAreRefusedAtTheEngine() async throws {
        let (home, _, transport) = pair()
        let engine = WinlinkSyncEngine(
            transport: transport,
            sources: [RogueSource()],
            tokenStore: WinlinkMemoryTokenStore())

        let report = try await engine.sync()
        XCTAssertEqual(report.refused, 1)
        XCTAssertEqual(report.pushed, 0)
        XCTAssertTrue(transport.allRecords.isEmpty)
        XCTAssertTrue(home.messages.isEmpty)
    }

    // MARK: Robustness

    /// A device that is signed out works alone rather than erroring at the
    /// operator. Sync is a convenience; the radio is the point.
    func testNoAccountIsReportedNotThrown() async throws {
        let store = FakeSyncStore(folderIDBase: 1)
        let engine = WinlinkSyncEngine(
            transport: UnavailableTransport(),
            sources: WinlinkMessageSyncSource.sources(store: store, deviceID: "home"),
            tokenStore: WinlinkMemoryTokenStore())

        let report = try await engine.sync()
        XCTAssertTrue(report.skippedNoAccount)
        XCTAssertEqual(report.pushed, 0)
    }

    /// One corrupt or newer-format record must not cost the operator the
    /// rest of the mailbox.
    func testOneUnreadableRecordDoesNotBlockTheRest() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000007"), updatedAt: t(0))

        let clock = { self.t(100) }
        try await engine(home, transport, device: "home", at: clock).sync()
        try await transport.push([WinlinkSyncRecord(
            kind: .message, id: "MID0BADBAD01",
            modifiedAt: t(50), payload: Data("not json".utf8))])

        let report = try await engine(handheld, transport, device: "ht", at: clock).sync()
        XCTAssertEqual(report.unreadable, 1)
        XCTAssertEqual(handheld.messages.count, 1)
        XCTAssertNotNil(handheld.messages["MID000000007"])
    }

    /// A second pass with nothing new must change nothing. Without this two
    /// devices can trade updates forever, each one's push provoking the
    /// other's.
    func testRepeatedSyncsConverge() async throws {
        let (home, handheld, transport) = pair()
        try home.insert(message("MID000000008"), updatedAt: t(0))
        let clock = { self.t(100) }

        let homeEngine = engine(home, transport, device: "home", at: clock)
        let htEngine = engine(handheld, transport, device: "ht", at: clock)

        for _ in 0..<3 {
            try await homeEngine.sync()
            try await htEngine.sync()
        }

        XCTAssertEqual(home.states["MID000000008"], handheld.states["MID000000008"].map {
            var copy = $0
            copy.folderId = home.states["MID000000008"]!.folderId
            return copy
        })
        XCTAssertEqual(handheld.messages.count, 1)
    }

    /// State arriving before its content is dropped, not stored. A state row
    /// with no message is an unreadable line in the mailbox.
    func testStateWithoutContentIsIgnored() async throws {
        let (_, handheld, transport) = pair()
        let payload = try JSONEncoder.iso8601.encode(WinlinkMessageStatePayload(
            folder: .system(.inbox), isRead: true, deliveryState: "received",
            updatedAt: t(0), lastError: nil, claim: nil,
            sentOffset: 0, offsetDevice: nil))
        try await transport.push([WinlinkSyncRecord(
            kind: .messageState, id: "MID00ORPHAN1", modifiedAt: t(0), payload: payload)])

        let report = try await engine(handheld, transport, device: "ht", at: { self.t(1) }).sync()
        XCTAssertEqual(report.applied, 0)
        XCTAssertTrue(handheld.states.isEmpty)
    }
}

// MARK: - Support

private struct UnavailableTransport: WinlinkSyncTransport {
    let deviceID = "offline"
    func isAvailable() async -> Bool { false }
    func fetchChanges(since token: Data?) async throws -> WinlinkSyncChangeSet {
        XCTFail("must not fetch without an account")
        return WinlinkSyncChangeSet()
    }
    func push(_ records: [WinlinkSyncRecord]) async throws {
        XCTFail("must not push without an account")
    }
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
