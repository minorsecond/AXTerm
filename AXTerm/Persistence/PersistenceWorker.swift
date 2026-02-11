//
//  PersistenceWorker.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import Foundation
import GRDB

/// Serializes persistence work off the main actor.
///
/// The underlying stores are synchronous; this actor provides async wrappers so the UI can call them without
/// capturing non-Sendable state in concurrent closures.
actor PersistenceWorker {
    private let packetStore: PacketStore?
    private let consoleStore: ConsoleStore?
    private let rawStore: RawStore?
    private let maxBusyRetryCount = 4
    private let initialBusyRetryDelayNanos: UInt64 = 50_000_000

    init(packetStore: PacketStore?, consoleStore: ConsoleStore?, rawStore: RawStore?) {
        self.packetStore = packetStore
        self.consoleStore = consoleStore
        self.rawStore = rawStore
    }

    func loadPackets(limit: Int) throws -> (packets: [Packet], pinnedIDs: Set<Packet.ID>) {
        guard let packetStore else { return ([], []) }
        let records = try packetStore.loadRecent(limit: limit)
        let packets = records.map { $0.toPacket() }
        let pinnedIDs = Set(records.filter { $0.pinned }.map(\.id))
        return (packets, pinnedIDs)
    }

    func aggregateAnalytics(
        in timeframe: DateInterval,
        bucket: TimeBucket,
        calendar: Calendar,
        options: AnalyticsAggregator.Options
    ) throws -> AnalyticsAggregationResult? {
        guard let store = packetStore as? (any PacketStoreAnalyticsQuerying) else { return nil }
        return try store.aggregateAnalytics(in: timeframe, bucket: bucket, calendar: calendar, options: options)
    }

    func loadPackets(in timeframe: DateInterval) throws -> [Packet]? {
        guard let store = packetStore as? (any PacketStoreTimeRangeQuerying) else { return nil }
        return try store.loadPackets(in: timeframe)
    }

    func loadConsole(limit: Int) throws -> [ConsoleLine] {
        guard let consoleStore else { return [] }
        let records = try consoleStore.loadRecent(limit: limit)
        return records.reversed().map { $0.toConsoleLine() }
    }

    func loadRaw(limit: Int) throws -> [RawChunk] {
        guard let rawStore else { return [] }
        let records = try rawStore.loadRecent(limit: limit)
        return records.reversed().map { $0.toRawChunk() }
    }

    func savePacket(_ packet: Packet, retentionLimit: Int) async throws {
        guard let packetStore else { return }
        try await withDatabaseBusyRetry(operation: "packet.save") {
            try packetStore.save(packet)
        }
        try await withDatabaseBusyRetry(operation: "packet.prune") {
            try packetStore.pruneIfNeeded(retentionLimit: retentionLimit)
        }
    }

    func setPinned(packetId: Packet.ID, pinned: Bool) async throws {
        guard let packetStore else { return }
        try await withDatabaseBusyRetry(operation: "packet.setPinned") {
            try packetStore.setPinned(packetId: packetId, pinned: pinned)
        }
    }

    func appendConsole(_ entry: ConsoleEntryRecord, retentionLimit: Int) async throws {
        guard let consoleStore else { return }
        try await withDatabaseBusyRetry(operation: "console.append") {
            try consoleStore.append(entry)
        }
        try await withDatabaseBusyRetry(operation: "console.prune") {
            try consoleStore.pruneIfNeeded(retentionLimit: retentionLimit)
        }
    }

    func appendRaw(_ entry: RawEntryRecord, retentionLimit: Int) async throws {
        guard let rawStore else { return }
        try await withDatabaseBusyRetry(operation: "raw.append") {
            try rawStore.append(entry)
        }
        try await withDatabaseBusyRetry(operation: "raw.prune") {
            try rawStore.pruneIfNeeded(retentionLimit: retentionLimit)
        }
    }

    func prunePackets(retentionLimit: Int) async throws {
        guard let packetStore else { return }
        try await withDatabaseBusyRetry(operation: "packet.pruneOnly") {
            try packetStore.pruneIfNeeded(retentionLimit: retentionLimit)
        }
    }

    func pruneConsole(retentionLimit: Int) async throws {
        guard let consoleStore else { return }
        try await withDatabaseBusyRetry(operation: "console.pruneOnly") {
            try consoleStore.pruneIfNeeded(retentionLimit: retentionLimit)
        }
    }

    func pruneRaw(retentionLimit: Int) async throws {
        guard let rawStore else { return }
        try await withDatabaseBusyRetry(operation: "raw.pruneOnly") {
            try rawStore.pruneIfNeeded(retentionLimit: retentionLimit)
        }
    }

    func deleteAllConsole() throws {
        guard let consoleStore else { return }
        try consoleStore.deleteAll()
    }

    func deleteAllRaw() throws {
        guard let rawStore else { return }
        try rawStore.deleteAll()
    }

    private func withDatabaseBusyRetry<T>(
        operation: String,
        _ body: () throws -> T
    ) async throws -> T {
        var attempt = 0
        var delay = initialBusyRetryDelayNanos

        while true {
            do {
                return try body()
            } catch {
                guard isDatabaseBusyError(error), attempt < maxBusyRetryCount else {
                    throw error
                }
                attempt += 1
                Task { @MainActor in
                    SentryManager.shared.addBreadcrumb(
                        category: "db.busy.retry",
                        message: "Retrying after SQLITE_BUSY",
                        level: .warning,
                        data: [
                            "operation": operation,
                            "attempt": attempt,
                            "delayMs": delay / 1_000_000
                        ]
                    )
                }
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
    }

    private func isDatabaseBusyError(_ error: Error) -> Bool {
        if let dbError = error as? DatabaseError {
            let code = dbError.extendedResultCode.rawValue
            if code == 5 || code == 261 || code == 517 {
                return true
            }
        }

        let text = error.localizedDescription.lowercased()
        return text.contains("database is locked")
            || text.contains("sqlite error 5")
            || text.contains("sqlite_busy")
    }
}
