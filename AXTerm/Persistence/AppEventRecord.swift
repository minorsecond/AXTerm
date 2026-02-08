//
//  AppEventRecord.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation
import GRDB

struct AppEventRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "app_events"

    enum Level: String, Codable {
        case info
        case warning
        case error
    }

    enum Category: String, Codable {
        case connection
        case parser
        case store
        case ui
        case settings
        case packet
        case watch
        case transmission
    }

    var id: UUID
    var createdAt: Date
    var level: Level
    var category: Category
    var message: String
    var metadataJSON: String?
}
