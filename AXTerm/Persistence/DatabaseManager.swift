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

    static func makeDatabaseQueue() throws -> DatabaseQueue {
        let url = try databaseURL()
        func openQueue() throws -> DatabaseQueue {
            let queue = try DatabaseQueue(path: url.path)
            try migrator.migrate(queue)
            return queue
        }

        var queue: DatabaseQueue? = try openQueue()
        if let currentQueue = queue, try needsDevReset(currentQueue) {
            let message = "AXTerm: schema mismatch detected for \(url.path)"
            #if DEBUG
            print("\(message) - deleting database in DEBUG.")
            queue = nil
            try? FileManager.default.removeItem(at: url)
            return try openQueue()
            #else
            print("\(message) - refusing to delete database in Release.")
            throw DatabaseManagerError.schemaMismatch
            #endif
        }
        guard let finalQueue = queue else {
            throw DatabaseManagerError.schemaMismatch
        }
        return finalQueue
    }

    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createPackets") { db in
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
        migrator.registerMigration("createConsoleRawEvents") { db in
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
