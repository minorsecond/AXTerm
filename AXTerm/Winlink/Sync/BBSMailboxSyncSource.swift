import Foundation

/// Replicates this device's mailbox to the operator's other devices, and
/// files theirs here, attributed. Two sources — messages and calls — because
/// the engine routes records to a source by kind.
///
/// Messages: every one, because the mailbox is small, capped per message, and
/// append-only; the record's date follows the message's state so a read or a
/// kill at home is pushed again. Calls: finished ones from the last week.

nonisolated struct BBSMessageSyncSource: WinlinkSyncSource {

    let kind: WinlinkSyncPolicy.Kind = .bbsMessage
    private let store: BBSMailboxReplicationStore
    private let stamp: BBSMailboxStamp

    init(store: BBSMailboxReplicationStore, deviceID: String, deviceName: String?,
         mailbox: @escaping @Sendable () -> String,
         station: @escaping @Sendable () -> String,
         gridSquare: @escaping @Sendable () -> String?,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.stamp = BBSMailboxStamp(deviceID: deviceID, deviceName: deviceName,
                                     mailbox: mailbox, station: station, gridSquare: gridSquare, now: now)
    }

    func localRecords() throws -> [WinlinkSyncRecord] {
        let origin = stamp.resolve()
        return try store.localMessagesForPublication().map { message in
            let payload = BBSMessagePayload(
                message: message, mailbox: origin.mailbox,
                provenance: WinlinkSyncProvenance(station: origin.station, deviceID: stamp.deviceID,
                                                  gridSquare: origin.gridSquare, observedAt: message.receivedAt),
                deviceName: stamp.deviceName)
            return WinlinkSyncRecord(kind: .bbsMessage, id: Self.recordID(payload),
                                     modifiedAt: payload.modifiedAt,
                                     payload: try BBSMailboxStamp.encoder.encode(payload))
        }
    }

    @discardableResult
    func apply(_ records: [WinlinkSyncRecord]) throws -> Int {
        var incoming: [BBSMessagePayload] = []
        for record in records where record.kind == .bbsMessage {
            guard let payload = try? BBSMailboxStamp.decoder.decode(BBSMessagePayload.self, from: record.payload) else {
                throw WinlinkSyncError.payloadUnreadable(kind: kind, id: record.id)
            }
            guard payload.provenance.deviceID != stamp.deviceID else { continue }
            incoming.append(payload)
        }
        guard !incoming.isEmpty else { return 0 }
        try store.saveRemoteMessages(incoming)
        return incoming.count
    }

    /// Device, then the mailbox's own number: two mailboxes can both hold a
    /// "Message 12" and neither overwrites the other.
    static func recordID(_ payload: BBSMessagePayload) -> String {
        "\(payload.provenance.deviceID)|m\(payload.id)"
    }
}

nonisolated struct BBSCallSyncSource: WinlinkSyncSource {

    static let window: TimeInterval = 7 * 86_400

    let kind: WinlinkSyncPolicy.Kind = .bbsCall
    private let store: BBSMailboxReplicationStore
    private let stamp: BBSMailboxStamp

    init(store: BBSMailboxReplicationStore, deviceID: String, deviceName: String?,
         mailbox: @escaping @Sendable () -> String,
         station: @escaping @Sendable () -> String,
         gridSquare: @escaping @Sendable () -> String?,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.stamp = BBSMailboxStamp(deviceID: deviceID, deviceName: deviceName,
                                     mailbox: mailbox, station: station, gridSquare: gridSquare, now: now)
    }

    func localRecords() throws -> [WinlinkSyncRecord] {
        let origin = stamp.resolve()
        let since = stamp.now().addingTimeInterval(-Self.window)
        return try store.localCallsForPublication(endedSince: since).compactMap { call in
            guard let ended = call.disconnectedAt else { return nil }
            let payload = BBSCallPayload(
                call: call, mailbox: origin.mailbox,
                provenance: WinlinkSyncProvenance(station: origin.station, deviceID: stamp.deviceID,
                                                  gridSquare: origin.gridSquare, observedAt: ended),
                deviceName: stamp.deviceName)
            return WinlinkSyncRecord(kind: .bbsCall, id: Self.recordID(payload),
                                     modifiedAt: ended,
                                     payload: try BBSMailboxStamp.encoder.encode(payload))
        }
    }

    @discardableResult
    func apply(_ records: [WinlinkSyncRecord]) throws -> Int {
        var incoming: [BBSCallPayload] = []
        for record in records where record.kind == .bbsCall {
            guard let payload = try? BBSMailboxStamp.decoder.decode(BBSCallPayload.self, from: record.payload) else {
                throw WinlinkSyncError.payloadUnreadable(kind: kind, id: record.id)
            }
            guard payload.provenance.deviceID != stamp.deviceID else { continue }
            incoming.append(payload)
        }
        guard !incoming.isEmpty else { return 0 }
        try store.saveRemoteCalls(incoming)
        return incoming.count
    }

    static func recordID(_ payload: BBSCallPayload) -> String {
        "\(payload.provenance.deviceID)|c\(payload.id)"
    }
}

/// What both sources stamp on a record: which device, which mailbox, which
/// station, where. Read at publish time so a callsign change is honoured
/// without a restart.
nonisolated struct BBSMailboxStamp: Sendable {
    let deviceID: String
    let deviceName: String?
    let mailbox: @Sendable () -> String
    let station: @Sendable () -> String
    let gridSquare: @Sendable () -> String?
    let now: @Sendable () -> Date

    struct Origin { var mailbox: String; var station: String; var gridSquare: String? }

    func resolve() -> Origin {
        let station = station().trimmingCharacters(in: .whitespaces).uppercased()
        var mailbox = self.mailbox().trimmingCharacters(in: .whitespaces).uppercased()
        if mailbox.isEmpty { mailbox = station }
        let grid = gridSquare()?.trimmingCharacters(in: .whitespaces)
        return Origin(mailbox: mailbox, station: station,
                      gridSquare: (grid?.isEmpty ?? true) ? nil : grid)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
