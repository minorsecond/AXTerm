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
        let queue = try DatabaseQueue(path: url.path)
        try migrator.migrate(queue)
        return queue
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
                table.column("portName", .text)
                table.column("pinned", .boolean).notNull().defaults(to: false)
                table.column("tags", .text)
            }

            try db.create(index: "idx_packets_receivedAt", on: PacketRecord.databaseTableName, columns: ["receivedAt"])
            try db.create(index: "idx_packets_from", on: PacketRecord.databaseTableName, columns: ["fromCall", "fromSSID"])
            try db.create(index: "idx_packets_to", on: PacketRecord.databaseTableName, columns: ["toCall", "toSSID"])
            try db.create(index: "idx_packets_frameType", on: PacketRecord.databaseTableName, columns: ["frameType"])
            try db.create(index: "idx_packets_printable", on: PacketRecord.databaseTableName, columns: ["isPrintableText"])
            try db.create(index: "idx_packets_pinned", on: PacketRecord.databaseTableName, columns: ["pinned"])
            try db.create(index: "idx_packets_viaCount", on: PacketRecord.databaseTableName, columns: ["viaCount"])
            try db.create(index: "idx_packets_from_receivedAt", on: PacketRecord.databaseTableName, columns: ["fromCall", "receivedAt"])
        }
        return migrator
    }()
}
