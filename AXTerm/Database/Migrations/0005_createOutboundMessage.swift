//
//  0005_createOutboundMessage.swift
//  AXTerm
//
//  Created by Ross Wardrup on 02/07/26.
//

import Foundation
import GRDB

extension DatabaseManager {
    static func createOutboundMessageTable(_ db: Database) throws {
        try db.create(table: OutboundMessage.databaseTableName) { table in
            table.column("id", .text).primaryKey()
            table.column("sessionId", .text).notNull()
            table.column("destCallsign", .text).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("payload", .blob).notNull()
            table.column("mode", .text).notNull()
            table.column("state", .text).notNull()
            table.column("attemptCount", .integer).notNull()
            table.column("lastError", .text)
            table.column("bytesTotal", .integer).notNull()
            table.column("bytesAcked", .integer).notNull()
            table.column("sentAt", .datetime)
            table.column("ackedAt", .datetime)
        }

        try db.create(
            index: "idx_outbound_session_created",
            on: OutboundMessage.databaseTableName,
            columns: ["sessionId", "createdAt"]
        )
        
        try db.create(
            index: "idx_outbound_state_session",
            on: OutboundMessage.databaseTableName,
            columns: ["state", "sessionId"]
        )
    }
}
