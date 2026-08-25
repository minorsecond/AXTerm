import Foundation

/// One class of state the engine can replicate.
///
/// Kind-agnostic so the engine holds no knowledge of mail, contacts or
/// aliases: it fetches, hands records to the source that owns the kind, and
/// collects what the source wants pushed back.
nonisolated protocol WinlinkSyncSource: Sendable {
    var kind: WinlinkSyncPolicy.Kind { get }
    /// Everything this device holds for the kind, encoded for the wire.
    ///
    /// `async` because a source may have to reach state that lives on
    /// another actor — the operator's settings are `@MainActor` observable
    /// objects, and the engine runs off the main thread on purpose. Sources
    /// whose state is already free of isolation simply never suspend.
    func localRecords() async throws -> [WinlinkSyncRecord]
    /// Applies records from another device. Returns how many changed
    /// something locally — records already known are not changes.
    @discardableResult
    func apply(_ records: [WinlinkSyncRecord]) async throws -> Int
}

// MARK: - Folder references

/// How a folder crosses between devices.
///
/// `folderId` is a local SQLite rowid and means nothing anywhere else: this
/// Mac's Archive may be row 5 while the iPhone's is row 6, and user folders
/// exist on one device and not the other. Syncing the number would file mail
/// into whatever folder happened to occupy that row — silently, and
/// differently on each device.
///
/// So the wire carries the folder's *identity*: its role if the system owns
/// it, otherwise its name.
nonisolated enum WinlinkSyncFolderRef: Equatable, Sendable, Codable {
    case system(WinlinkFolderRecord.SystemRole)
    case user(String)

    static func of(folderId: Int64, in folders: [WinlinkFolderRecord]) -> WinlinkSyncFolderRef? {
        guard let folder = folders.first(where: { $0.id == folderId }) else { return nil }
        if let role = folder.role { return .system(role) }
        return .user(folder.name)
    }
}

// MARK: - Wire payloads

/// The immutable half of a message: its B2F bytes.
///
/// Reusing the protocol's own encoding rather than inventing a second one —
/// it is canonical, already round-trip tested, and carries attachments. A
/// separate serialization would be one more thing to keep in step with the
/// protocol, and the mailbox is the last place that should drift.
nonisolated struct WinlinkMessageContentPayload: Codable, Equatable, Sendable {
    var direction: String
    /// `WinlinkB2Message.encode()` output.
    var b2f: Data
}

/// The mutable half: what the merge rules operate on.
///
/// Kept in its own record so a read flag costs a few hundred bytes rather
/// than re-uploading every attachment the message carries.
nonisolated struct WinlinkMessageStatePayload: Codable, Equatable, Sendable {
    var folder: WinlinkSyncFolderRef
    var isRead: Bool
    var deliveryState: String
    var updatedAt: Date
    var lastError: String?
    var claim: WinlinkTransmitClaim?
    var sentOffset: Int
    var offsetDevice: String?
}

// MARK: - Store surface

/// What sync needs from persistence.
///
/// Deliberately separate from `WinlinkStore`: a device with no database has
/// nothing to sync, and that should be a missing conformance rather than a
/// pile of methods that throw.
nonisolated protocol WinlinkSyncStore: Sendable {
    func folders() throws -> [WinlinkFolderRecord]
    func folderID(for role: WinlinkFolderRecord.SystemRole) throws -> Int64
    @discardableResult
    func createFolder(name: String) throws -> WinlinkFolderRecord

    func syncMessageStates() throws -> [WinlinkMessageStateRecord]
    func syncStoredMessage(mid: String) throws -> WinlinkStoredMessage?
    /// Inserts a message that arrived from another device, content and state
    /// together. Existing MIDs are left alone — content is immutable.
    func syncInsertMessage(_ message: WinlinkB2Message,
                           direction: WinlinkMessageRecord.Direction,
                           state: WinlinkMessageStateRecord) throws
    /// Writes merged state onto an existing message.
    func syncUpdateState(_ state: WinlinkMessageStateRecord) throws
}

// MARK: - Message source

