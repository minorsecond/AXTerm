import Foundation

/// One syncable item, in transit.
///
/// The payload is opaque to the transport on purpose. Whatever carries the
/// bytes — CloudKit today, something else later — moves blobs and never has
/// to understand B2F, which keeps protocol knowledge in the protocol layer
/// where it is already tested.
nonisolated struct WinlinkSyncRecord: Equatable, Sendable {
    var kind: WinlinkSyncPolicy.Kind
    /// Stable identity within the kind: a MID, a callsign, an alias.
    var id: String
    var modifiedAt: Date
    var payload: Data

    /// Globally unique key, so different kinds sharing an id cannot collide.
    var recordName: String { "\(kind.rawValue)|\(id)" }
}

/// What a fetch returned, plus where to resume next time.
nonisolated struct WinlinkSyncChangeSet: Equatable, Sendable {
    var records: [WinlinkSyncRecord] = []
    /// Opaque server position. Persisted verbatim; only the transport that
    /// produced it may interpret it.
    var token: Data?
    /// The server discarded the token we sent — usually because it aged out.
    /// The caller must treat the change set as a full re-read rather than an
    /// increment, or it will silently miss everything in between.
    var wasReset: Bool = false
}

nonisolated enum WinlinkSyncError: Error, Equatable {
    /// The kind may not leave this device. See `WinlinkSyncPolicy`.
    case notSyncable(WinlinkSyncPolicy.Kind)
    case accountUnavailable(String)
    case payloadUnreadable(kind: WinlinkSyncPolicy.Kind, id: String)
}

/// Moves records between devices. Deliberately tiny: fetch, push, done.
///
/// The engine above it holds every rule that matters, so the rules are
/// testable without a network, an Apple Account, or a second machine.
nonisolated protocol WinlinkSyncTransport: Sendable {
    /// This installation's stable identifier, used for transmission claims.
    var deviceID: String { get }

    /// Whether the account is currently usable. A signed-out device must
    /// degrade to working alone rather than erroring at the operator.
    func isAvailable() async -> Bool

    func fetchChanges(since token: Data?) async throws -> WinlinkSyncChangeSet
    func push(_ records: [WinlinkSyncRecord]) async throws
}

// MARK: - Device identity

/// A stable per-installation identifier.
///
/// Not the hardware UUID and not the callsign. Two of an operator's radios
/// can share a callsign, and a reinstalled app should not inherit the
/// transmission claims of the install it replaced — a claim held by a device
/// that no longer exists is exactly what the expiry rule exists to clear.
nonisolated enum WinlinkSyncDevice {

    static let defaultsKey = "winlink.sync.deviceID"

    static func identifier(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }

    /// Short form for display: "this message is being sent by ABCD1234".
    static func shortName(_ identifier: String) -> String {
        String(identifier.prefix(8))
    }
}

// MARK: - In-memory transport

/// A transport that keeps everything in memory.
///
/// Two engines pointed at one instance behave like two devices sharing an
/// account, which is what makes the merge rules testable end to end. Also
/// the honest fallback when no account is configured: the engine runs, the
/// rules apply, and nothing leaves the machine.
final class WinlinkInMemorySyncTransport: WinlinkSyncTransport, @unchecked Sendable {

    let deviceID: String
    private let lock = NSLock()
    private var storage: [String: WinlinkSyncRecord] = [:]
    /// Monotonic write counter; the token is a position in this sequence.
    private var sequence: Int = 0
    private var order: [String: Int] = [:]

    /// Set to fail the next push, to exercise the caller's error path.
    var pushFailure: Error?

    init(deviceID: String = "test-device") {
        self.deviceID = deviceID
    }

    func isAvailable() async -> Bool { true }

    func fetchChanges(since token: Data?) async throws -> WinlinkSyncChangeSet {
        lock.lock()
        defer { lock.unlock() }
        let after = token.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? -1
        let changed = storage.values
            .filter { (order[$0.recordName] ?? 0) > after }
            .sorted { $0.recordName < $1.recordName }
        return WinlinkSyncChangeSet(
            records: changed,
            token: String(sequence).data(using: .utf8))
    }

    func push(_ records: [WinlinkSyncRecord]) async throws {
        if let pushFailure { throw pushFailure }
        lock.lock()
        defer { lock.unlock() }
        for record in records {
            sequence += 1
            storage[record.recordName] = record
            order[record.recordName] = sequence
        }
    }

    var allRecords: [WinlinkSyncRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.sorted { $0.recordName < $1.recordName }
    }
}
