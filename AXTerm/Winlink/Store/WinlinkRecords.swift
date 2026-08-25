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

    /// Which cache a row belongs to.
    ///
    /// Two sets rather than one radius, because they answer different
    /// questions and are maintained on different schedules. The local set is
    /// "who can I reach from here", refreshed often and kept small enough to
    /// scan. The global set is "who will exist along the route", fetched
    /// deliberately before a trip and — crucially — not destroyed by an
    /// ordinary refresh at home.
    enum Scope: String, Codable, Sendable, CaseIterable {
        case local
        case global

        var label: String {
            switch self {
            case .local: return "Near home"
            case .global: return "Downloaded"
            }
        }
    }

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
    var scope: Scope = .local

    /// The two-character Maidenhead field, which is the only geography this
    /// record actually carries. `DM79GR` is in field `DM`.
    ///
    /// Deliberately not "state" or "country": the CMS gives a grid square and
    /// nothing else, so offering to download "Colorado" would mean inventing
    /// a boundary the data cannot support. A field is about 10 degrees of
    /// longitude by 10 of latitude — coarse, but honest and exactly what a
    /// travelling operator reasons in.
    var gridField: String {
        String(gridSquare.uppercased().prefix(2))
    }
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

    // MARK: Link identity
    //
    // A callsign alone does not identify a link: W0ARP-10 answers on
    // 145.030 and 145.050 at 1200 bd and on 441.075 at 9600 bd, and those
    // behave nothing alike. Quality must be attributed per frequency.
    // Nil on rows written before migration v8, and on telnet sessions.
    var frequencyHz: Int?

    // MARK: Observation position
    //
    // Where the operator was when this session ran. RF reachability is a
    // property of the *pair* of endpoints, so a measurement taken 200 km
    // away says nothing about the link from here. Nil when no position
    // was known (no GPS fix and no configured grid square).
    var obsLatitude: Double?
    var obsLongitude: Double?
    /// Maidenhead locator of `obsLatitude`/`obsLongitude`, for cheap
    /// bucketing without recomputing it on every query.
    var obsGrid: String?
    /// `StationLocation.Source.rawValue` — a GPS fix is good to ~100 m,
    /// a grid square only to the size of the square, and the confidence
    /// wording must not overstate the latter.
    var obsSource: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A catalog product the operator starred.
///
/// Deliberately its own table rather than a flag on
/// `WinlinkCatalogItemRecord`: `replaceCatalogCache` deletes every row in
/// that table on each refresh, so a flag there would be wiped by the next
/// LIST reply. Favourites outlive the cache — and may name a product the
/// current index no longer carries, which is information, not corruption.
nonisolated struct WinlinkCatalogFavoriteRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static let databaseTableName = "winlinkCatalogFavorite"

    var inquiryId: String
    var addedAt: Date
}

/// A cached callsign-directory answer.
///
/// Cached aggressively and **never expired automatically**: a licence
/// address changes rarely, and a stale answer is enormously better than
/// no answer when the network that would refresh it is gone. Age is
/// recorded so the UI can say how old it is; nothing deletes on age.
nonisolated struct CallsignDirectoryRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static let databaseTableName = "callsignDirectory"

    /// Base callsign, SSID stripped — the primary key.
    var callsign: String
    var name: String?
    var gridSquare: String?
    var latitude: Double?
    var longitude: Double?
    var locality: String?
    var state: String?
    var country: String?
    var licenseClass: String?
    var expires: String?
    var source: String
    var fetchedAt: Date
}

// MARK: - Partial inbound bodies (B2F resume)

/// A partially received compressed message body from an interrupted
/// exchange. The next session answers the matching FC proposal with
/// `FS !offset` and stitches the continuation onto `data`.
nonisolated struct WinlinkPartialBodyRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static let databaseTableName = "winlinkPartialBody"

    /// The proposal's MID — primary key; one partial per message.
    var mid: String
    /// Total compressed size the original proposal announced. A future
    /// proposal with a different size is a different encoding and must
    /// not be resumed against this prefix.
    var compressedSize: Int
    var data: Data
    var updatedAt: Date
}
