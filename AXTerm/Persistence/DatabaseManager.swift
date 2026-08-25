//
//  DatabaseManager.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
import GRDB

nonisolated enum DatabaseManager {
    static let folderName = "AXTerm"
    static let databaseName = "axterm.sqlite"
    private static let busyTimeoutMilliseconds = 8_000

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

    /// Creates a temporary database URL for test mode.
    /// Each instance gets a unique database based on the instance identifier.
    static func ephemeralDatabaseURL(instanceID: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let testFolder = tempDir.appendingPathComponent("AXTerm-Test", isDirectory: true)
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)

        // Sanitize instance ID for use in filename
        let sanitizedID = instanceID
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let dbName = "axterm-test-\(sanitizedID).sqlite"
        return testFolder.appendingPathComponent(dbName)
    }

    /// Creates a database queue for test mode with an ephemeral database.
    /// The database is created fresh each time (previous test data is deleted).
    @MainActor
    static func makeEphemeralDatabaseQueue(instanceID: String) throws -> DatabaseQueue {
        let url = try ephemeralDatabaseURL(instanceID: instanceID)
        let urlPath = url.path

        // Delete any existing test database to start fresh
        try? FileManager.default.removeItem(at: url)

        print("AXTerm Test Mode: Using ephemeral database at \(urlPath)")

        do {
            let queue = try DatabaseQueue(path: urlPath)
            try configureDatabase(queue)
            try migrator.migrate(queue)
            return queue
        } catch {
            print("AXTerm Test Mode: Failed to create ephemeral database: \(error)")
            throw error
        }
    }

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
                try configureDatabase(queue)

                // Run migrations BEFORE declaring the open successful: emitting
                // the success crumb first produced the contradictory pair
                // "open: success" → "open: failure" whenever a migration threw.
                try migrator.migrate(queue)
                breadcrumbOpenSuccess()
                
                // Enable incremental vacuum mode for automatic space reclamation
                // Check if we need to enable it
                let needsVacuum = try queue.read { db in
                    let autoVacuum = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
                    return autoVacuum != 2
                }
                
                if needsVacuum {
                    // Set the pragma in a write transaction
                    try queue.write { db in
                        try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                    }
                    // VACUUM must run OUTSIDE of a transaction
                    try queue.vacuum()
                    Task { @MainActor in
                        SentryManager.shared.addBreadcrumb(
                            category: "db.lifecycle",
                            message: "Enabled incremental vacuum mode",
                            level: .info,
                            data: ["path": urlPath]
                        )
                    }
                }
                
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

    private static func configureDatabase(_ queue: DatabaseQueue) throws {
        try queue.writeWithoutTransaction { db in
            // WAL improves reader/writer concurrency and reduces lock contention.
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
            try db.execute(sql: "PRAGMA busy_timeout = \(busyTimeoutMilliseconds)")
        }
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

    /// What the operator's *other* stations heard (migration v11).
    ///
    /// A table of its own, and that is the point. These rows are
    /// observations made by a different antenna in a different place; no
    /// query that feeds routing inference may reach them, and giving them
    /// their own table makes that structural rather than a convention
    /// someone has to remember. See `WinlinkSyncPolicy.attributed`.
    ///
    /// Keyed on observer *and* subject: two receivers hearing one callsign
    /// are two facts, and a single-column key would let the later sync
    /// silently overwrite the earlier station's view.
    /// Time series of directed link quality.
    ///
    /// `link_stats` holds only the *current* estimate per link, so the app
    /// could say what a path is like now and never what it had been. A
    /// station that degrades over an afternoon looked identical to one that
    /// was always poor. This is append-only and pruned by age.
    ///
    /// Sampled from the NET/ROM snapshot save, which already runs about once
    /// a minute with the stats in hand — no new timer, and that cadence is
    /// already proven not to cost anything.
    /// What the operator knows about a station that no directory does.
    ///
    /// Antenna, which repeater it sits on, who runs it, when they are usually
    /// on, the fact that it answers on 145.050 but not 145.030 — the local
    /// knowledge a packet operator accumulates and currently keeps on paper.
    ///
    /// Keyed by the callsign exactly as displayed, SSID included, because
    /// `K0NTS-1` and `K0NTS-10` are different services and a note about the
    /// mailbox is not a note about the node.
    /// The directory the network publishes about itself.
    ///
    /// Most networks never broadcast NET/ROM `NODES`, so there is nothing to
    /// listen for on that channel — but nodes, BBSs and digipeaters identify
    /// themselves anyway, because ID is a licence requirement and operators
    /// fill it with a service list. Collected passively, it needs no internet
    /// and no registry.
    ///
    /// Durable on purpose. Held only in memory it rebuilt from scratch every
    /// launch, which is the opposite of what a directory is for: the value is
    /// in what was learned over weeks, especially somewhere the operator is
    /// only passing through.
    static func createStationServices(_ db: Database) throws {
        try db.create(table: "station_services") { t in
            t.column("callsign", .text).notNull()
            t.column("service", .text).notNull()
            t.column("alias", .text)
            t.column("confidence", .text).notNull()
            t.column("firstHeard", .datetime).notNull()
            t.column("lastHeard", .datetime).notNull()
            t.column("timesHeard", .integer).notNull().defaults(to: 1)
            t.column("sourceText", .text).notNull().defaults(to: "")
            // One row per claim about a station, so "declared a BBS" and
            // "demonstrated a digipeat" can both be true and both be kept.
            t.primaryKey(["callsign", "service", "confidence"])
        }
        try db.create(
            index: "idx_station_services_callsign",
            on: "station_services",
            columns: ["callsign"])
    }

    /// Antenna height above ground, where the operator knows it.
    ///
    /// Lives with the notes because it is the same kind of fact: something a
    /// human recorded about a station that no directory carries. Nullable
    /// because it is nearly always unknown for a remote station, and a
    /// guessed height presented as a known one would quietly change every
    /// terrain verdict that path appears in.
    static func addStationAntennaHeight(_ db: Database) throws {
        let columns = try db.columns(in: "station_notes").map(\.name)
        guard !columns.contains("antennaHeightMetres") else { return }
        try db.alter(table: "station_notes") { t in
            t.add(column: "antennaHeightMetres", .double)
        }
    }

    static func createStationNotes(_ db: Database) throws {
        try db.create(table: "station_notes") { t in
            t.column("callsign", .text).primaryKey()
            t.column("body", .text).notNull().defaults(to: "")
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        // Photos and files live in their own table: a note is usually text and
        // reading it should not drag megabytes of image off disk with it.
        try db.create(table: "station_attachments") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("callsign", .text).notNull().indexed()
            t.column("kind", .text).notNull()
            t.column("name", .text).notNull()
            t.column("addedAt", .datetime).notNull()
            t.column("byteCount", .integer).notNull()
            t.column("data", .blob).notNull()
        }
    }

    static func createLinkQualityHistory(_ db: Database) throws {
        try db.create(table: "link_quality_history") { t in
            t.column("fromCall", .text).notNull()
            t.column("toCall", .text).notNull()
            t.column("sampledAt", .datetime).notNull()
            t.column("quality", .integer).notNull()
            t.column("dfEstimate", .double)
            t.column("drEstimate", .double)
            t.column("dupCount", .integer).notNull().defaults(to: 0)
        }
        // Reads are always "this link, recent first".
        try db.create(
            index: "idx_link_quality_history_link",
            on: "link_quality_history",
            columns: ["fromCall", "toCall", "sampledAt"])
        // Pruning is by age across every link.
        try db.create(
            index: "idx_link_quality_history_time",
            on: "link_quality_history",
            columns: ["sampledAt"])
    }

    static func createRemoteStationActivity(_ db: Database) throws {
        try db.create(table: "remoteStationActivity") { table in
            table.column("deviceID", .text).notNull()
            table.column("callsign", .text).notNull()
            table.primaryKey(["deviceID", "callsign"])
            table.column("station", .text).notNull()
            table.column("gridSquare", .text)
            table.column("observedAt", .datetime).notNull()
            table.column("roles", .text).notNull()
            table.column("firstHeard", .datetime).notNull()
            table.column("lastHeard", .datetime).notNull()
            table.column("frameCount", .integer).notNull()
            table.column("airtimeSeconds", .double).notNull()
        }
        try db.create(index: "idx_remoteStationActivity_lastHeard",
                      on: "remoteStationActivity", columns: ["lastHeard"])
    }

    /// Register a migration with full Sentry lifecycle reporting: a start
    /// breadcrumb, then either a success breadcrumb or — previously impossible —
    /// a failure breadcrumb plus a captured event naming the migration and
    /// version. Before this, every call site hardcoded `success: true` and a
    /// throwing migration surfaced only as a mislabeled "database open" failure.
    private static func registerReportedMigration(
        _ migrator: inout DatabaseMigrator,
        version: Int,
        name: String,
        body: @escaping @Sendable (Database) throws -> Void
    ) {
        migrator.registerMigration(name) { db in
            Task { @MainActor in
                SentryManager.shared.addBreadcrumb(
                    category: "db.migration",
                    message: "Running migration v\(version) (\(name))",
                    level: .info,
                    data: nil
                )
            }
            do {
                try body(db)
            } catch {
                Task { @MainActor in
                    SentryManager.shared.breadcrumbDatabaseMigration(version: version, success: false)
                    SentryManager.shared.capturePersistenceFailure("migration v\(version) (\(name))", error: error)
                }
                throw error
            }
            Task { @MainActor in
                SentryManager.shared.breadcrumbDatabaseMigration(version: version, success: true)
            }
        }
    }

    /// Migrator with Sentry breadcrumbs dispatched asynchronously.
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        registerReportedMigration(&migrator, version: 1, name: "createPackets") { db in
            try createPacketsTable(db)
        }
        registerReportedMigration(&migrator, version: 2, name: "createConsoleRawEvents") { db in
            try createConsoleRawEventsTables(db)
        }
        registerReportedMigration(&migrator, version: 3, name: "addControlFieldColumns") { db in
            try addControlFieldColumns(db)
        }
        registerReportedMigration(&migrator, version: 4, name: "fixControlFieldDecoding") { db in
            try fixControlFieldDecoding(db)
        }
        registerReportedMigration(&migrator, version: 5, name: "createWinlinkTables") { db in
            try createWinlinkTables(db)
        }
        registerReportedMigration(&migrator, version: 6, name: "createWinlinkContacts") { db in
            try createWinlinkContacts(db)
        }
        registerReportedMigration(&migrator, version: 7, name: "createWinlinkPartialBodies") { db in
            try createWinlinkPartialBodies(db)
        }
        registerReportedMigration(&migrator, version: 8, name: "addWinlinkSessionLogContext") { db in
            try addWinlinkSessionLogContext(db)
        }
        registerReportedMigration(&migrator, version: 9, name: "createWinlinkCatalogFavorites") { db in
            try createWinlinkCatalogFavorites(db)
        }
        registerReportedMigration(&migrator, version: 10, name: "createCallsignDirectory") { db in
            try createCallsignDirectory(db)
        }
        registerReportedMigration(&migrator, version: 11, name: "createRemoteStationActivity") { db in
            try createRemoteStationActivity(db)
        }
        registerReportedMigration(&migrator, version: 12, name: "createLinkQualityHistory") { db in
            try createLinkQualityHistory(db)
        }
        registerReportedMigration(&migrator, version: 13, name: "createStationNotes") { db in
            try createStationNotes(db)
        }
        registerReportedMigration(&migrator, version: 14, name: "addStationScope") { db in
            try addStationScope(db)
        }
        registerReportedMigration(&migrator, version: 15, name: "createStationServices") { db in
            try createStationServices(db)
        }
        registerReportedMigration(&migrator, version: 16, name: "addStationAntennaHeight") { db in
            try addStationAntennaHeight(db)
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

nonisolated enum DatabaseManagerError: Error {
    case schemaMismatch
}
