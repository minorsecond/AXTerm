import Foundation
import GRDB

/// Schema for the Winlink radiomail subsystem (migration v5).
extension DatabaseManager {

    static func createWinlinkTables(_ db: Database) throws {
        try db.create(table: WinlinkFolderRecord.databaseTableName) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("systemRole", .text).unique()
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
        }

        try db.create(table: WinlinkMessageRecord.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("direction", .text).notNull()
            t.column("dateUtc", .datetime).notNull()
            t.column("messageType", .text).notNull()
            t.column("fromAddr", .text).notNull()
            t.column("toAddrs", .text).notNull()
            t.column("ccAddrs", .text).notNull()
            t.column("subject", .text).notNull()
            t.column("mbo", .text).notNull()
            t.column("body", .blob).notNull()
            t.column("createdAt", .datetime).notNull()
        }

        try db.create(table: WinlinkMessageStateRecord.databaseTableName) { t in
            t.primaryKey("messageId", .text)
                .references(WinlinkMessageRecord.databaseTableName, onDelete: .cascade)
            t.column("folderId", .integer).notNull()
                .references(WinlinkFolderRecord.databaseTableName)
            t.column("isRead", .boolean).notNull().defaults(to: false)
            t.column("deliveryState", .text).notNull()
            t.column("sentOffset", .integer).notNull().defaults(to: 0)
            t.column("lastError", .text)
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(
            index: "idx_winlinkMessageState_folder",
            on: WinlinkMessageStateRecord.databaseTableName,
            columns: ["folderId", "updatedAt"])
        try db.create(
            index: "idx_winlinkMessageState_isRead",
            on: WinlinkMessageStateRecord.databaseTableName,
            columns: ["isRead"])

        try db.create(table: WinlinkAttachmentRecord.databaseTableName) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("messageId", .text).notNull()
                .references(WinlinkMessageRecord.databaseTableName, onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("name", .text).notNull()
            t.column("size", .integer).notNull()
            t.column("data", .blob).notNull()
        }
        try db.create(
            index: "idx_winlinkAttachment_message",
            on: WinlinkAttachmentRecord.databaseTableName,
            columns: ["messageId"])

        try db.create(table: WinlinkRMSStationRecord.databaseTableName) { t in
            t.column("callsign", .text).notNull()
            t.column("gridSquare", .text).notNull()
            t.column("frequencyHz", .integer).notNull()
            t.column("modeName", .text).notNull()
            t.column("baud", .text).notNull()
            t.column("serviceCode", .text).notNull()
            t.column("distanceMiles", .double).notNull()
            t.column("headingDegrees", .double).notNull()
            t.column("lastSeenAt", .datetime)
            t.column("fetchedAt", .datetime).notNull()
            t.primaryKey(["callsign", "frequencyHz"])
        }

        try db.create(table: WinlinkCatalogItemRecord.databaseTableName) { t in
            t.primaryKey("inquiryId", .text)
            t.column("category", .text).notNull()
            t.column("subject", .text).notNull()
            t.column("url", .text).notNull()
            t.column("lifetimeDays", .integer).notNull().defaults(to: 0)
            t.column("sizeEstimate", .integer).notNull().defaults(to: 0)
            t.column("enabled", .boolean).notNull().defaults(to: true)
            t.column("fetchedAt", .datetime).notNull()
        }

        try db.create(table: WinlinkSessionLogRecord.databaseTableName) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startedAt", .datetime).notNull()
            t.column("endedAt", .datetime).notNull()
            t.column("gatewayCallsign", .text).notNull()
            t.column("transport", .text).notNull()
            t.column("result", .text).notNull()
            t.column("messagesSent", .integer).notNull().defaults(to: 0)
            t.column("messagesReceived", .integer).notNull().defaults(to: 0)
            t.column("bytesSent", .integer).notNull().defaults(to: 0)
            t.column("bytesReceived", .integer).notNull().defaults(to: 0)
            t.column("errorText", .text)
        }

