//
//  OutboundMessageStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 02/07/26.
//

import Foundation

protocol OutboundMessageStore: Sendable {
    func insertQueued(_ message: OutboundMessage) throws
    func updateState(
        id: UUID,
        newState: OutboundMessage.State,
        sentAt: Date?,
        ackedAt: Date?,
        lastError: String?,
        attemptCount: Int,
        bytesAcked: Int
    ) throws
    func fetchNextQueued(sessionId: String) throws -> OutboundMessage?
    func fetchBySession(sessionId: String) throws -> [OutboundMessage]
    func fetchAll() throws -> [OutboundMessage]
    func deleteAll() throws
}
