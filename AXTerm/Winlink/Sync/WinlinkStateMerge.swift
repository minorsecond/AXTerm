import Foundation

/// Which device may transmit a queued message.
///
/// This is the part of a unified mailbox that can actually cause harm.
/// Two devices holding the same queued outbound message will *both* try to
/// send it, and the CMS will receive the same MID twice — duplicate traffic
/// on a shared channel and airtime spent twice on one message. A shared
/// mailbox therefore needs an owner per outbound item, not just a merge rule.
///
/// Claims expire on purpose. A device switched off mid-activation must not
/// strand mail forever, so an unrenewed claim lapses and another device may
/// take it.
nonisolated struct WinlinkTransmitClaim: Equatable, Sendable, Codable {

    /// Stable per-installation identifier.
    var deviceID: String
    var claimedAt: Date
    /// After this instant, any device may claim it.
    var expiresAt: Date

    /// Long enough to cover a slow exchange — the ~19-minute session cap
    /// measured on this station's own links, plus retries — and short
    /// enough that a dead device does not hold mail hostage.
    static let defaultDuration: TimeInterval = 45 * 60

    init(deviceID: String, claimedAt: Date, expiresAt: Date) {
        self.deviceID = deviceID
        self.claimedAt = claimedAt
        self.expiresAt = expiresAt
    }

    init(deviceID: String, at now: Date, duration: TimeInterval = defaultDuration) {
        self.init(deviceID: deviceID,
                  claimedAt: now,
                  expiresAt: now.addingTimeInterval(duration))
    }

    func isActive(at now: Date) -> Bool { now < expiresAt }

    /// Whether `device` may put this message on the air.
    ///
    /// Unclaimed or lapsed mail is fair game; otherwise only the holder
    /// sends. Failing closed would be worse than duplication: mail that
    /// silently never leaves is the failure an operator cannot see.
    static func mayTransmit(_ claim: WinlinkTransmitClaim?, device: String, at now: Date) -> Bool {
        guard let claim, claim.isActive(at: now) else { return true }
        return claim.deviceID == device
    }

    /// Resolves two claims seen during a sync.
    ///
    /// A lapsed claim never beats a live one. Between two live claims the
    /// earlier wins — the device that started first is the one likely to be
    /// mid-session — and an exact tie is broken by device identifier so both
    /// sides reach the *same* answer without exchanging another round.
    static func resolve(_ a: WinlinkTransmitClaim?,
                        _ b: WinlinkTransmitClaim?,
                        at now: Date) -> WinlinkTransmitClaim? {
        let liveA = a?.isActive(at: now) == true ? a : nil
        let liveB = b?.isActive(at: now) == true ? b : nil
        switch (liveA, liveB) {
        case (let a?, let b?):
            if a.claimedAt != b.claimedAt { return a.claimedAt < b.claimedAt ? a : b }
            return a.deviceID <= b.deviceID ? a : b
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }
}

/// Merging one message's mutable state across two devices.
///
/// Transport-free and pure, so the rules can be tested exhaustively without
/// CloudKit, a network, or a second machine. Whatever carries the bytes —
/// CloudKit, a file, a cable — these are the rules that keep two mailboxes
/// honest.
nonisolated enum WinlinkStateMerge {

    /// The mutable half of a message: everything that can differ between two
    /// devices holding the same MID.
    struct State: Equatable, Sendable {
        var mid: String
        var isRead: Bool
        var folderId: Int64
        var deliveryState: WinlinkMessageStateRecord.DeliveryState
        var updatedAt: Date
        var lastError: String?
        /// Which device, if any, currently owns transmission of this message.
        var claim: WinlinkTransmitClaim?
        /// Compressed-stream bytes a gateway has already accepted.
        var sentOffset: Int
        /// The device that measured `sentOffset`.
        ///
        /// An `FS !offset` resume is a claim about one stream between one
        /// radio and one gateway. The number is meaningless without knowing
        /// whose stream it counts, so the owner travels with it.
        var offsetDevice: String?

        /// Timestamp meaning "this device has never decided anything about
        /// this message". Used for the state seeded alongside content that
        /// arrived without its state record.
        static let provisionalTimestamp = Date.distantPast

        /// True while this is a placeholder rather than a decision.
        var isProvisional: Bool { updatedAt == Self.provisionalTimestamp }

        init(mid: String,
             isRead: Bool = false,
             folderId: Int64 = 0,
             deliveryState: WinlinkMessageStateRecord.DeliveryState = .received,
             updatedAt: Date = Date(),
             lastError: String? = nil,
             claim: WinlinkTransmitClaim? = nil,
             sentOffset: Int = 0,
             offsetDevice: String? = nil) {
            self.mid = mid
            self.isRead = isRead
            self.folderId = folderId
            self.deliveryState = deliveryState
            self.updatedAt = updatedAt
            self.lastError = lastError
            self.claim = claim
            self.sentOffset = sentOffset
            self.offsetDevice = offsetDevice
        }
    }

    /// Merges two views of one message.
    ///
    /// Not a blanket last-writer-wins: several fields are monotonic, and
    /// last-writer would lose information. Reading a message is a fact a
    /// stale replica cannot un-make, and a message a gateway has accepted
    /// has not become un-sent because another device still thinks it queued.
    static func merge(_ local: State, _ remote: State, at now: Date) -> State {
        precondition(local.mid == remote.mid, "merging different messages")

        // A provisional side has no opinion to merge. It is the placeholder
        // written when a message's content arrived ahead of its companion
        // state record, and merging against it would let a placeholder's
        // defaults outrank a real decision — filing mail into the Inbox
        // because the seed said Inbox, or holding a message at `sent`
        // because the seed guessed conservatively.
        switch (local.isProvisional, remote.isProvisional) {
        case (true, false): return remote
        case (false, true): return local
        default: break
        }
        let newer = local.updatedAt >= remote.updatedAt ? local : remote
        let older = local.updatedAt >= remote.updatedAt ? remote : local
        let claim = WinlinkTransmitClaim.resolve(local.claim, remote.claim, at: now)

        // The resume offset belongs to whoever owns the send. Taking the
        // larger of two offsets would be a plausible-looking disaster: a
        // handheld resuming at the home rig's offset would ask a gateway
        // that never received those bytes to continue past them, and the
        // message would arrive truncated with no error anywhere.
        let offsetSide: State? = [local, remote].first {
            $0.offsetDevice != nil && $0.offsetDevice == claim?.deviceID
        }

        return State(
            mid: local.mid,
            // Monotonic: somebody read it. A replica that has not caught up
            // cannot make that untrue.
            isRead: local.isRead || remote.isRead,
            // Filing is a preference with no natural ordering, so the most
            // recent decision stands.
            folderId: newer.folderId,
            deliveryState: mergeDelivery(local.deliveryState, remote.deliveryState),
            updatedAt: max(local.updatedAt, remote.updatedAt),
            // Keep an error only while it is still the current story.
            lastError: newer.lastError ?? older.lastError,
            claim: claim,
            sentOffset: offsetSide?.sentOffset ?? 0,
            offsetDevice: offsetSide?.offsetDevice)
    }

    /// How far along the send has got.
    ///
    /// Progress is monotonic, with one exception: `failed` reported after an
    /// apparent success is later information about a message that still has
    /// not arrived. `sent` is the exception to the exception — a gateway
    /// accepted it, and that cannot be undone from another device.
    static func mergeDelivery(_ a: WinlinkMessageStateRecord.DeliveryState,
                              _ b: WinlinkMessageStateRecord.DeliveryState)
        -> WinlinkMessageStateRecord.DeliveryState {
        if a == b { return a }
        if a == .sent || b == .sent { return .sent }
        if a == .failed || b == .failed { return .failed }
        return rank(a) >= rank(b) ? a : b
    }

    private static func rank(_ state: WinlinkMessageStateRecord.DeliveryState) -> Int {
        switch state {
        case .draft: 0
        case .queued: 1
        case .sending: 2
        case .failed: 3
        case .sent: 4
        case .received: 5
        }
    }

    // MARK: - Mailbox-level merge

    /// Merges two mailboxes' worth of state, keyed by MID.
    ///
    /// A MID present on only one side is carried across untouched: a message
    /// the other device has never seen is new mail, not a deletion. This
    /// mailbox has no delete-tombstone concept, and inventing one from
    /// absence would silently destroy mail whenever a device synced before it
    /// had finished pulling.
    static func merge(local: [String: State],
                      remote: [String: State],
                      at now: Date) -> [String: State] {
        var result = local
        for (mid, remoteState) in remote {
            if let localState = result[mid] {
                result[mid] = merge(localState, remoteState, at: now)
            } else {
                result[mid] = remoteState
            }
        }
        return result
    }
}

extension WinlinkStateMerge.State {
    /// Builds merge state from a stored row.
    ///
    /// The claim and the offset's owner are sync-layer facts the local
    /// database does not carry, so they are supplied by the caller that
    /// knows them.
    init(record: WinlinkMessageStateRecord,
         claim: WinlinkTransmitClaim? = nil,
         offsetDevice: String? = nil) {
        self.init(mid: record.messageId,
                  isRead: record.isRead,
                  folderId: record.folderId,
                  deliveryState: record.state ?? .received,
                  updatedAt: record.updatedAt,
                  lastError: record.lastError,
                  claim: claim,
                  sentOffset: record.sentOffset,
                  offsetDevice: offsetDevice)
    }

    /// Projects merged state back onto a row for storage.
    func applied(to record: WinlinkMessageStateRecord) -> WinlinkMessageStateRecord {
        var updated = record
        updated.isRead = isRead
        updated.folderId = folderId
        updated.deliveryState = deliveryState.rawValue
        updated.updatedAt = updatedAt
        updated.lastError = lastError
        updated.sentOffset = sentOffset
        return updated
    }
}
