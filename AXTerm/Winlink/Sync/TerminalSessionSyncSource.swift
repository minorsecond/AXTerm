import Foundation

/// Replicates finished terminal sessions between the operator's own devices,
/// attributed to the device that made them.
///
/// Reads this device's recent finished sessions and offers them; files what
/// arrives from other devices in the remote table and nowhere else. It never
/// writes a local session — the store protocol has no method for it.
///
/// What is published: sessions that have *ended* in the last week. A live
/// session is rewritten when it closes, and its record ID would not change,
/// so the push ledger would suppress the final copy; waiting for the end is
/// what makes the one push carry the whole transcript. The window keeps
/// iCloud to recent history — a year of sessions is the local store's job.
nonisolated struct TerminalSessionSyncSource: WinlinkSyncSource {

    /// How far back publication reaches. Matches station activity.
    static let window: TimeInterval = 7 * 86_400

    let kind: WinlinkSyncPolicy.Kind = .terminalSession
    private let store: TerminalSessionReplicationStore
    private let deviceID: String
    private let deviceName: String?
    private let station: @Sendable () -> String
    private let gridSquare: @Sendable () -> String?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - station: the callsign this device operates as, read at publish
    ///     time so a callsign change is reflected without a restart.
    ///   - gridSquare: where this device is, for the attribution line.
    init(store: TerminalSessionReplicationStore,
         deviceID: String,
         deviceName: String?,
         station: @escaping @Sendable () -> String,
         gridSquare: @escaping @Sendable () -> String?,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.station = station
        self.gridSquare = gridSquare
        self.now = now
    }

    func localRecords() throws -> [WinlinkSyncRecord] {
        let since = now().addingTimeInterval(-Self.window)
        let callsign = station().trimmingCharacters(in: .whitespaces).uppercased()
        let grid = gridSquare()?.trimmingCharacters(in: .whitespaces)
        return try store.localSessionsForPublication(endedSince: since).compactMap { session in
            // Belt and braces: the store promises no live sessions, and the
            // payload would otherwise invent an end time.
            guard session.outcome != .live, let endedAt = session.endedAt else { return nil }
            let payload = TerminalSessionPayload(
                session: session,
                provenance: WinlinkSyncProvenance(
                    station: callsign, deviceID: deviceID,
                    gridSquare: (grid?.isEmpty ?? true) ? nil : grid,
                    observedAt: endedAt),
                deviceName: deviceName)
            return WinlinkSyncRecord(
                kind: .terminalSession,
                id: Self.recordID(payload),
                // The end is the one moment that changes exactly once, so
                // the ledger pushes each session once and never again.
                modifiedAt: endedAt,
                payload: try Self.encoder.encode(payload))
        }
    }

    @discardableResult
    func apply(_ records: [WinlinkSyncRecord]) throws -> Int {
        var incoming: [TerminalSessionPayload] = []
        for record in records where record.kind == .terminalSession {
            guard let payload = try? Self.decoder.decode(TerminalSessionPayload.self,
                                                         from: record.payload) else {
                throw WinlinkSyncError.payloadUnreadable(kind: kind, id: record.id)
            }
            // A device's own records come back on the next pull. Filing
            // them as another device's would show every session twice, once
            // under a heading that says it came from somewhere else.
            guard payload.provenance.deviceID != deviceID else { continue }
            incoming.append(payload)
        }
        guard !incoming.isEmpty else { return 0 }
        try store.saveRemoteSessions(incoming)
        return incoming.count
    }

    /// Device first, so one device's history is one prefix and two devices
    /// can never overwrite each other's copy of anything.
    static func recordID(_ payload: TerminalSessionPayload) -> String {
        "\(payload.provenance.deviceID)|\(payload.id.uuidString)"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
