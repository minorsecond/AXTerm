//
//  OutboundMessage.swift
//  AXTerm
//
//  Created by Ross Wardrup on 02/07/26.
//

import Foundation
import GRDB

/// Represents an outbound message queued for transmission.
///
/// Future mapping to AXDP MSG_ID:
/// When AXDP is fully implemented, this model will likely need to store the assigned MSG_ID
/// to correlate acknowledgments at the AXDP layer. For now, we track state and bytes verified
/// via the link layer.
struct OutboundMessage: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "outbound_message"

    enum Mode: String, Codable, Sendable {
        case line
        case block
    }

    enum State: String, Codable, Sendable {
        case queued
        case sending
        case sent
        case retrying
        case failed
    }

    var id: UUID
    var sessionId: String
    var destCallsign: String
    var createdAt: Date
    var payload: Data
    var mode: Mode
    var state: State
    var attemptCount: Int
    var lastError: String?
    var bytesTotal: Int
    var bytesAcked: Int
    var sentAt: Date?
    var ackedAt: Date?

    init(
        id: UUID = UUID(),
        sessionId: String,
        destCallsign: String,
        createdAt: Date = Date(),
        payload: Data,
        mode: Mode
    ) {
        self.id = id
        self.sessionId = sessionId
        self.destCallsign = destCallsign
        self.createdAt = createdAt
        self.payload = payload
        self.mode = mode
        self.state = .queued
        self.attemptCount = 0
        self.lastError = nil
        self.bytesTotal = payload.count
        self.bytesAcked = 0
        self.sentAt = nil
        self.ackedAt = nil
    }

    /// Helper to initialize from string with encoding
    init(
        id: UUID = UUID(),
        sessionId: String,
        destCallsign: String,
        createdAt: Date = Date(),
        text: String,
        encoding: String.Encoding = .utf8,
        mode: Mode
    ) {
        let data = text.data(using: encoding) ?? Data()
        self.init(
            id: id,
            sessionId: sessionId,
            destCallsign: destCallsign,
            createdAt: createdAt,
            payload: data,
            mode: mode
        )
    }

    // MARK: - State Machine

    /// Validates allowed state transitions.
    func canTransition(to newState: State) -> Bool {
        switch (self.state, newState) {
        case (.queued, .sending): return true
        case (.queued, .failed): return true // Failed before sending (e.g. queue full/cancelled)

        case (.sending, .sent): return true
        case (.sending, .retrying): return true
        case (.sending, .failed): return true

        case (.retrying, .sending): return true
        case (.retrying, .failed): return true

        // Terminal states
        case (.sent, _): return false
        case (.failed, _): return false

        // No-op or invalid
        default: return false
        }
    }
}
