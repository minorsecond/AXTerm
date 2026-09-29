import Foundation
import GRDB

/// How strongly a claim about a station is supported.
///
/// The distinction matters because the two are earned differently and one is
/// harder to fake. A station *saying* it runs a digipeater is an assertion; a
/// station whose callsign appears in a via path with the has-been-repeated bit
/// set has actually done the job while we watched.
nonisolated enum StationServiceConfidence: String, Codable, Sendable, CaseIterable {
    /// The station announced it in an ID or beacon.
    case declared
    /// It was observed doing it. Only digipeating can be proven this way —
    /// nothing a BBS or node does is visible in a frame header.
    case demonstrated

    var label: String {
        switch self {
        case .declared: return "Declared"
        case .demonstrated: return "Observed"
        }
    }
}

/// One durable fact about what a station runs.
nonisolated struct StationServiceEntry: Equatable, Sendable, Identifiable {
    var callsign: String
    var service: StationServiceParser.Service
    var alias: String?
    var confidence: StationServiceConfidence
    var firstHeard: Date
    var lastHeard: Date
    var timesHeard: Int
    var sourceText: String

    var id: String { "\(callsign)|\(service.rawValue)|\(confidence.rawValue)" }
}

nonisolated protocol StationServiceStore: Sendable {
    /// Records a claim, merging with anything already known about it.
    func record(_ entries: [StationServiceEntry]) throws
    func services(for callsign: String) throws -> [StationServiceEntry]
    func allServices() throws -> [StationServiceEntry]
    /// Everything known, grouped by the grid field it was heard in — the unit
    /// a travelling operator reasons in.
    func stationsRunningServices() throws -> [String: [StationServiceEntry]]
}

nonisolated final class SQLiteStationServiceStore: StationServiceStore, @unchecked Sendable {

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func record(_ entries: [StationServiceEntry]) throws {
        guard !entries.isEmpty else { return }
        try dbQueue.write { db in
            for entry in entries {
                // `timesHeard` accumulates rather than being overwritten:
                // repetition is the whole signal. An ID heard once could be a
                // decode error; the same claim every ten minutes for a week is
                // the network describing itself reliably, and only a running
                // count can tell those apart.
                try db.execute(sql: """
                    INSERT INTO station_services
                    (callsign, service, alias, confidence, firstHeard, lastHeard, timesHeard, sourceText)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(callsign, service, confidence) DO UPDATE SET
                        lastHeard = MAX(excluded.lastHeard, station_services.lastHeard),
                        firstHeard = MIN(excluded.firstHeard, station_services.firstHeard),
                        timesHeard = station_services.timesHeard + excluded.timesHeard,
                        alias = COALESCE(excluded.alias, station_services.alias),
                        sourceText = excluded.sourceText
                    """, arguments: [
                        entry.callsign.uppercased(), entry.service.rawValue, entry.alias,
                        entry.confidence.rawValue, entry.firstHeard, entry.lastHeard,
                        entry.timesHeard, entry.sourceText,
                    ])
            }
        }
    }

    func services(for callsign: String) throws -> [StationServiceEntry] {
        let key = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        return try dbQueue.read { db in
            try Self.rows(db, sql: """
                SELECT * FROM station_services WHERE callsign = ?
                ORDER BY timesHeard DESC
                """, arguments: [key])
        }
    }

    func allServices() throws -> [StationServiceEntry] {
        try dbQueue.read { db in
            try Self.rows(db, sql: "SELECT * FROM station_services ORDER BY callsign, service",
                          arguments: [])
        }
    }

    func stationsRunningServices() throws -> [String: [StationServiceEntry]] {
        Dictionary(grouping: try allServices(), by: \.callsign)
    }

    private static func rows(_ db: Database, sql: String,
                             arguments: StatementArguments) throws -> [StationServiceEntry] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            guard let service = StationServiceParser.Service(rawValue: row["service"]),
                  let confidence = StationServiceConfidence(rawValue: row["confidence"])
            else { return nil }
            return StationServiceEntry(
                callsign: row["callsign"], service: service, alias: row["alias"],
                confidence: confidence, firstHeard: row["firstHeard"],
                lastHeard: row["lastHeard"], timesHeard: row["timesHeard"],
                sourceText: row["sourceText"])
        }
    }
}

// MARK: - Harvesting

nonisolated enum StationServiceHarvester {

    /// Reads declarations out of ID and beacon frames.
    static func declarations(in packets: [Packet]) -> [StationServiceEntry] {
        var result: [StationServiceEntry] = []
        for packet in packets {
            guard let text = packet.infoText, !text.isEmpty,
                  let destination = packet.to?.call.uppercased(),
                  NodeAliasStore.announcementDestinations.contains(destination),
                  let source = packet.from?.display else { continue }

            for declaration in StationServiceParser.parse(text, source: source) {
                result.append(StationServiceEntry(
                    callsign: declaration.callsign,
                    service: declaration.service,
                    alias: declaration.alias,
                    confidence: .declared,
                    firstHeard: packet.timestamp,
                    lastHeard: packet.timestamp,
                    timesHeard: 1,
                    sourceText: declaration.sourceText))
            }
        }
        return result
    }

    /// Finds digipeaters that have actually repeated a frame.
    ///
    /// The has-been-repeated bit is set by the digipeater itself as it
    /// retransmits, so a hop carrying it did the job while we listened. That
    /// is stronger evidence than any announcement: a station can claim to
    /// digipeat and be misconfigured, but it cannot fake having repeated a
    /// frame that reached us.
    ///
    /// Hops without the bit are skipped. They are a *request* to be
    /// digipeated — the frame on its way to the digi — and counting them
    /// would credit stations that never repeated anything.
    static func demonstratedDigipeaters(in packets: [Packet]) -> [StationServiceEntry] {
        var result: [StationServiceEntry] = []
        for packet in packets {
            for hop in packet.via where hop.repeated {
                let call = hop.display.uppercased()
                // A digipeater is as often a tactical alias as a callsign —
                // DRLNOD and FNKTWN repeat frames every day. Requiring a
                // valid callsign here would have credited none of the nodes
                // this network actually runs on. What must be excluded is the
                // routing conventions: WIDE1-1 is an instruction, not a
                // station, and every frame carries one.
                guard !CallsignValidator.isServiceEndpoint(call) else { continue }
                guard CallsignValidator.isValidCallsign(call)
                        || NodeAliasParser.isPlausibleAlias(call) else { continue }
                result.append(StationServiceEntry(
                    callsign: call,
                    service: .digipeater,
                    alias: nil,
                    confidence: .demonstrated,
                    firstHeard: packet.timestamp,
                    lastHeard: packet.timestamp,
                    timesHeard: 1,
                    sourceText: "Repeated a frame from \(packet.from?.display ?? "another station")"))
            }
        }
        return result
    }
}