/// Replicates the mailbox: message content and message state.
///
/// Content and state travel as two kinds because they behave differently.
/// Content is written once and never revised, so it can be uploaded and
/// forgotten. State changes every time somebody opens a message, and is
/// small enough to re-send freely.
nonisolated struct WinlinkMessageSyncSource: WinlinkSyncSource {

    let kind: WinlinkSyncPolicy.Kind
    private let store: WinlinkSyncStore
    private let deviceID: String
    private let now: @Sendable () -> Date

    init(kind: WinlinkSyncPolicy.Kind,
         store: WinlinkSyncStore,
         deviceID: String,
         now: @escaping @Sendable () -> Date = Date.init) {
        precondition(kind == .message || kind == .messageState,
                     "this source owns mail only")
        self.kind = kind
        self.store = store
        self.deviceID = deviceID
        self.now = now
    }

    /// Both halves of the mailbox, ready to plug into an engine.
    static func sources(store: WinlinkSyncStore,
                        deviceID: String,
                        now: @escaping @Sendable () -> Date = Date.init)
        -> [WinlinkSyncSource] {
        [WinlinkMessageSyncSource(kind: .message, store: store, deviceID: deviceID, now: now),
         WinlinkMessageSyncSource(kind: .messageState, store: store, deviceID: deviceID, now: now)]
    }

    // MARK: Outgoing

    func localRecords() throws -> [WinlinkSyncRecord] {
        let folders = try store.folders()
        let states = try store.syncMessageStates()

        return try states.compactMap { state -> WinlinkSyncRecord? in
            switch kind {
            case .message:
                // Drafts are excluded on purpose. A draft is still being
                // written; syncing one mid-sentence would let two devices
                // overwrite each other's typing, and the immutability the
                // rest of this design leans on does not hold until the
                // message is queued.
                guard state.state != .draft else { return nil }
                guard let stored = try store.syncStoredMessage(mid: state.messageId) else { return nil }
                let payload = WinlinkMessageContentPayload(
                    direction: stored.direction.rawValue,
                    b2f: try stored.message.encode())
                return WinlinkSyncRecord(
                    kind: .message,
                    id: state.messageId,
                    modifiedAt: stored.message.date,
                    payload: try Self.encoder.encode(payload))

            case .messageState:
                guard state.state != .draft else { return nil }
                guard let folder = WinlinkSyncFolderRef.of(folderId: state.folderId, in: folders) else {
                    return nil
                }
                let payload = WinlinkMessageStatePayload(
                    folder: folder,
                    isRead: state.isRead,
                    deliveryState: state.deliveryState,
                    updatedAt: state.updatedAt,
                    lastError: state.lastError,
                    // A claim is only asserted by the device that owns the
                    // send; this source reports, it does not claim.
                    claim: nil,
                    sentOffset: state.sentOffset,
                    offsetDevice: state.sentOffset > 0 ? deviceID : nil)
                return WinlinkSyncRecord(
                    kind: .messageState,
                    id: state.messageId,
                    modifiedAt: state.updatedAt,
                    payload: try Self.encoder.encode(payload))

            default:
                return nil
            }
        }
    }

    // MARK: Incoming

    @discardableResult
    func apply(_ records: [WinlinkSyncRecord]) throws -> Int {
        var changed = 0
        for record in records where record.kind == kind {
            switch kind {
            case .message: changed += try applyContent(record) ? 1 : 0
            case .messageState: changed += try applyState(record) ? 1 : 0
            default: break
            }
        }
        return changed
    }

    /// New mail from another device. Existing MIDs are skipped rather than
    /// overwritten — content is immutable, so a second copy is the same copy.
    private func applyContent(_ record: WinlinkSyncRecord) throws -> Bool {
        if try store.syncStoredMessage(mid: record.id) != nil { return false }

        guard let payload = try? Self.decoder.decode(
                WinlinkMessageContentPayload.self, from: record.payload),
              let direction = WinlinkMessageRecord.Direction(rawValue: payload.direction),
              let message = try? WinlinkB2Message.parse(payload.b2f)
        else {
            throw WinlinkSyncError.payloadUnreadable(kind: kind, id: record.id)
        }
        // Content can arrive before its companion state record. The seed
        // below keeps the message readable in the meantime, and is stamped
        // `provisionalTimestamp` so the merge treats it as a placeholder
        // rather than a decision — otherwise the seed's guesses would
        // outrank the real state when it lands.
        //
        // Outbound seeds as `sent` rather than `queued` on purpose. If the
        // state record never arrives, a wrongly-queued message would be
        // transmitted a second time, which is invisible; a wrongly-sent one
        // sits in Sent where the operator can see it and resend. Failing
        // toward silence on the air is the right way round.
        let role: WinlinkFolderRecord.SystemRole = direction == .inbound ? .inbox : .sent
        let state = WinlinkMessageStateRecord(
            messageId: message.mid,
            folderId: try store.folderID(for: role),
            isRead: false,
            deliveryState: (direction == .inbound
                            ? WinlinkMessageStateRecord.DeliveryState.received
                            : .sent).rawValue,
            sentOffset: 0,
            lastError: nil,
            updatedAt: WinlinkStateMerge.State.provisionalTimestamp)
        try store.syncInsertMessage(message, direction: direction, state: state)
        return true
    }

    /// Merges a remote state onto the local one.
    ///
    /// A state for a message this device has never seen is dropped, not
    /// stored: state without content is an unreadable row in the mailbox.
    /// The content record is on its way, and its own arrival carries state
    /// with it.
    private func applyState(_ record: WinlinkSyncRecord) throws -> Bool {
        guard let stored = try store.syncStoredMessage(mid: record.id) else { return false }
        guard let payload = try? Self.decoder.decode(
                WinlinkMessageStatePayload.self, from: record.payload) else {
            throw WinlinkSyncError.payloadUnreadable(kind: kind, id: record.id)
        }

        let folderId = try resolve(payload.folder)
        let remote = WinlinkStateMerge.State(
            mid: record.id,
            isRead: payload.isRead,
            folderId: folderId,
            deliveryState: WinlinkMessageStateRecord.DeliveryState(rawValue: payload.deliveryState) ?? .received,
            updatedAt: payload.updatedAt,
            lastError: payload.lastError,
            claim: payload.claim,
            sentOffset: payload.sentOffset,
            offsetDevice: payload.offsetDevice)

        let local = WinlinkStateMerge.State(record: stored.state)
        let merged = WinlinkStateMerge.merge(local, remote, at: now())
        let updated = merged.applied(to: stored.state)
        guard updated != stored.state else { return false }
        try store.syncUpdateState(updated)
        return true
    }

    /// Turns a folder identity back into a local row, creating a user folder
    /// that only exists on the other device.
    private func resolve(_ ref: WinlinkSyncFolderRef) throws -> Int64 {
        switch ref {
        case .system(let role):
            return try store.folderID(for: role)
        case .user(let name):
            let folders = try store.folders()
            if let existing = folders.first(where: { $0.role == nil && $0.name == name }),
               let id = existing.id {
                return id
            }
            let created = try store.createFolder(name: name)
            if let id = created.id { return id }
            return try store.folderID(for: .inbox)
        }
    }

    // MARK: Coding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
