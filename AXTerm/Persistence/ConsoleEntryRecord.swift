//
//  ConsoleEntryRecord.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation
import GRDB

nonisolated struct ConsoleEntryRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "console_entries"

    enum Level: String, Codable {
        case info
        case warning
        case error
        case system
    }

    enum Category: String, Codable {
        case connection
        case parser
        case store
        case ui
        case packet
        case system
        case transmission
    }

    var id: UUID
    var createdAt: Date
    var level: Level
    var category: Category
    var message: String
    var packetID: UUID?
    var metadataJSON: String?
    var byteCount: Int?

    func toConsoleLine() -> ConsoleLine {
        let metadata = metadataJSON.flatMap { DeterministicJSON.decode(ConsoleMetadata.self, from: $0) }
        return ConsoleLine(
            id: id,
            kind: ConsoleLine.Kind(from: level),
            timestamp: createdAt,
            from: metadata?.from,
            to: metadata?.to,
            text: message,
            via: metadata?.via ?? [],
            subject: ConsoleLine.Subject(stored: metadata?.radios),
            // Re-decoded rather than stored decoded, so a reloaded line reads
            // exactly as a live one does — and reads better than it did if the
            // decoder has improved since it was written.
            aprsInfo: metadata?.aprs.flatMap { Data(base64Encoded: $0) }
        )
    }

    /// Metadata structure for JSON serialization
    private struct ConsoleMetadata: Codable {
        let from: String?
        let to: String?
        let via: [String]?
        /// The radios this line is about. Absent for an app notice and for
        /// every line written before the console attributed them; empty for a
        /// radio that could not be named.
        let radios: [String]?
        /// The APRS information field, base64. Absent on every line written
        /// before the console decoded APRS, and on every line that is not.
        let aprs: String?
    }
}

// Nonisolated, like the type it extends: only the project's main-actor
// default put these members on an actor.
nonisolated private extension ConsoleLine.Kind {
    init(from level: ConsoleEntryRecord.Level) {
        switch level {
        case .system:
            self = .system
        case .error:
            self = .error
        case .warning:
            self = .system
        case .info:
            self = .packet
        }
    }
}

nonisolated extension ConsoleLine.Subject {
    /// Rebuild from what `ConsoleEntryMetadata` stored.
    ///
    /// Nil is the app's — which is also what every line written before the
    /// console attributed them reads as. That is the right answer for the
    /// system notices among them, and for the packet lines it matches the
    /// attribution they already lost on reload.
    init(stored radios: [String]?) {
        guard let radios else { self = .app; return }
        self = radios.isEmpty ? .unnamedRadio : .radios(Set(radios.map(RadioID.init(rawValue:))))
    }
}
