import Foundation

/// What an SSID conventionally means, so an operator choosing one is told
/// rather than left to remember.
///
/// The two worlds this app lives in do not answer the question the same way.
/// APRS has a published convention that receivers and maps actually key on: a
/// `-9` is drawn as a car and a `-13` is read as a weather station, whatever
/// the operator meant. Naming those is a table, and the table is stable.
///
/// The packet side has no standard at all. `-1` is a bulletin board on one
/// network and a digipeater on the next, `-7` is a node here and a handheld
/// somewhere else. A hardcoded table would be a guess presented as a fact, so
/// the packet answer comes from the channel instead: AXTerm is already
/// harvesting service declarations into `station_services`, and what the
/// neighbours use an SSID for is the only honest local meaning available.
///
/// Evidence beats the table where there is any, because a convention the
/// operator's own network does not follow is worse than no advice.
nonisolated enum SSIDConvention {

    /// AX.25 carries four bits of SSID.
    static let range = 0...15

    // MARK: - APRS

    /// The published APRS convention. Present tense and short, because these
    /// land in a picker row and not in a manual.
    static func aprsMeaning(_ ssid: Int) -> String? {
        switch ssid {
        case 0: return "Home station, fixed"
        case 1: return "Fill-in digipeater, or a second station"
        case 2: return "Digipeater, or a second station"
        case 3: return "Digipeater, or a second station"
        case 4: return "A second station"
        case 5: return "Phone, tablet or another network"
        case 6: return "Special activity or satellite"
        case 7: return "Handheld"
        case 8: return "Boat, RV or maritime mobile"
        case 9: return "Mobile, in a vehicle"
        case 10: return "Internet gateway"
        case 11: return "Balloon, aircraft or spacecraft"
        case 12: return "One-way tracker"
        case 13: return "Weather station"
        case 14: return "Trucker"
        case 15: return "A second station"
        default: return nil
        }
    }

    // MARK: - Local evidence

    /// How many distinct stations run each service on each SSID, read from
    /// what this station has actually heard.
    ///
    /// Counted by callsign rather than by claim so that one talkative node
    /// repeating its ID every ten minutes does not outvote four quiet ones.
    static func localUsage(from entries: [StationServiceEntry])
    -> [Int: [StationServiceParser.Service: Int]] {
        var stations: [Int: [StationServiceParser.Service: Set<String>]] = [:]
        for entry in entries {
            guard let ssid = ssid(of: entry.callsign) else { continue }
            stations[ssid, default: [:]][entry.service, default: []]
                .insert(entry.callsign.uppercased())
        }
        return stations.mapValues { $0.mapValues(\.count) }
    }

    /// What this operator's own network uses an SSID for, most common first.
    ///
    /// A single sighting is left out: one station is an anecdote, and an
    /// anecdote in a picker reads as advice.
    static func localMeaning(_ ssid: Int,
                             usage: [Int: [StationServiceParser.Service: Int]],
                             minimumStations: Int = 2) -> String? {
        guard let services = usage[ssid] else { return nil }
        let ranked = services
            .filter { $0.value >= minimumStations }
            .sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
        guard !ranked.isEmpty else { return nil }
        let named = ranked.prefix(2).map { "\($0.key.label.lowercased()) (\($0.value))" }
        return "Here: " + named.joined(separator: ", ")
    }

    /// The SSID part of a callsign, or nil for a bare call or a tactical name.
    static func ssid(of callsign: String) -> Int? {
        let parts = callsign.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let value = Int(parts[1]), range.contains(value) else { return nil }
        return value
    }

    // MARK: - What the picker shows

    /// The line beside an SSID.
    ///
    /// `family` is what the radio has been *heard* carrying, not what it is
    /// configured as, so a radio that has heard nothing yet gets both kinds of
    /// advice rather than the wrong one. Local evidence is appended rather
    /// than substituted on an APRS channel: the published meaning is what
    /// other people's software will assume regardless of local habit.
    static func detail(ssid: Int,
                       family: RadioTrafficFamily?,
                       usage: [Int: [StationServiceParser.Service: Int]]) -> String? {
        let local = localMeaning(ssid, usage: usage)
        switch family {
        case .aprs:
            return aprsMeaning(ssid)
        case .ax25:
            return local
        case nil:
            // Nothing heard yet. Say what is known without claiming which
            // world this radio belongs to.
            return local ?? aprsMeaning(ssid).map { "APRS: \($0)" }
        }
    }
}