        try seedSystemFolders(db)
    }

    static func createWinlinkContacts(_ db: Database) throws {
        try db.create(table: WinlinkContactRecord.databaseTableName) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("displayName", .text).notNull()
            t.column("callsign", .text).notNull().defaults(to: "")
            t.column("smtpEmail", .text).notNull().defaults(to: "")
            t.column("phone", .text).notNull().defaults(to: "")
            t.column("organization", .text).notNull().defaults(to: "")
            t.column("positionTitle", .text).notNull().defaults(to: "")
            t.column("gridSquare", .text).notNull().defaults(to: "")
            t.column("street", .text).notNull().defaults(to: "")
            t.column("city", .text).notNull().defaults(to: "")
            t.column("state", .text).notNull().defaults(to: "")
            t.column("postalCode", .text).notNull().defaults(to: "")
            t.column("notes", .text).notNull().defaults(to: "")
            t.column("favorite", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("lastUsedAt", .datetime)
        }
        try db.create(
            index: "idx_winlinkContact_callsign",
            on: WinlinkContactRecord.databaseTableName,
            columns: ["callsign"])
        try db.create(
            index: "idx_winlinkContact_name",
            on: WinlinkContactRecord.databaseTableName,
            columns: ["displayName"])
    }

    static func createWinlinkPartialBodies(_ db: Database) throws {
        try db.create(table: WinlinkPartialBodyRecord.databaseTableName) { t in
            t.primaryKey("mid", .text)
            t.column("compressedSize", .integer).notNull()
            t.column("data", .blob).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
    }

    /// Adds link identity (frequency) and observation position to the
    /// session log so empirical link quality can be attributed to the
    /// right link and qualified by where it was measured from.
    ///
    /// All columns are nullable: rows written before this migration have
    /// no position, and telnet sessions have no frequency. A nil is
    /// "unknown", never "zero" — the quality query must treat it as
    /// unattributable rather than assume the operator's current QTH.
    static func addWinlinkSessionLogContext(_ db: Database) throws {
        try db.alter(table: WinlinkSessionLogRecord.databaseTableName) { t in
            t.add(column: "frequencyHz", .integer)
            t.add(column: "obsLatitude", .double)
            t.add(column: "obsLongitude", .double)
            t.add(column: "obsGrid", .text)
            t.add(column: "obsSource", .text)
        }
        // Quality lookups scan by link; the log grows one row per exchange.
        try db.create(
            index: "winlinkSessionLog_link",
            on: WinlinkSessionLogRecord.databaseTableName,
            columns: ["gatewayCallsign", "frequencyHz", "startedAt"],
            ifNotExists: true)
    }

    /// Starred catalog products (migration v9). Separate from the
    /// catalog cache on purpose — see `WinlinkCatalogFavoriteRecord`.
    static func createWinlinkCatalogFavorites(_ db: Database) throws {
        try db.create(table: WinlinkCatalogFavoriteRecord.databaseTableName) { t in
            t.primaryKey("inquiryId", .text)
            t.column("addedAt", .datetime).notNull()
        }
    }

    /// Cached callsign-directory answers (migration v10). Source-agnostic
    /// by design — the `source` column records which directory answered,
    /// so HamDB today and anything else later share one cache.
    /// Splits the gateway cache into what is near home and what was fetched
    /// for a trip.
    ///
    /// `gateway/status.json` has no geographic filter — it returns every
    /// public gateway in the world and the radius is applied on this device.
    /// So the wide list was already being downloaded and then discarded. The
    /// only thing missing was somewhere to keep it that an ordinary refresh
    /// near home would not wipe.
    static func addStationScope(_ db: Database) throws {
        // Existing rows were fetched under the local radius, so that is what
        // they are.
        try db.alter(table: WinlinkRMSStationRecord.databaseTableName) { t in
            t.add(column: "scope", .text).notNull().defaults(to: "local")
        }
        // The list filters by scope on every read.
        try db.create(
            index: "idx_winlinkRMSStation_scope",
            on: WinlinkRMSStationRecord.databaseTableName,
            columns: ["scope", "distanceMiles"])
    }

    static func createCallsignDirectory(_ db: Database) throws {
        try db.create(table: CallsignDirectoryRecord.databaseTableName) { t in
            t.primaryKey("callsign", .text)
            t.column("name", .text)
            t.column("gridSquare", .text)
            t.column("latitude", .double)
            t.column("longitude", .double)
            t.column("locality", .text)
            t.column("state", .text)
            t.column("country", .text)
            t.column("licenseClass", .text)
            t.column("expires", .text)
            t.column("source", .text).notNull()
            t.column("fetchedAt", .datetime).notNull()
        }
    }

    private static func seedSystemFolders(_ db: Database) throws {
        let seeds: [(WinlinkFolderRecord.SystemRole, String, Int)] = [
            (.inbox, "Inbox", 0),
            (.outbox, "Outbox", 1),
            (.drafts, "Drafts", 2),
            (.sent, "Sent", 3),
            (.archive, "Archive", 4),
            (.trash, "Trash", 5),
        ]
        for (role, name, order) in seeds {
            var folder = WinlinkFolderRecord(id: nil, name: name, systemRole: role.rawValue, sortOrder: order)
            try folder.insert(db)
        }
    }
}
