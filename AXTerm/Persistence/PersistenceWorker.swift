//
//  PersistenceWorker.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import Foundation

/// Serializes persistence work off the main actor.
///
/// The underlying stores are synchronous; this actor provides async wrappers so the UI can call them without
/// capturing non-Sendable state in concurrent closures.
actor PersistenceWorker {
    private let packetStore: PacketStore?
    private let consoleStore: ConsoleStore?
    private let rawStore: RawStore?

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
        let records = try store.loadPackets(in: timeframe)
        return records.map { $0.toPacket() }
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

    func savePacket(_ packet: Packet, retentionLimit: Int) throws {
        guard let packetStore else { return }
        try packetStore.save(packet)
        try packetStore.pruneIfNeeded(retentionLimit: retentionLimit)
    }

    func setPinned(packetId: Packet.ID, pinned: Bool) throws {
        guard let packetStore else { return }
        try packetStore.setPinned(packetId: packetId, pinned: pinned)
    }

    func appendConsole(_ entry: ConsoleEntryRecord, retentionLimit: Int) throws {
        guard let consoleStore else { return }
        try consoleStore.append(entry)
        try consoleStore.pruneIfNeeded(retentionLimit: retentionLimit)
    }

    func appendRaw(_ entry: RawEntryRecord, retentionLimit: Int) throws {
        guard let rawStore else { return }
        try rawStore.append(entry)
        try rawStore.pruneIfNeeded(retentionLimit: retentionLimit)
    }

    func prunePackets(retentionLimit: Int) throws {
        guard let packetStore else { return }
        try packetStore.pruneIfNeeded(retentionLimit: retentionLimit)
    }

    func pruneConsole(retentionLimit: Int) throws {
        guard let consoleStore else { return }
        try consoleStore.pruneIfNeeded(retentionLimit: retentionLimit)
    }

    func pruneRaw(retentionLimit: Int) throws {
        guard let rawStore else { return }
        try rawStore.pruneIfNeeded(retentionLimit: retentionLimit)
    }

    func deleteAllConsole() throws {
        guard let consoleStore else { return }
        try consoleStore.deleteAll()
    }

    func deleteAllRaw() throws {
        guard let rawStore else { return }
        try rawStore.deleteAll()
    }
}
