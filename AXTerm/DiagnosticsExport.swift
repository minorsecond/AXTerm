//
//  DiagnosticsExport.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation

nonisolated struct DiagnosticsReport: Encodable {
    nonisolated struct AppInfo: Encodable {
        let name: String
        let version: String
        let build: String
        let macOSVersion: String
    }

    nonisolated struct SettingsSnapshot: Encodable {
        let host: String
        let port: Int
        let persistHistory: Bool
        let packetRetention: Int
        let consoleRetention: Int
        let rawRetention: Int
        let eventRetention: Int
    }

    nonisolated struct EventSnapshot: Encodable {
        let id: UUID
        let createdAt: Date
        let level: String
        let category: String
        let message: String
        let metadata: [String: String]?
    }

    let app: AppInfo
    let settings: SettingsSnapshot
    let events: [EventSnapshot]
}

nonisolated enum DiagnosticsExporter {
    static func makeReport(settings: AppSettingsStore, events: [AppEventRecord]) -> DiagnosticsReport {
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "AXTerm"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"

        let app = DiagnosticsReport.AppInfo(
            name: name,
            version: version,
            build: build,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )

        let snapshot = DiagnosticsReport.SettingsSnapshot(
            host: settings.host,
            port: settings.port,
            persistHistory: settings.persistHistory,
            packetRetention: settings.retentionLimit,
            consoleRetention: settings.consoleRetentionLimit,
            rawRetention: settings.rawRetentionLimit,
            eventRetention: settings.eventRetentionLimit
        )

        let eventSnapshots = events.map { record in
            DiagnosticsReport.EventSnapshot(
                id: record.id,
                createdAt: record.createdAt,
                level: record.level.rawValue,
                category: record.category.rawValue,
                message: record.message,
                metadata: record.metadataJSON.flatMap(DeterministicJSON.decodeDictionary)
            )
        }

        return DiagnosticsReport(app: app, settings: snapshot, events: eventSnapshots)
    }

    static func makeJSON(report: DiagnosticsReport) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
