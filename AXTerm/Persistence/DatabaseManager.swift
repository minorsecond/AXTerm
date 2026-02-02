//
//  DatabaseManager.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
import GRDB

enum DatabaseManager {
    static let folderName = "AXTerm"
    static let databaseName = "axterm.sqlite"

    static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folderURL = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL.appendingPathComponent(databaseName)
    }

    @MainActor
    static func makeDatabaseQueue() throws -> DatabaseQueue {
        let url = try databaseURL()
        let urlPath = url.path

        // Breadcrumbs are dispatched to main actor asynchronously to avoid blocking migrations.
        func breadcrumbOpenSuccess() {
            Task { @MainActor in
                SentryManager.shared.breadcrumbDatabaseOpen(success: true, path: urlPath)
            }
        }

        func breadcrumbOpenFailure(_ error: Error) {
            Task { @MainActor in
                SentryManager.shared.breadcrumbDatabaseOpen(success: false, path: urlPath)
                SentryManager.shared.capturePersistenceFailure("database open", error: error)
            }
        }

        func openQueue() throws -> DatabaseQueue {
            do {
                let queue = try DatabaseQueue(path: urlPath)
                breadcrumbOpenSuccess()
                try migrator.migrate(queue)
                return queue
            } catch {
                breadcrumbOpenFailure(error)
                throw error
            }
        }

        var queue: DatabaseQueue? = try openQueue()
        if let currentQueue = queue, try needsDevReset(currentQueue) {
            let message = "AXTerm: schema mismatch detected for \(urlPath)"
            #if DEBUG
            print("\(message) - deleting database in DEBUG.")
            Task { @MainActor in
                SentryManager.shared.addBreadcrumb(
                    category: "db.lifecycle",
                    message: "Schema mismatch - deleting database (DEBUG)",
                    level: .warning,
                    data: ["path": urlPath]
                )
            }
            queue = nil
            try? FileManager.default.removeItem(at: url)
            return try openQueue()
            #else
            print("\(message) - refusing to delete database in Release.")
            Task { @MainActor in
                SentryManager.shared.captureMessage(
                    "Database schema mismatch in Release build",
                    level: .error,
                    extra: ["path": urlPath]
                )
            }
            throw DatabaseManagerError.schemaMismatch
            #endif
        }
        guard let finalQueue = queue else {
            throw DatabaseManagerError.schemaMismatch
        }
        return finalQueue
    }

    // MARK: - Migration Table Creation (extracted for reuse)

    private static func createPacketsTable(_ db: Database) throws {
        try db.create(table: PacketRecord.databaseTableName) { table in
            table.column("id", .text).primaryKey()
            table.column("receivedAt", .datetime).notNull()
            table.column("ax25Timestamp", .datetime)
            table.column("direction", .text).notNull()
            table.column("source", .text).notNull()
            table.column("fromCall", .text).notNull()
            table.column("fromSSID", .integer).notNull()
            table.column("toCall", .text).notNull()
            table.column("toSSID", .integer).notNull()
            table.column("viaPath", .text).notNull()
            table.column("viaCount", .integer).notNull()
            table.column("hasDigipeaters", .boolean).notNull()
            table.column("frameType", .text).notNull()
            table.column("controlHex", .text).notNull()
            table.column("pid", .integer)
            table.column("infoLen", .integer).notNull()
            table.column("isPrintableText", .boolean).notNull()
            table.column("infoText", .text)
            table.column("infoASCII", .text).notNull()
            table.column("infoHex", .text).notNull()
            table.column("rawAx25Hex", .text).notNull()
            table.column("rawAx25Bytes", .blob).notNull()
            table.column("infoBytes", .blob).notNull()
            table.column("portName", .text)
            table.column("kissHost", .text).notNull()
            table.column("kissPort", .integer).notNull()
            table.column("pinned", .boolean).notNull().defaults(to: false)
            table.column("tags", .text)
        }

        try db.create(index: "idx_packets_receivedAt", on: PacketRecord.databaseTableName, columns: ["receivedAt"])
        try db.create(index: "idx_packets_from_receivedAt", on: PacketRecord.databaseTableName, columns: ["fromCall", "fromSSID", "receivedAt"])
        try db.create(index: "idx_packets_to_receivedAt", on: PacketRecord.databaseTableName, columns: ["toCall", "toSSID", "receivedAt"])
        try db.create(index: "idx_packets_frameType", on: PacketRecord.databaseTableName, columns: ["frameType"])
        try db.create(index: "idx_packets_pid", on: PacketRecord.databaseTableName, columns: ["pid"])
        try db.create(index: "idx_packets_printable", on: PacketRecord.databaseTableName, columns: ["isPrintableText"])
        try db.create(index: "idx_packets_pinned", on: PacketRecord.databaseTableName, columns: ["pinned"])
        try db.create(index: "idx_packets_viaCount", on: PacketRecord.databaseTableName, columns: ["viaCount"])
        try db.create(index: "idx_packets_hasDigipeaters", on: PacketRecord.databaseTableName, columns: ["hasDigipeaters"])
        try db.create(index: "idx_packets_kissEndpoint", on: PacketRecord.databaseTableName, columns: ["kissHost", "kissPort"])
        try db.create(index: "idx_packets_frameType_receivedAt", on: PacketRecord.databaseTableName, columns: ["frameType", "receivedAt"])
        try db.create(index: "idx_packets_pinned_receivedAt", on: PacketRecord.databaseTableName, columns: ["pinned", "receivedAt"])

        try db.execute(sql: """
            CREATE VIEW v_daily_counts AS
            SELECT date(receivedAt) AS day,
                   COUNT(*) AS packetCount
            FROM \(PacketRecord.databaseTableName)
            GROUP BY day
            """)

        try db.execute(sql: """
            CREATE VIEW v_station_counts AS
            SELECT fromCall,
                   fromSSID,
                   COUNT(*) AS packetCount,
                   MAX(receivedAt) AS lastReceivedAt
            FROM \(PacketRecord.databaseTableName)
            GROUP BY fromCall, fromSSID
            """)
    }

    private static func addControlFieldColumns(_ db: Database) throws {
        // Add AX.25 control field decoded columns to packets table
        try db.alter(table: PacketRecord.databaseTableName) { table in
            table.add(column: "ax25FrameClass", .text)      // "I", "S", "U", or "unknown"
            table.add(column: "ax25SType", .text)           // "RR", "RNR", "REJ", "SREJ" (S-frames only)
            table.add(column: "ax25UType", .text)           // "UI", "SABM", etc. (U-frames only)
            table.add(column: "ax25Ns", .integer)           // N(S) for I-frames
            table.add(column: "ax25Nr", .integer)           // N(R) for I/S frames
            table.add(column: "ax25Pf", .integer)           // Poll/Final bit (0/1)
            table.add(column: "ax25Ctl0", .integer)         // Raw first control byte
            table.add(column: "ax25Ctl1", .integer)         // Raw second control byte (if present)
            table.add(column: "ax25IsExtended", .integer).defaults(to: 0)  // Extended mode flag
        }

        // Create index for frame class queries
        try db.create(
            index: "idx_packets_ax25FrameClass",
            on: PacketRecord.databaseTableName,
            columns: ["ax25FrameClass"]
        )
    }

    /// Fix incorrectly decoded control field values for existing packets.
    /// This recomputes ax25Ns, ax25Nr, and ax25Pf from the raw control byte (ax25Ctl0).
    ///
    /// I-frame control byte format (modulo-8): NNNPSSS0
    /// - bits 5-7: N(R)
    /// - bit 4: P/F
    /// - bits 1-3: N(S)
    /// - bit 0: 0 (I-frame indicator)
    ///
    /// S-frame control byte format: NNNPSS01
    /// - bits 5-7: N(R)
    /// - bit 4: P/F
    /// - bits 2-3: subtype
    /// - bits 0-1: 01 (S-frame indicator)
    private static func fixControlFieldDecoding(_ db: Database) throws {
        // Fix I-frame decoding: recompute N(S), N(R), P/F from raw control byte
        try db.execute(sql: """
            UPDATE \(PacketRecord.databaseTableName)
            SET ax25Ns = (ax25Ctl0 >> 1) & 7,
                ax25Nr = (ax25Ctl0 >> 5) & 7,
                ax25Pf = (ax25Ctl0 >> 4) & 1
            WHERE ax25FrameClass = 'I' AND ax25Ctl0 IS NOT NULL
            """)

        // Fix S-frame decoding: recompute N(R), P/F from raw control byte
        try db.execute(sql: """
            UPDATE \(PacketRecord.databaseTableName)
            SET ax25Nr = (ax25Ctl0 >> 5) & 7,
                ax25Pf = (ax25Ctl0 >> 4) & 1
            WHERE ax25FrameClass = 'S' AND ax25Ctl0 IS NOT NULL
            """)
    }

    private static func createConsoleRawEventsTables(_ db: Database) throws {
        try db.create(table: ConsoleEntryRecord.databaseTableName) { table in
            table.column("id", .text).primaryKey()
            table.column("createdAt", .datetime).notNull()
            table.column("level", .text).notNull()
            table.column("category", .text).notNull()
            table.column("message", .text).notNull()
            table.column("packetID", .text)
            table.column("metadataJSON", .text)
            table.column("byteCount", .integer)
        }
        try db.create(index: "idx_console_createdAt", on: ConsoleEntryRecord.databaseTableName, columns: ["createdAt"])
        try db.create(index: "idx_console_level_category", on: ConsoleEntryRecord.databaseTableName, columns: ["level", "category"])

        try db.create(table: RawEntryRecord.databaseTableName) { table in
            table.column("id", .text).primaryKey()
            table.column("createdAt", .datetime).notNull()
            table.column("source", .text).notNull()
            table.column("direction", .text).notNull()
            table.column("kind", .text).notNull()
            table.column("rawHex", .text).notNull()
            table.column("byteCount", .integer).notNull()
            table.column("packetID", .text)
            table.column("metadataJSON", .text)
        }
        try db.create(index: "idx_raw_createdAt", on: RawEntryRecord.databaseTableName, columns: ["createdAt"])
        try db.create(index: "idx_raw_kind_source", on: RawEntryRecord.databaseTableName, columns: ["kind", "source"])

        try db.create(table: AppEventRecord.databaseTableName) { table in
            table.column("id", .text).primaryKey()
            table.column("createdAt", .datetime).notNull()
            table.column("level", .text).notNull()
            table.column("category", .text).notNull()
            table.column("message", .text).notNull()
            table.column("metadataJSON", .text)
        }
        try db.create(index: "idx_events_createdAt", on: AppEventRecord.databaseTableName, columns: ["createdAt"])
        try db.create(index: "idx_events_level_category", on: AppEventRecord.databaseTableName, columns: ["level", "category"])
    }

    /// Migrator with Sentry breadcrumbs dispatched asynchronously.
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createPackets") { db in
            Task { @MainActor in
                SentryManager.shared.addBreadcrumb(
                    category: "db.migration",
                    message: "Running migration v1 (createPackets)",
                    level: .info,
                    data: nil
                )
            }
            try createPacketsTable(db)
            Task { @MainActor in
                SentryManager.shared.breadcrumbDatabaseMigration(version: 1, success: true)
            }
        }
        migrator.registerMigration("createConsoleRawEvents") { db in
            Task { @MainActor in
                SentryManager.shared.addBreadcrumb(
                    category: "db.migration",
                    message: "Running migration v2 (createConsoleRawEvents)",
                    level: .info,
                    data: nil
                )
            }
            try createConsoleRawEventsTables(db)
            Task { @MainActor in
                SentryManager.shared.breadcrumbDatabaseMigration(version: 2, success: true)
            }
        }
        migrator.registerMigration("addControlFieldColumns") { db in
            Task { @MainActor in
                SentryManager.shared.addBreadcrumb(
                    category: "db.migration",
                    message: "Running migration v3 (addControlFieldColumns)",
                    level: .info,
                    data: nil
                )
            }
            try addControlFieldColumns(db)
            Task { @MainActor in
                SentryManager.shared.breadcrumbDatabaseMigration(version: 3, success: true)
            }
        }
        migrator.registerMigration("fixControlFieldDecoding") { db in
            Task { @MainActor in
                SentryManager.shared.addBreadcrumb(
                    category: "db.migration",
                    message: "Running migration v4 (fixControlFieldDecoding)",
                    level: .info,
                    data: nil
                )
            }
            try fixControlFieldDecoding(db)
            Task { @MainActor in
                SentryManager.shared.breadcrumbDatabaseMigration(version: 4, success: true)
            }
        }
        return migrator
    }()

    private static func needsDevReset(_ queue: DatabaseQueue) throws -> Bool {
        try queue.read { db in
            guard try db.tableExists(PacketRecord.databaseTableName) else { return false }
            let columns = try db.columns(in: PacketRecord.databaseTableName).map(\.name)
            let required: Set<String> = [
                "id",
                "receivedAt",
                "ax25Timestamp",
                "direction",
                "source",
                "fromCall",
                "fromSSID",
                "toCall",
                "toSSID",
                "viaPath",
                "viaCount",
                "hasDigipeaters",
                "frameType",
                "controlHex",
                "pid",
                "infoLen",
                "isPrintableText",
                "infoText",
                "infoASCII",
                "infoHex",
                "rawAx25Hex",
                "rawAx25Bytes",
                "infoBytes",
                "portName",
                "kissHost",
                "kissPort",
                "pinned",
                "tags"
            ]
            return !required.isSubset(of: Set(columns))
        }
    }
}

enum DatabaseManagerError: Error {
    case schemaMismatch
}
