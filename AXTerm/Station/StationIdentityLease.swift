import Foundation

/// A device's standing claim on a callsign-SSID at a particular TNC.
///
/// `StationIdentityMonitor` detects a collision *after* it has happened, from
/// a frame that has already been transmitted. That is useful but late: by the
/// time the evidence exists, two AX.25 state machines are already diverging.
///
/// A lease catches it before anything is transmitted. Each device, while
/// connected to a TNC, publishes what callsign it is using on which endpoint.
/// The lease travels over the same iCloud channel as the mailbox, so a second
/// AXTerm signed into the same account sees the claim and knows it is about to
/// collide — before it keys up rather than after.
///
/// Keyed on **callsign *and* endpoint**. The same callsign on two different
/// TNCs is two stations on two channels, which is legitimate and common — an
/// HF station and a VHF station under one licence. Only the same address on
/// the same channel is a collision.
///
/// This does not replace the monitor. A lease only exists between devices that
/// sync; the other station might be somebody else's radio entirely, or an
/// AXTerm with sync off, or LinBPQ. The two work together: the lease prevents
/// the case we can see coming, the monitor catches everything else.
nonisolated struct StationIdentityLease: Codable, Equatable, Sendable, Identifiable {

    /// Stable per-installation identifier — the same one the transmit claim
    /// uses, so a device is one device across both mechanisms.
    var deviceID: String
    /// What to call the other device when telling the operator about it.
    var deviceName: String
    /// Callsign with SSID, normalised.
    var callsign: String
    /// `host:port` of the TNC, normalised. Two AXTerms are only on the same
    /// channel if they are talking to the same TNC.
    var endpoint: String
    var heartbeatAt: Date
    var expiresAt: Date

    var id: String { deviceID }

    /// How long a lease outlives its last heartbeat.
    ///
    /// Short, because a stale lease blocks a device that has every right to
    /// transmit — an app that was force-quit must not lock the operator's
    /// other radio out for an hour. Long enough that an ordinary sync gap
    /// does not expire a live station.
    static let duration: TimeInterval = 15 * 60

    /// How often a connected device renews. Comfortably inside `duration`, so
    /// two missed renewals still leave the lease valid.
    static let heartbeatInterval: TimeInterval = 4 * 60

    init(deviceID: String, deviceName: String, callsign: String,
         endpoint: String, at now: Date, duration: TimeInterval = StationIdentityLease.duration) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.callsign = Self.normalize(callsign)
        self.endpoint = Self.normalize(endpoint)
        self.heartbeatAt = now
        self.expiresAt = now.addingTimeInterval(duration)
    }

    func isActive(at now: Date) -> Bool { now < expiresAt }

    /// True when two leases describe the same address on the same channel.
    func conflicts(with other: StationIdentityLease) -> Bool {
        deviceID != other.deviceID
            && callsign == other.callsign
            && endpoint == other.endpoint
            && !callsign.isEmpty
            && !endpoint.isEmpty
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).uppercased()
    }
}

/// What a device should do about the leases it can see.
nonisolated enum StationIdentityLeaseResolver {

    enum Verdict: Equatable, Sendable {
        /// No other device claims this address on this channel.
        case clear
        /// Another device holds it. Carries who, and what to tell the
        /// operator.
        case contested(holder: StationIdentityLease)

        var isContested: Bool {
            if case .contested = self { return true }
            return false
        }
    }

    /// Evaluates this device's intended identity against everything else on
    /// the account.
    ///
    /// A lease with no callsign or no endpoint cannot conflict with anything:
    /// a station that has not been configured has no identity to defend, and
    /// treating a blank as a match would have every unconfigured device block
    /// every other one.
    static func evaluate(own: StationIdentityLease,
                         others: [StationIdentityLease],
                         at now: Date) -> Verdict {
        guard !own.callsign.isEmpty, !own.endpoint.isEmpty else { return .clear }
        // Oldest first, so the device that got there first is the one named.
        let conflicting = others
            .filter { $0.isActive(at: now) && own.conflicts(with: $0) }
            .sorted { $0.heartbeatAt < $1.heartbeatAt }
        guard let holder = conflicting.first else { return .clear }
        return .contested(holder: holder)
    }

    /// Whether the station may transmit **without an operator present**.
    ///
    /// The split that matters. Unattended transmission into a contested
    /// identity — answering an inbound P2P call, sending queued mail on a
    /// timer — must not happen: nobody is watching, both stations reply to
    /// the same caller, and the damage compounds unobserved.
    ///
    /// A human deliberately keying up is a different matter and is never
    /// blocked. In an emergency an operator who understands the risk must
    /// still be able to transmit; the app's job there is to warn, not to
    /// refuse.
    static func mayTransmitUnattended(_ verdict: Verdict) -> Bool {
        !verdict.isContested
    }

    /// What to tell the operator, naming the device and the fix.
    static func explanation(for verdict: Verdict, own: StationIdentityLease) -> String? {
        guard case .contested(let holder) = verdict else { return nil }
        return """
        \(holder.deviceName) is already using \(own.callsign) on \(own.endpoint).

        Two stations answering to one address on one channel breaks AX.25: both reply to a SABM, both acknowledge I-frames, and each one's DISC tears down the other's session. Nothing reports an error — links just drop.

        Unattended transmission is held off on this device while that is true: it will not answer inbound Winlink calls and will not send queued mail on a timer. You can still transmit deliberately.

        To use both devices at once, give this one a different SSID in Settings → General → Callsign.
        """
    }
}
