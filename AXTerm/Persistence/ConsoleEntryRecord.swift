//
//  ConsoleEntryRecord.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation
import GRDB

struct ConsoleEntryRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
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
        let metadata = metadataJSON.flatMap(DeterministicJSON.decodeDictionary)
        let from = metadata?["from"]
        let to = metadata?["to"]
        return ConsoleLine(
            id: id,
            kind: ConsoleLine.Kind(from: level),
            timestamp: createdAt,
            from: from,
            to: to,
            text: message
        )
    }
}

private extension ConsoleLine.Kind {
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
