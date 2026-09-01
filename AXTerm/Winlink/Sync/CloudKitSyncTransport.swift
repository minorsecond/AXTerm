import Foundation
import CloudKit

/// Carries sync records through the operator's private CloudKit database.
///
/// Chosen over syncing the SQLite file: iCloud Drive replicates whole files
/// with last-writer-wins and no idea what a WAL journal is, so two devices
/// writing one database produce a corrupted store rather than a merged
/// mailbox. CloudKit merges per record, which is what the rules in
/// `WinlinkStateMerge` need.
///
/// The **private** database specifically. Winlink mail is the operator's own
/// traffic, some of it welfare and health-and-safety messages in an
/// emergency. It goes in the container only they can read, never a public or
/// shared one.
///
/// Same code on macOS, iOS and iPadOS — CloudKit has no platform-specific
/// surface here, which is why this file has no `#if os(...)` in it.
nonisolated final class CloudKitSyncTransport: WinlinkSyncTransport, @unchecked Sendable {

    /// Matches the app's bundle identifier, per Apple's container naming.
    static let defaultContainerID = "iCloud.com.rosswardrup.AXTerm"

    /// One custom zone, so fetches are incremental. The default zone has no
    /// change tokens, which would mean re-reading every message every pass.
    static let zoneName = "WinlinkMailbox"

    /// CloudKit rejects records over 1 MB, and counts an asset separately.
    /// Winlink messages are small by protocol, but a photo attachment from a
    /// form easily exceeds this, so oversized payloads move as assets.
    static let inlinePayloadLimit = 700 * 1024

    let deviceID: String

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private var zoneReady = false
    private let lock = NSLock()

    init(containerID: String = defaultContainerID,
         deviceID: String = WinlinkSyncDevice.identifier()) {
        self.container = CKContainer(identifier: containerID)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        self.deviceID = deviceID
    }

    // MARK: - Availability

    /// True only when the account can actually be written to.
    ///
    /// Reported rather than thrown: an operator who is signed out, or in the
    /// field with no path to Apple's servers, should find the app working
    /// alone. Sync is a convenience; the radio is the point.
    func isAvailable() async -> Bool {
        do {
            return try await container.accountStatus() == .available
        } catch {
            return false
        }
    }

    // MARK: - Fetch

    func fetchChanges(since token: Data?) async throws -> WinlinkSyncChangeSet {
        try await ensureZone()

        let serverToken = token.flatMap(Self.decodeToken)
        var records: [WinlinkSyncRecord] = []
        var wasReset = token != nil && serverToken == nil

        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = serverToken

        var latestToken: CKServerChangeToken?
        var fetchError: Error?

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: configuration])
        operation.fetchAllChanges = true

        operation.recordWasChangedBlock = { _, result in
            guard case .success(let record) = result else { return }
            if let decoded = Self.decode(record) { records.append(decoded) }
        }
        operation.recordZoneChangeTokensUpdatedBlock = { _, changeToken, _ in
            latestToken = changeToken ?? latestToken
        }
        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let (changeToken, _, _)):
                latestToken = changeToken
            case .failure(let error):
                // An expired token is recoverable and must be reported as a
                // reset, not swallowed: the caller has to know its increment
                // became a full re-read, or it will believe it saw
                // everything in between.
                if let ckError = error as? CKError, ckError.code == .changeTokenExpired {
                    wasReset = true
                } else {
                    fetchError = error
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }

        if let fetchError { throw fetchError }

        // A reset invalidates the increment, so re-run from the beginning
        // rather than returning a partial set that looks complete.
        if wasReset && serverToken != nil {
            var full = try await fetchChanges(since: nil)
            full.wasReset = true
            return full
        }

        return WinlinkSyncChangeSet(
            records: records,
            token: latestToken.flatMap(Self.encodeToken),
            wasReset: wasReset)
    }

    // MARK: - Push

    func push(_ records: [WinlinkSyncRecord]) async throws {
        guard !records.isEmpty else { return }
        try await ensureZone()

        // CloudKit caps a single operation at 400 records; batching keeps a
        // first sync of a full mailbox from being rejected outright.
        for batch in stride(from: 0, to: records.count, by: 300).map({
            Array(records[$0..<min($0 + 300, records.count)])
        }) {
            let ckRecords = batch.map(encode)
            let operation = CKModifyRecordsOperation(recordsToSave: ckRecords, recordIDsToDelete: nil)
            // The engine has already merged; the local value is the merged
            // one, so it is the value that should win at the server.
            operation.savePolicy = .changedKeys

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        }
    }

    // MARK: - Zone

    // Scoped locking: `lock()`/`unlock()` are unavailable in an async
    // function — a hard error under Swift 6 — because a suspension point
    // between them would hold the lock across an await. Here that risk is
    // real rather than theoretical: there is an `await` a few lines down.
    private func ensureZone() async throws {
        if lock.withLock({ zoneReady }) { return }

        do {
            _ = try await database.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another device created it first, which is the expected race.
        }

        lock.withLock { zoneReady = true }
    }

    // MARK: - Record mapping

    private enum Field {
        static let kind = "kind"
        static let itemID = "itemID"
        static let modifiedAt = "modifiedAt"
        static let payload = "payload"
        static let asset = "payloadAsset"
    }

    private func encode(_ record: WinlinkSyncRecord) -> CKRecord {
        let id = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
        let ck = CKRecord(recordType: record.kind.rawValue, recordID: id)
        ck[Field.kind] = record.kind.rawValue as CKRecordValue
        ck[Field.itemID] = record.id as CKRecordValue
        ck[Field.modifiedAt] = record.modifiedAt as CKRecordValue

        if record.payload.count <= Self.inlinePayloadLimit {
            ck[Field.payload] = record.payload as CKRecordValue
        } else if let asset = Self.makeAsset(record.payload) {
            ck[Field.asset] = asset
        } else {
            // Better a record that decodes to nothing than a silent partial
            // write: the receiver reports it unreadable and the operator
            // learns the message did not cross.
            ck[Field.payload] = Data() as CKRecordValue
        }
        return ck
    }

    private static func decode(_ ck: CKRecord) -> WinlinkSyncRecord? {
        guard let kindName = ck[Field.kind] as? String,
              let kind = WinlinkSyncPolicy.Kind(rawValue: kindName),
              let itemID = ck[Field.itemID] as? String,
              let modifiedAt = ck[Field.modifiedAt] as? Date
        else { return nil }

        let payload: Data
        if let inline = ck[Field.payload] as? Data, !inline.isEmpty {
            payload = inline
        } else if let asset = ck[Field.asset] as? CKAsset,
                  let url = asset.fileURL,
                  let data = try? Data(contentsOf: url) {
            payload = data
        } else {
            return nil
        }

        return WinlinkSyncRecord(kind: kind, id: itemID, modifiedAt: modifiedAt, payload: payload)
    }

    private static func makeAsset(_ data: Data) -> CKAsset? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("winlink-sync-\(UUID().uuidString)")
        guard (try? data.write(to: url)) != nil else { return nil }
        return CKAsset(fileURL: url)
    }

    // MARK: - Token coding

    static func encodeToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func decodeToken(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
