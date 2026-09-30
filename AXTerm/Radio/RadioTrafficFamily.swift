import Foundation

/// What kind of network a radio is actually listening to, read from the
/// traffic it has heard rather than from a setting.
///
/// One station can have a radio on 144.390 hearing nothing but APRS beacons
/// and another on a 1200-baud packet channel hearing nothing but node
/// broadcasts and connected-mode sessions. The two want different things drawn
/// on the map, and the operator should not have to say which is which — the
/// frames already say it.
///
/// This is evidence, not configuration. A radio that has heard nothing
/// classifiable belongs to no family, and callers must treat that as "not yet
/// known" rather than as "neither" — hiding a control because nothing has been
/// heard yet is how a map ends up blank with no way to fix it.
nonisolated enum RadioTrafficFamily: String, CaseIterable, Sendable, Hashable {
    /// Position, weather and message beacons: the APRS world.
    case aprs
    /// Connected-mode sessions and NET/ROM: the packet-network world.
    case ax25

    var label: String {
        switch self {
        case .aprs: return "APRS"
        case .ax25: return "AX.25"
        }
    }

    /// The family's name on a coverage ring and its layer switch. "Packet"
    /// rather than "AX.25": APRS is AX.25 too, and the ring is about the
    /// packet network, not the frame format.
    var coverageName: String {
        switch self {
        case .aprs: return "APRS"
        case .ax25: return "Packet"
        }
    }

    var help: String {
        switch self {
        case .aprs:
            return "This radio has *heard* APRS \u{2014} UI frames carrying a position, "
                + "weather report, object or message. It says nothing about whether this "
                + "radio transmits APRS, which is the separate switch in Settings \u{203a} "
                + "Radios. A receive-only badge is the useful one here: the APRS layers "
                + "decide what is drawn for stations, and what is drawn depends on what "
                + "arrives."
        case .ax25:
            return "This radio has heard connected-mode or NET/ROM traffic \u{2014} sessions "
                + "and node broadcasts. Stations here are placed from what is known about the "
                + "callsign, because packet-network stations do not beacon a position."
        }
    }
}

