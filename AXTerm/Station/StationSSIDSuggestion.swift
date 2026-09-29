import Foundation

/// Choosing an SSID for a device that has not got one.
///
/// This is why setting up a second device is not simply "copy the settings
/// across". A callsign has two halves and they belong to different things:
///
/// - **The base is a licence.** `K0EPI` identifies a person and is the same
///   on every radio they own. Making them retype it on each device is
///   pointless friction, so it syncs.
/// - **The SSID identifies a station.** `-7` and `-1` are what let two of the
///   operator's radios share a channel without breaking AX.25. Copying it
///   across is precisely the collision that `StationIdentityMonitor` detects
///   and `StationIdentityLease` refuses to transmit into — so it does not
///   sync, and a new device is offered a free one instead of guessing.
///
/// Splitting is `CallsignParser`'s job, which the network graph already uses;
/// this only decides which SSID is free.
nonisolated enum StationSSIDSuggestion {

    /// AX.25 addresses 0–15.
    static let ssidRange = 0...15

    /// Order SSIDs are offered in.
    ///
    /// 0 is deliberately last. A bare callsign is the value most likely to be
    /// in use somewhere this app cannot see — a Winlink account, a club
    /// roster, another radio entirely — so handing it to a brand-new device
    /// is the choice most likely to collide with something outside its view.
    static let preferenceOrder = Array(1...15) + [0]

    /// A free SSID for a new device.
    ///
    /// - Parameters:
    ///   - taken: SSIDs the operator's other devices are known to be using.
    ///   - reserved: SSIDs belonging to something else on the channel — a
    ///     LinBPQ node, a digipeater, a BBS. Not this app's devices, but
    ///     colliding with them breaks just as badly.
    ///
    /// Nil when every SSID is spoken for, which is a real problem rather than
    /// something to paper over by reusing one.
    static func freeSSID(taken: Set<Int>, avoiding reserved: Set<Int> = []) -> Int? {
        preferenceOrder.first { !taken.contains($0) && !reserved.contains($0) }
    }

    /// SSIDs in use by the operator's other devices on this callsign.
    ///
    /// A bare callsign occupies 0: `K0EPI` and `K0EPI-0` are the same address
    /// on the air, and `CallsignParser` reports both as no SSID.
    static func takenSSIDs(from leases: [StationIdentityLease],
                           base: String,
                           at now: Date) -> Set<Int> {
        let wanted = CallsignParser.normalizeBase(base)
        return Set(leases.compactMap { lease -> Int? in
            guard lease.isActive(at: now) else { return nil }
            let parsed = CallsignParser.parse(lease.callsign)
            guard parsed.base == wanted else { return nil }
            return parsed.ssid ?? 0
        })
    }

    /// What to prefill on a device that has never been configured.
    ///
    /// Nil when there is no synced callsign to work from — a first device has
    /// nothing to inherit, and inventing one would be worse than asking.
    static func suggestion(syncedBase: String?,
                           leases: [StationIdentityLease],
                           at now: Date) -> ParsedCallsign? {
        guard let syncedBase else { return nil }
        let base = CallsignParser.normalizeBase(syncedBase)
        guard !base.isEmpty else { return nil }

        let taken = takenSSIDs(from: leases, base: base, at: now)
        guard let ssid = freeSSID(taken: taken) else { return nil }
        return ParsedCallsign(base: base, ssid: ssid > 0 ? ssid : nil)
    }

    /// Why this SSID and not another.
    ///
    /// Shown beside the prefilled field, because a value that appeared on its
    /// own invites the operator to "correct" it to the one their other radio
    /// uses — which is exactly the collision.
    static func explanation(for identity: ParsedCallsign,
                            otherDevices: [StationIdentityLease],
                            at now: Date) -> String {
        let others = otherDevices
            .filter { $0.isActive(at: now) }
            .map { "\($0.deviceName) is \($0.callsign)" }

        var lines = [
            "Your callsign \(identity.base) came from your other devices. The SSID is this device's own.",
        ]
        if !others.isEmpty {
            lines.append("Already in use: \(others.joined(separator: ", ")).")
        }
        lines.append("Two radios answering to one callsign-SSID on the same channel breaks AX.25 — both reply to a connect request, and sessions drop for no visible reason. Any unused SSID keeps them separate.")
        return lines.joined(separator: "\n\n")
    }
}
