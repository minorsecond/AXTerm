import Foundation

/// Drives one sync pass: pull, merge, push.
///
/// Holds every rule that matters and no knowledge of any particular
/// transport, so the whole thing is exercised in tests by pointing two
/// engines at one in-memory transport — which behaves exactly like two of an
/// operator's radios sharing an account.
actor WinlinkSyncEngine {

    /// What a pass did, for the operator and for the log.
    ///
    /// Sync that reports nothing is sync nobody can debug: when a message
    /// fails to appear on the other device, the question is always whether it
    /// was pushed, pulled, or refused, and this answers it.
    struct Report: Equatable, Sendable {
        var pulled = 0
        var applied = 0
        var pushed = 0
        /// Records refused by policy. Non-zero means a source tried to
        /// replicate device-local state and was stopped.
        var refused = 0
        /// Payloads that arrived unreadable — a newer app version, or
        /// corruption. Counted rather than thrown so one bad record cannot
        /// wedge the mailbox.
        var unreadable = 0
        /// Records this device holds that were already up there unchanged, so
        /// a pass that pushes nothing is visibly "nothing to say" rather than
        /// indistinguishable from a pass that failed to look.
        var unchanged = 0
        /// The server discarded our position and the pass re-read everything.
        var wasReset = false
        var skippedNoAccount = false
    }

    private let transport: WinlinkSyncTransport
    private let sources: [WinlinkSyncSource]
    private let tokenStore: WinlinkSyncTokenStore

    init(transport: WinlinkSyncTransport,
         sources: [WinlinkSyncSource],
         tokenStore: WinlinkSyncTokenStore) {
        self.transport = transport
        self.sources = sources
        self.tokenStore = tokenStore
    }

    var deviceID: String { transport.deviceID }

    /// Runs one pass.
    ///
    /// Pull before push: a device that pushes first would broadcast a state
    /// it formed without having seen the other device's changes, and the
    /// merge would then run on the far side against a value already
    /// overwritten here.
    @discardableResult
    func sync() async throws -> Report {
        var report = Report()

        guard await transport.isAvailable() else {
            // Not an error. An operator in the field with no signal should
            // find the app working alone, not an alert about iCloud.
            report.skippedNoAccount = true
            return report
        }

        // MARK: Pull
        let token = tokenStore.loadToken()
        let changes = try await transport.fetchChanges(since: token)
        report.pulled = changes.records.count
        report.wasReset = changes.wasReset

        for source in sources {
            let mine = changes.records.filter { $0.kind == source.kind }
            guard !mine.isEmpty else { continue }
            do {
                report.applied += try await source.apply(mine)
            } catch WinlinkSyncError.payloadUnreadable {
                // One unreadable record must not cost the operator the rest
                // of the mailbox. Apply what parses, count what does not.
                report.unreadable += try await applyIndividually(mine, with: source, into: &report)
            }
        }

        // Only advance the position once everything landed. A token saved
        // before a failed apply would skip those records forever.
        tokenStore.saveToken(changes.token)

        // MARK: Push
        var outgoing: [WinlinkSyncRecord] = []
        for source in sources {
            // The policy is enforced here rather than trusted to the sources.
            // A future source that tried to replicate session logs or a
            // digipeater path would be stopped by the same check that
            // documents why it must not.
            guard case .synced = WinlinkSyncPolicy.disposition(for: source.kind) else {
                report.refused += 1
                continue
            }
            outgoing += try await source.localRecords()
        }

        // Only what actually changed. Pushing the whole mailbox every pass
        // makes CloudKit report all of it as changed, so the next pass pulls
        // it all back and pushes it all again — a loop that never settles and
        // burns quota in proportion to mailbox size rather than to activity.
        let ledger = tokenStore.loadPushLedger()
        let changed = outgoing.filter { ledger[$0.recordName] != $0.modifiedAt }
        report.unchanged = outgoing.count - changed.count

        if !changed.isEmpty {
            try await transport.push(changed)
            report.pushed = changed.count
            var updated = ledger
            for record in changed { updated[record.recordName] = record.modifiedAt }
            // Records this device no longer holds are dropped, so a deleted
            // message cannot keep a stale entry alive forever.
            let live = Set(outgoing.map(\.recordName))
            tokenStore.savePushLedger(updated.filter { live.contains($0.key) })
        }

        return report
    }

    /// Retries a batch one record at a time so a single bad payload costs
    /// only itself. Returns how many were unreadable.
    private func applyIndividually(_ records: [WinlinkSyncRecord],
                                   with source: WinlinkSyncSource,
                                   into report: inout Report) async throws -> Int {
        var bad = 0
        for record in records {
            do {
                report.applied += try await source.apply([record])
            } catch WinlinkSyncError.payloadUnreadable {
                bad += 1
            }
        }
        return bad
    }
}

// MARK: - Token persistence

/// Remembers where the last pass got to.
nonisolated protocol WinlinkSyncTokenStore: Sendable {
    func loadToken() -> Data?
    func saveToken(_ token: Data?)

    /// What this device last pushed, as recordName -> the `modifiedAt` that
    /// went up. Separate from the server change token: the token says what we
    /// have *read*, this says what we have *written*, and a device needs both
    /// to avoid re-uploading a mailbox that has not changed.
    func loadPushLedger() -> [String: Date]
    func savePushLedger(_ ledger: [String: Date])
}

// `@unchecked` for `defaults`, and only for that. `UserDefaults` is
// documented as thread-safe, so sharing one across actors is sound; the
// compiler cannot see that because the class predates Sendable.
nonisolated struct WinlinkDefaultsTokenStore: WinlinkSyncTokenStore, @unchecked Sendable {
    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = AppEnvironment.defaults, key: String = "winlink.sync.token") {
        self.defaults = defaults
        self.key = key
    }

    func loadToken() -> Data? { defaults.data(forKey: key) }

    func saveToken(_ token: Data?) {
        if let token {
            defaults.set(token, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private var ledgerKey: String { key + ".pushed" }

    func loadPushLedger() -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: ledgerKey) as? [String: Double] else {
            return [:]
        }
        return raw.mapValues(Date.init(timeIntervalSince1970:))
    }

    func savePushLedger(_ ledger: [String: Date]) {
        defaults.set(ledger.mapValues(\.timeIntervalSince1970), forKey: ledgerKey)
    }
}

/// Token store that forgets, for tests and for a deliberate full re-read.
final class WinlinkMemoryTokenStore: WinlinkSyncTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: Data?

    init(token: Data? = nil) { self.token = token }

    func loadToken() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func saveToken(_ token: Data?) {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    private var ledger: [String: Date] = [:]

    func loadPushLedger() -> [String: Date] {
        lock.lock(); defer { lock.unlock() }
        return ledger
    }

    func savePushLedger(_ ledger: [String: Date]) {
        lock.lock(); defer { lock.unlock() }
        self.ledger = ledger
    }
}
