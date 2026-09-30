import Foundation

/// What a radio's frequency is for: APRS or packet, one or the other.
///
/// `RadioProfile.aprsEnabled` is the stored truth and this is a way of
/// reading and setting it. An APRS channel is a shared beacon frequency, so
/// the packet services (node announcements, ping, the mailbox, AXDP) stay off
/// there (`RadioProfile.runsPacketServices`). The radio's page shows the
/// sections for its channel and nothing else.
nonisolated enum RadioChannel: String, CaseIterable, Identifiable, Sendable {
    case aprs
    case packet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aprs: return "APRS"
        case .packet: return "Packet"
        }
    }

    static func of(_ radio: RadioProfile) -> RadioChannel {
        radio.aprsEnabled ? .aprs : .packet
    }

    /// The beacon a radio on this channel sends: a position report on APRS,
    /// an ID beacon to BEACON on packet.
    var beaconKind: BeaconKind {
        switch self {
        case .aprs: return .aprsPosition
        case .packet: return .text
        }
    }

    /// Puts a radio on this channel.
    ///
    /// The beacon changes kind with it and keeps everything else: its on/off
    /// switch, its interval, the text of an ID beacon and the symbol of a
    /// position beacon all come back if the operator switches back. A radio
    /// moved to APRS for the first time gets a position beacon that follows
    /// the station position. Its packet services are not touched either;
    /// they are only held off while the channel is APRS.
    ///
    /// Moved to APRS for the first time with no path ever set, it also gets
    /// `APRSPath.newRadioDefault`. Only then: a stored path, direct included,
    /// is the operator's; a radio already on APRS keeps what it sends; and a
    /// radio that has been on APRS before (it has a position beacon set up)
    /// keeps resolving its path from that beacon as it always has.
    func apply(to radio: inout RadioProfile) {
        if Self.takesDefaultAPRSPath(radio, movingTo: self) {
            radio.aprsPath = APRSPath.newRadioDefault
        }
        radio.aprsEnabled = self == .aprs
        radio.beacon.kind = beaconKind
        if self == .aprs, radio.beacon.aprs == nil {
            radio.beacon.aprs = .followingStation
        }
    }

    /// Whether moving `radio` to `channel` should give it the default APRS
    /// path. See `apply(to:)`.
    static func takesDefaultAPRSPath(_ radio: RadioProfile, movingTo channel: RadioChannel) -> Bool {
        channel == .aprs
            && of(radio) != .aprs
            && radio.aprsPath == nil
            && radio.beacon.aprs == nil
    }

    /// Whether the stored beacon is the kind this radio's channel sends.
    ///
    /// Before channels were one or the other, a radio could beacon an APRS
    /// position with APRS switched off, or send an ID beacon on an APRS
    /// channel. Those settings are kept as they were, and the page says so
    /// rather than showing controls for a beacon the radio does not send.
    static func beaconMatchesChannel(_ radio: RadioProfile) -> Bool {
        radio.beacon.kind == of(radio).beaconKind
    }

    /// The radios APRS messages and the reachability query may go out on.
    ///
    /// With several radios, the enabled ones on an APRS channel. With one,
    /// that radio whatever its channel: a single-radio station has no other
    /// channel to send an APRS message on, and it always behaved this way.
    /// `SessionCoordinator.connectedAPRSRadios` and the APRS page's "Runs on"
    /// line both read this, so they cannot disagree.
    static func aprsRadios(in radios: [RadioProfile]) -> [RadioProfile] {
        let active = radios.filter { !$0.archived }
        let enabled = active.filter(\.enabled)
        return active.count > 1 ? enabled.filter(\.handlesAPRS) : enabled
    }
}

extension APRSPositionConfig {
    /// A new position beacon: the station position from General, the
    /// default symbol, nothing else set.
    nonisolated static var followingStation: APRSPositionConfig { APRSPositionConfig(useGPS: true) }
}
