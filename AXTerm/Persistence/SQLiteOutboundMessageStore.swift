//
//  SQLiteOutboundMessageStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 02/07/26.
//

import Foundation
import GRDB

final class SQLiteOutboundMessageStore: OutboundMessageStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    convenience init() throws {
        try self.init(dbQueue: DatabaseManager.makeDatabaseQueue())
    }

    func insertQueued(_ message: OutboundMessage) throws {
        try dbQueue.write { db in
            try message.insert(db)
        }
    }

    func updateState(
        id: UUID,
        newState: OutboundMessage.State,
        sentAt: Date?,
        ackedAt: Date?,
        lastError: String?,
        attemptCount: Int,
        bytesAcked: Int
    ) throws {
        try dbQueue.write { db in
            guard var message = try OutboundMessage.fetchOne(db, key: id) else {
                throw OutboundMessageStoreError.notFound
            }
            
            // Validate transition
            guard message.canTransition(to: newState) else {
                throw OutboundMessageStoreError.invalidTransition(from: message.state, to: newState)
            }

            message.state = newState
            message.sentAt = sentAt ?? message.sentAt
            message.ackedAt = ackedAt ?? message.ackedAt
            message.lastError = lastError ?? message.lastError
            message.attemptCount = attemptCount
            message.bytesAcked = bytesAcked
            
            try message.update(db)
        }
    }

    func fetchNextQueued(sessionId: String) throws -> OutboundMessage? {
        try dbQueue.read { db in
            try OutboundMessage
                .filter(Column("sessionId") == sessionId)
                .filter(Column("state") == OutboundMessage.State.queued.rawValue)
                .order(Column("createdAt").asc, Column("rowid").asc)
                .limit(1)
                .fetchOne(db)
        }
    }

    func fetchBySession(sessionId: String) throws -> [OutboundMessage] {
        try dbQueue.read { db in
            try OutboundMessage
                .filter(Column("sessionId") == sessionId)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }
    
    func fetchAll() throws -> [OutboundMessage] {
        try dbQueue.read { db in
            try OutboundMessage.fetchAll(db)
        }
    }
    
    func deleteAll() throws {
         try dbQueue.write { db in
             _ = try OutboundMessage.deleteAll(db)
         }
     }
}

enum OutboundMessageStoreError: Error {
    case notFound
    case invalidTransition(from: OutboundMessage.State, to: OutboundMessage.State)
}
