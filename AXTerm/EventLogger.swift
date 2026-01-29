//
//  EventLogger.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation
import OSLog

@MainActor
protocol EventLogger {
    func log(level: AppEventRecord.Level, category: AppEventRecord.Category, message: String, metadata: [String: String]?)
}

@MainActor
final class DatabaseEventLogger: EventLogger {
    private let store: EventLogStore
    private let settings: AppSettingsStore
    private let logger = Logger(subsystem: "AXTerm", category: "Diagnostics")

    init(store: EventLogStore, settings: AppSettingsStore) {
        self.store = store
        self.settings = settings
    }

    func log(level: AppEventRecord.Level, category: AppEventRecord.Category, message: String, metadata: [String: String]?) {
        let metadataJSON = metadata.flatMap(DeterministicJSON.encodeDictionary)
        let entry = AppEventRecord(
            id: UUID(),
            createdAt: Date(),
            level: level,
            category: category,
            message: message,
            metadataJSON: metadataJSON
        )

        logToOSLog(entry)

        let retentionLimit = settings.eventRetentionLimit
        DispatchQueue.global(qos: .utility).async { [store, retentionLimit] in
            do {
                try store.append(entry)
                try store.pruneIfNeeded(retentionLimit: retentionLimit)
            } catch {
                return
            }
        }
    }

    private func logToOSLog(_ entry: AppEventRecord) {
        switch entry.level {
        case .info:
            logger.info("\(entry.category.rawValue): \(entry.message, privacy: .public)")
        case .warning:
            logger.warning("\(entry.category.rawValue): \(entry.message, privacy: .public)")
        case .error:
            logger.error("\(entry.category.rawValue): \(entry.message, privacy: .public)")
        }
    }
}

@MainActor
final class NoopEventLogger: EventLogger {
    func log(level: AppEventRecord.Level, category: AppEventRecord.Category, message: String, metadata: [String: String]?) {
        return
    }
}
