import Foundation

/// Who observed something, and from where.
///
/// The thing that makes attributed data safe. Without it a remote
/// observation is indistinguishable from a local one the moment it lands in
/// the database, and the distinction cannot be recovered later — so it is
/// carried on the record itself rather than inferred from context.
nonisolated struct WinlinkSyncProvenance: Codable, Equatable, Sendable {
    /// The callsign that heard it — the station, not the operator.
    var station: String
    /// Which installation recorded it, so two radios under one callsign stay
    /// distinguishable.
    var deviceID: String
    /// Where that station was, when it heard this. A bearing means nothing
    /// without it.
    var gridSquare: String?
    var observedAt: Date
}

/// One station's activity as seen by one receiver.
///
/// Derived rather than raw: a rolling window of packets is tens of thousands
/// of records and would burn CloudKit quota for data nobody reads twice.
/// This is the summary that actually answers "what did home hear while I was
/// away" — who, when, how often, how much airtime — at a fraction of the
/// volume.
nonisolated struct StationActivityPayload: Codable, Equatable, Sendable {
    var callsign: String
    var roles: [String]
    var firstHeard: Date
    var lastHeard: Date
    var frameCount: Int
    var airtimeSeconds: Double
    var provenance: WinlinkSyncProvenance
}

/// What attributed observations need from persistence.
///
/// Deliberately not part of `WinlinkSyncStore`: these rows live in their own
/// table and must never be reachable from the queries that feed routing
/// inference. Keeping the surface separate makes that a compile-time fact
/// rather than a convention someone has to remember.
nonisolated protocol StationActivityStore: Sendable {
    /// This station's own observations, to publish.
    func localStationActivity() throws -> [StationActivityPayload]
    /// Replaces what is held for one remote station+device pair.
    func saveRemoteStationActivity(_ payloads: [StationActivityPayload]) throws
    /// Everything other stations have reported. Never merged with local.
    func remoteStationActivity() throws -> [StationActivityPayload]
}

/// Replicates *derived* station activity between an operator's devices.
///
/// The rule this source exists to enforce: it writes only into the remote
/// table, and reads only from the local one. There is no path by which an
/// observation from another antenna reaches the store the analytics read.
nonisolated struct StationActivitySyncSource: WinlinkSyncSource {

    let kind: WinlinkSyncPolicy.Kind = .stationActivity
    private let store: StationActivityStore
    private let deviceID: String

    init(store: StationActivityStore, deviceID: String) {
        self.store = store
        self.deviceID = deviceID
    }

    func localRecords() throws -> [WinlinkSyncRecord] {
        try store.localStationActivity().map { payload in
            WinlinkSyncRecord(
                kind: .stationActivity,
                // Keyed by observer *and* subject: two stations hearing the
                // same callsign are two facts, not one fact written twice,
                // and collapsing them would silently discard one antenna's
                // view of the network.
                id: Self.recordID(payload),
                modifiedAt: payload.lastHeard,
                payload: try Self.encoder.encode(payload))
        }
    }

    @discardableResult
    func apply(_ records: [WinlinkSyncRecord]) throws -> Int {
        var incoming: [StationActivityPayload] = []
        for record in records where record.kind == .stationActivity {
            guard let payload = try? Self.decoder.decode(
                    StationActivityPayload.self, from: record.payload) else {
                throw WinlinkSyncError.payloadUnreadable(kind: kind, id: record.id)
            }
            // A device does not learn from its own echo. Without this the
            // station would re-import its own observations as though another
            // receiver had made them, doubling every count on the very
            // screen meant to separate the two.
            guard payload.provenance.deviceID != deviceID else { continue }
            incoming.append(payload)
        }
        guard !incoming.isEmpty else { return 0 }
        try store.saveRemoteStationActivity(incoming)
        return incoming.count
    }

    /// Stable identity: observer, then subject.
    static func recordID(_ payload: StationActivityPayload) -> String {
        "\(payload.provenance.deviceID)|\(payload.callsign)"
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