/// Which families each radio has evidence for, derived from the heard
/// stations. Pure so the classification is testable without a receiver.
nonisolated enum RadioTrafficClassifier {

    /// Families per radio, from every station's per-radio observations.
    ///
    /// A radio appears in the result only once it has heard something
    /// classifiable; an entry with an empty set cannot occur.
    static func families(from stations: [Station]) -> [RadioID: Set<RadioTrafficFamily>] {
        var result: [RadioID: Set<RadioTrafficFamily>] = [:]
        for station in stations {
            for (radio, observation) in station.perRadio {
                if observation.aprsFrames > 0 { result[radio, default: []].insert(.aprs) }
                if observation.sessionFrames > 0 { result[radio, default: []].insert(.ax25) }
            }
        }
        return result
    }

    /// Families per radio as the map should use them: the heard evidence,
    /// narrowed by what the operator has said a radio is for.
    ///
    /// A radio marked as on an APRS channel counts as APRS and nothing else.
    /// Packet services are locked off there, so it never opens a session and
    /// can never collect the answers the packet coverage ring is built from,
    /// and its "heard direct" stations are the same set the APRS ring already
    /// draws. Letting it carry AX.25 as well only ever produced a second copy
    /// of the APRS receive ring under a packet label. On 2026-09-30 a single
    /// corrupt frame on a TNC4 (garbage addresses, decoded as an I frame) was
    /// enough to do that.
    ///
    /// The radio gets APRS even before anything has been heard on it: the
    /// operator has already said what the channel is, which is better
    /// evidence than silence.
    static func mapFamilies(heard: [RadioID: Set<RadioTrafficFamily>],
                            aprsChannels: Set<RadioID>) -> [RadioID: Set<RadioTrafficFamily>] {
        var result = heard
        for radio in aprsChannels { result[radio] = [.aprs] }
        return result
    }

    /// The families some radio on this station could carry on the map.
    ///
    /// A radio on an APRS channel carries APRS and nothing else
    /// (`mapFamilies`). Any other radio could carry either, whatever it has
    /// heard so far: a packet radio that has heard nothing yet is "not known
    /// yet", and hiding its layers for that would leave nothing to switch on
    /// when its traffic arrives. So a family is ruled out only when every
    /// radio is held away from it, which today means every radio is on an
    /// APRS channel and AX.25 is out.
    ///
    /// With no radios at all nothing is ruled out.
    static func possibleFamilies(radios: [RadioID],
                                 aprsChannels: Set<RadioID>) -> Set<RadioTrafficFamily> {
        let everything = Set(RadioTrafficFamily.allCases)
        guard !radios.isEmpty else { return everything }
        let held = mapFamilies(heard: [:], aprsChannels: aprsChannels)
        return radios.reduce(into: Set<RadioTrafficFamily>()) { result, radio in
            result.formUnion(held[radio] ?? everything)
        }
    }

    /// `possibleFamilies` for a set of radio profiles, reading each one's
    /// Channel setting.
    static func possibleFamilies(of radios: [RadioProfile]) -> Set<RadioTrafficFamily> {
        possibleFamilies(radios: radios.map(\.id),
                         aprsChannels: Set(radios.filter(\.aprsEnabled).map(\.id)))
    }

    /// Whether a frame's addresses could have come from a real station.
    ///
    /// AX.25 addresses are upper-case letters and digits, one to six of them.
    /// A frame whose CRC passed by luck, or a TNC reply mistaken for data,
    /// decodes to punctuation in the address field, and its control byte is
    /// just as random, so it should not stand as proof that a radio is on a
    /// connected-mode channel.
    static func hasWellFormedAddresses(from: String?, to: String?) -> Bool {
        guard let from, let to else { return false }
        return isWellFormedCall(from) && isWellFormedCall(to)
    }

    private static func isWellFormedCall(_ call: String) -> Bool {
        guard (1...6).contains(call.count) else { return false }
        return call.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    /// The radios that carry `family`, among `visible`.
    static func radios(carrying family: RadioTrafficFamily,
                       families: [RadioID: Set<RadioTrafficFamily>],
                       visible: [RadioID]) -> [RadioID] {
        visible.filter { families[$0]?.contains(family) ?? false }
    }

    /// Whether a frame is evidence of a connected-mode or NET/ROM network.
    ///
    /// I and S frames only exist inside a session, and a U frame that is not
    /// UI is a session being set up or torn down (SABM, UA, DISC, DM, FRMR).
    /// A plain UI frame proves nothing either way: APRS and a NET/ROM NODES
    /// broadcast both ride in one.
    static func isSessionEvidence(_ type: FrameType) -> Bool {
        switch type {
        case .i, .s, .u: return true
        case .ui, .unknown: return false
        }
    }
}

/// Decides which radio's row each family's map layers sit under.
///
/// A layer switch is one setting, so it must appear exactly once. Filing the
/// APRS layers under "the APRS radio" only works while there is one of them;
/// with two APRS radios the same switch would appear twice and read as two
/// independent settings. So a family goes under a radio only when exactly one
/// visible radio carries it, and otherwise falls back to the shared section —
/// which is also what happens before any traffic has been classified.
nonisolated enum MapLayerPlacement {

    struct Plan: Equatable, Sendable {
        /// Families whose layers are drawn under this radio's row.
        var perRadio: [RadioID: Set<RadioTrafficFamily>] = [:]
        /// Families that could not be filed under a single radio, and are
        /// drawn in the shared Layers section instead.
        var orphans: Set<RadioTrafficFamily> = []
        /// True when at least one family found a home under a radio, so the
        /// caller knows whether to group at all.
        var isGrouped: Bool { !perRadio.isEmpty }
    }

    /// - Parameter radios: **every** radio, not only the shown ones. A layer
    ///   belongs under the radio whose network it describes whether or not
    ///   that radio's traffic is currently being drawn; moving it to the
    ///   bottom of the sidebar the moment the radio is switched off is how
    ///   the grouping appeared to be broken. The row itself is disabled
    ///   instead, which says the same thing without relocating anything.
    static func plan(families: [RadioID: Set<RadioTrafficFamily>],
                     radios: [RadioID]) -> Plan {
        var plan = Plan()
        for family in RadioTrafficFamily.allCases {
            let carriers = RadioTrafficClassifier.radios(
                carrying: family, families: families, visible: radios)
            if carriers.count == 1 {
                plan.perRadio[carriers[0], default: []].insert(family)
            } else {
                // Nobody carries it (nothing heard yet), or several do.
                plan.orphans.insert(family)
            }
        }
        return plan
    }
}
