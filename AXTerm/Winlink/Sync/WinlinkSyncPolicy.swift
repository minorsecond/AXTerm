import Foundation

/// What may travel between an operator's devices, and what must not.
///
/// A unified mailbox is mostly easy and partly dangerous, and the split
/// is not where people expect. Messages are the easy part: B2F gives
/// every message a globally unique MID, and this app treats delivered
/// mail as immutable, so merging two mailboxes is a union keyed by MID
/// with no field-level conflicts at all.
///
/// The dangerous part is everything that describes *a particular radio at
/// a particular place*. Syncing that does not merge two views of one
/// thing — it asserts something false about a second thing.
nonisolated enum WinlinkSyncPolicy {

    enum Disposition: Equatable, Sendable {
        /// Safe to replicate. Immutable, or merged by an explicit rule.
        case synced(String)
        /// Describes this device's radio, antenna or location. Copying
        /// it to another device would be a claim about equipment that
        /// does not exist there.
        case deviceLocal(String)
        /// Tied to one in-flight session on one radio. Meaningless, and
        /// actively harmful, anywhere else.
        case sessionLocal(String)
        /// Crosses, but only ever as *another station's evidence*.
        ///
        /// The middle ground the first three cases could not express. A
        /// packet the home rig heard is a real observation and worth reading
        /// on a handheld — but it is a measurement by a different antenna in
        /// a different place, so merging it into local routing metrics would
        /// produce numbers describing neither station. Attributed data is
        /// stored apart, labelled with its origin, and never feeds inference.
        case attributed(String)
    }

    /// Every kind of state the Winlink subsystem persists, and whether it
    /// may cross to another device.
    static func disposition(for kind: Kind) -> Disposition {
        switch kind {
        case .message:
            .synced("Immutable once delivered, and MIDs are globally unique, so merging is a union with no conflicts.")
        case .messageState:
            .synced("Read flags and folders are what a unified mailbox is for. Merged by rule — see WinlinkStateMerge.")
        case .contact:
            .synced("An address book is about people, not equipment.")
        case .catalogFavorite:
            .synced("A starred product is an operator preference and travels with them.")
        case .callsignDirectory:
            .synced("A licence address is the same fact everywhere, and a device with no network benefits most from another device's lookups.")
        case .nodeAlias:
            .synced("DRLNOD is KE0NCQ regardless of which radio heard the beacon.")
        case .callsignBase:
            // The licence, not the station. `K0EPI` identifies a person and
            // is the same on every radio they own; retyping it per device is
            // pointless friction. The **SSID** is deliberately excluded —
            // see `callsignSSID` below.
            .synced("A licence callsign identifies the operator, not the radio, so it is the same on every device they own.")
        case .operatorProfile:
            .synced("Name, organisation, phone, address — the operator, not the equipment. ICS forms want these and retyping them per device is friction with no upside.")

        case .callsignSSID:
            // The one piece of the callsign that must not travel. Two devices
            // on one callsign-SSID is exactly the collision that
            // StationIdentityMonitor detects and StationIdentityLease refuses
            // to transmit into.
            .deviceLocal("An SSID identifies a station, not an operator. Copying it to a second radio puts two stations on one address, which breaks AX.25 — each device picks a free one instead. See StationSSIDSuggestion.")

        case .stationLease:
            // The one piece of device-specific state that *must* travel. It
            // describes this radio, but its whole purpose is to be read by
            // the operator's other devices — a claim nobody else can see
            // prevents nothing.
            .synced("A claim on a callsign at a TNC, published so another device can see it is about to collide before it transmits. See StationIdentityLease.")

        case .partialInboundBody:
            .sessionLocal("A half-received compressed body resumes with 'FS !offset' against the gateway that was mid-transfer. Another device resuming from it would request an offset into a stream it never started.")

        case .stationPreferences:
            .deviceLocal("Digipeater paths are a property of *this* antenna. The route a home rig uses to reach a gateway is usually wrong for a handheld, and silently reusing it would put traffic on a path that cannot work.")
        case .gatewayLadder:
            .deviceLocal("A ladder is an ordered list of gateways this radio can actually hear.")
        case .sessionLog:
            .deviceLocal("Link quality is measured from one place with one antenna. WinlinkLinkQuality already refuses to treat a measurement taken elsewhere as a prediction; copying another device's log would smuggle exactly that in.")
        case .stationActivity:
            .attributed("What another station heard is real evidence and worth reading when away from it — but it was measured by a different antenna in a different place. Shown as that station's observations, never merged into this one's routing metrics, which CLAUDE.md requires to stay packet-derived from *this* receiver.")
        case .gridSquare:
            .deviceLocal("Where the station is. A handheld's position is not the home rig's.")
        }
    }

    enum Kind: String, CaseIterable, Sendable {
        case message
        case messageState
        case contact
        case catalogFavorite
        case callsignDirectory
        case nodeAlias
        case callsignBase
        case operatorProfile
        case callsignSSID
        case stationLease
        case partialInboundBody
        case stationPreferences
        case gatewayLadder
        case sessionLog
        case gridSquare
        case stationActivity
    }

    /// Everything the engine replicates: merged *and* attributed.
    ///
    /// Separate from `syncedKinds` because the two answer different
    /// questions. "May this cross the wire" is not "may this be merged into
    /// what this station believes", and conflating them is precisely how
    /// another antenna's measurements would end up in local routing metrics.
    static var replicatedKinds: [Kind] {
        Kind.allCases.filter {
            switch disposition(for: $0) {
            case .synced, .attributed: return true
            case .deviceLocal, .sessionLocal: return false
            }
        }
    }

    /// True when the kind may only be shown as another station's evidence,
    /// never folded into local state.
    static func isAttributed(_ kind: Kind) -> Bool {
        if case .attributed = disposition(for: kind) { return true }
        return false
    }

    static var syncedKinds: [Kind] {
        Kind.allCases.filter {
            if case .synced = disposition(for: $0) { return true }
            return false
        }
    }

    static func reason(for kind: Kind) -> String {
        switch disposition(for: kind) {
        case .synced(let why), .deviceLocal(let why),
             .sessionLocal(let why), .attributed(let why): why
        }
    }
}
