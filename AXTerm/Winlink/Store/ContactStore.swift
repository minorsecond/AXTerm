import Foundation
import GRDB

/// One address-book entry. A contact can carry a callsign, an internet
/// address, or both; `preferredAddress` picks the right form for a
/// Winlink To: field.
nonisolated struct WinlinkContactRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable, Identifiable {
    static let databaseTableName = "winlinkContact"

    var id: Int64?
    var displayName: String
    var callsign: String
    var smtpEmail: String
    var phone: String
    var organization: String
    var positionTitle: String
    var gridSquare: String
    var street: String
    var city: String
    var state: String
    var postalCode: String
    var notes: String
    var favorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The address to put in a Winlink To/Cc field: callsign when the
    /// contact has one, otherwise their internet address.
    var preferredAddress: String? {
        if !callsign.isEmpty { return callsign }
        if !smtpEmail.isEmpty { return "SMTP:\(smtpEmail)" }
        return nil
    }

    static func empty(now: Date = Date()) -> WinlinkContactRecord {
        WinlinkContactRecord(
            id: nil, displayName: "", callsign: "", smtpEmail: "", phone: "",
            organization: "", positionTitle: "", gridSquare: "",
            street: "", city: "", state: "", postalCode: "", notes: "",
            favorite: false, createdAt: now, updatedAt: now, lastUsedAt: nil)
    }
}

nonisolated enum ContactStoreError: Error, Equatable {
    case contactNotFound(Int64)
    case emptyName
}

/// Address-book persistence.
nonisolated protocol ContactStore: Sendable {
    func contacts() throws -> [WinlinkContactRecord]
    /// Case-insensitive match on name, callsign, or email.
    func searchContacts(_ query: String) throws -> [WinlinkContactRecord]
    @discardableResult
    func saveContact(_ contact: WinlinkContactRecord) throws -> WinlinkContactRecord
    func deleteContact(id: Int64) throws
    /// Records that an address was used, bumping recency for suggestions.
    func touchContact(address: String, at date: Date) throws
    /// The contact owning `address` (callsign or SMTP form), if any.
    func contact(forAddress address: String) throws -> WinlinkContactRecord?
}

nonisolated final class SQLiteContactStore: ContactStore, @unchecked Sendable {

    private let dbQueue: DatabaseQueue
    private let now: @Sendable () -> Date

    init(dbQueue: DatabaseQueue, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbQueue = dbQueue
        self.now = now
    }

    func contacts() throws -> [WinlinkContactRecord] {
        try dbQueue.read { db in
            try WinlinkContactRecord
                .order(Column("favorite").desc, Column("displayName").collating(.nocase))
                .fetchAll(db)
        }
    }

    func searchContacts(_ query: String) throws -> [WinlinkContactRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return try contacts() }
        let pattern = "%\(trimmed)%"
        return try dbQueue.read { db in
            try WinlinkContactRecord
                .filter(
                    Column("displayName").like(pattern)
                        || Column("callsign").like(pattern)
                        || Column("smtpEmail").like(pattern)
                        || Column("organization").like(pattern))
                .order(Column("favorite").desc, Column("lastUsedAt").desc, Column("displayName").collating(.nocase))
                .fetchAll(db)
        }
    }

    @discardableResult
    func saveContact(_ contact: WinlinkContactRecord) throws -> WinlinkContactRecord {
        var record = contact
        record.displayName = record.displayName.trimmingCharacters(in: .whitespaces)
        record.callsign = record.callsign.trimmingCharacters(in: .whitespaces).uppercased()
        record.smtpEmail = record.smtpEmail.trimmingCharacters(in: .whitespaces)
        guard !record.displayName.isEmpty || !record.callsign.isEmpty || !record.smtpEmail.isEmpty else {
            throw ContactStoreError.emptyName
        }
        if record.displayName.isEmpty {
            record.displayName = record.callsign.isEmpty ? record.smtpEmail : record.callsign
        }
        record.updatedAt = now()

        return try dbQueue.write { db in
            if record.id != nil {
                try record.update(db)
            } else {
                try record.insert(db)
            }
            return record
        }
    }

    func deleteContact(id: Int64) throws {
        try dbQueue.write { db in
            guard try WinlinkContactRecord.deleteOne(db, key: id) else {
                throw ContactStoreError.contactNotFound(id)
            }
        }
    }

    func touchContact(address: String, at date: Date) throws {
        guard var record = try contact(forAddress: address) else { return }
        record.lastUsedAt = date
        record.updatedAt = date
        _ = try dbQueue.write { db in try record.update(db) }
    }

    func contact(forAddress address: String) throws -> WinlinkContactRecord? {
        let normalized = address.trimmingCharacters(in: .whitespaces)
        let bareEmail = normalized.uppercased().hasPrefix("SMTP:")
            ? String(normalized.dropFirst(5)) : normalized
        return try dbQueue.read { db in
            try WinlinkContactRecord
                .filter(
                    Column("callsign").collating(.nocase) == normalized
                        || Column("smtpEmail").collating(.nocase) == bareEmail)
                .fetchOne(db)
        }
    }
}


/// Inert store used when the database is unavailable.
nonisolated final class NullContactStore: ContactStore, @unchecked Sendable {
    func contacts() throws -> [WinlinkContactRecord] { [] }
    func searchContacts(_ query: String) throws -> [WinlinkContactRecord] { [] }
    func saveContact(_ contact: WinlinkContactRecord) throws -> WinlinkContactRecord {
        throw ContactStoreError.emptyName
    }
    func deleteContact(id: Int64) throws { throw ContactStoreError.contactNotFound(id) }
    func touchContact(address: String, at date: Date) throws {}
    func contact(forAddress address: String) throws -> WinlinkContactRecord? { nil }
}
