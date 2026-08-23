import Foundation
import GRDB

// MARK: - Folders

nonisolated struct WinlinkFolderRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    static let databaseTableName = "winlinkFolder"

    /// Roles of the six built-in folders. User folders have a nil role.
    enum SystemRole: String, Codable, CaseIterable, Sendable {
        case inbox, outbox, sent, drafts, archive, trash
    }

    var id: Int64?
    var name: String
    var systemRole: String?
    var sortOrder: Int

    var role: SystemRole? { systemRole.flatMap(SystemRole.init(rawValue:)) }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Messages

/// The immutable message content row. Once a message leaves the `draft`
/// state its content row MUST never change again (CLAUDE.md §7:
/// "Messages are append-only and immutable after delivery") — the store
/// enforces this invariant.
nonisolated struct WinlinkMessageRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static let databaseTableName = "winlinkMessage"

    enum Direction: String, Codable, Sendable {
        case inbound, outbound
    }

    /// Primary key: the Winlink MID.
    var id: String
    var direction: String
    var dateUtc: Date
    var messageType: String
    var fromAddr: String
    /// JSON-encoded array of addresses.
    var toAddrs: String
    var ccAddrs: String
    var subject: String
    var mbo: String
    var body: Data
    var createdAt: Date

    var toAddressList: [String] { Self.decodeAddresses(toAddrs) }
    var ccAddressList: [String] { Self.decodeAddresses(ccAddrs) }

    static func encodeAddresses(_ addresses: [String]) -> String {
        guard let data = try? JSONEncoder().encode(addresses) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeAddresses(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let addresses = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return addresses
    }
}

/// The mutable per-message state row (folder, read flag, delivery state).
nonisolated struct WinlinkMessageStateRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static let databaseTableName = "winlinkMessageState"

    enum DeliveryState: String, Codable, Sendable {
        case draft      // mutable, lives in Drafts
        case queued     // frozen, waiting in Outbox
        case sending    // proposed/accepted in the current session
        case sent       // delivered to a gateway, lives in Sent
        case failed     // rejected or errored, stays in Outbox
        case received   // inbound mail
    }

    var messageId: String
    var folderId: Int64
    var isRead: Bool
    var deliveryState: String
    /// Compressed-stream offset confirmed by the remote (partial resume).
    var sentOffset: Int
    var lastError: String?
    var updatedAt: Date

    var state: DeliveryState? { DeliveryState(rawValue: deliveryState) }
}

nonisolated struct WinlinkAttachmentRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    static let databaseTableName = "winlinkAttachment"

    var id: Int64?
    var messageId: String
    var position: Int
    var name: String
    var size: Int
    var data: Data

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - RMS station cache

nonisolated struct WinlinkRMSStationRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable, Identifiable {
    static let databaseTableName = "winlinkRMSStation"

    /// Table identity: one row per callsign + frequency (the DB primary key).
    var id: String { "\(callsign)@\(frequencyHz)" }

    var callsign: String
    var gridSquare: String
    var frequencyHz: Int
    var modeName: String
    var baud: String
    var serviceCode: String
    var distanceMiles: Double
    var headingDegrees: Double
    var lastSeenAt: Date?
    var fetchedAt: Date
}

// MARK: - Catalog cache

nonisolated struct WinlinkCatalogItemRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static let databaseTableName = "winlinkCatalogItem"

    var inquiryId: String
    var category: String
    var subject: String
    var url: String
    var lifetimeDays: Int
    var sizeEstimate: Int
    var enabled: Bool
    var fetchedAt: Date
}

// MARK: - Session log

nonisolated struct WinlinkSessionLogRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    static let databaseTableName = "winlinkSessionLog"

    var id: Int64?
    var startedAt: Date
    var endedAt: Date
    var gatewayCallsign: String
    var transport: String
    var result: String
    var messagesSent: Int
    var messagesReceived: Int
    var bytesSent: Int
    var bytesReceived: Int
    var errorText: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
