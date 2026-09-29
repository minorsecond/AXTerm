import Foundation

/// Per-link operator preferences for the Stations table: which links to
/// show, and how to reach each one.
///
/// Keyed by **link**, not callsign: the same gateway on 145.050 and
/// 441.075 is two different paths, two different radios, and often two
/// different answers about whether it is reachable at all. A preference
/// stored per callsign would leak across bands.
///
/// A station that is hidden is hidden from the *table*, never from the
/// data — the record stays cached, its link quality keeps accumulating,
/// and unhiding restores everything. Hiding is a view preference, not a
/// delete.
nonisolated struct WinlinkStationPreferences: Codable, Equatable, Sendable {

    /// Digipeater path per link, e.g. `"DRLNOD"` or `"DRLNOD,WIDE1-1"`.
    /// Absent means direct.
    var paths: [String: String] = [:]

    /// Links the operator has hidden from the table.
    var hidden: Set<String> = []

    /// Frequencies to show. **Empty means show everything** — an empty
    /// filter is "no filter", not "hide everything", which is the only
    /// reading that degrades safely if the set is ever lost.
    var visibleFrequencies: Set<Int> = []

    // MARK: - Identity

    /// Table identity, matching `WinlinkRMSStationRecord.id`.
    static func linkKey(callsign: String, frequencyHz: Int) -> String {
        "\(callsign.uppercased())@\(frequencyHz)"
    }

    static func linkKey(_ station: WinlinkRMSStationRecord) -> String {
        linkKey(callsign: station.callsign, frequencyHz: station.frequencyHz)
    }

    // MARK: - Paths

    /// The stored path for a link, or empty for direct.
    func path(for station: WinlinkRMSStationRecord) -> String {
        paths[Self.linkKey(station)] ?? ""
    }

    /// Stores a path, normalising it. An empty or blank path is removed
    /// rather than stored as an empty string, so "direct" has exactly one
    /// representation.
    mutating func setPath(_ raw: String, for station: WinlinkRMSStationRecord) {
        let normalized = Self.normalizePath(raw)
        let key = Self.linkKey(station)
        if normalized.isEmpty {
            paths.removeValue(forKey: key)
        } else {
            paths[key] = normalized
        }
    }

    /// Uppercases, trims, and joins with commas. Accepts commas, spaces
    /// or both as separators, because operators type all three.
    ///
    /// AX.25 allows at most 8 digipeaters, so anything beyond that is
    /// dropped rather than silently failing at transmit time.
    static func normalizePath(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: ",")
    }

    // MARK: - Visibility

    func isHidden(_ station: WinlinkRMSStationRecord) -> Bool {
        hidden.contains(Self.linkKey(station))
    }

    mutating func setHidden(_ isHidden: Bool, for station: WinlinkRMSStationRecord) {
        let key = Self.linkKey(station)
        if isHidden {
            hidden.insert(key)
        } else {
            hidden.remove(key)
        }
    }

    func showsFrequency(_ frequencyHz: Int) -> Bool {
        visibleFrequencies.isEmpty || visibleFrequencies.contains(frequencyHz)
    }

    mutating func toggleFrequency(_ frequencyHz: Int, in available: [Int]) {
        if visibleFrequencies.isEmpty {
            // Turning one off from "all" means "all except this one",
            // which is what the operator just expressed.
            visibleFrequencies = Set(available).subtracting([frequencyHz])
        } else if visibleFrequencies.contains(frequencyHz) {
            visibleFrequencies.remove(frequencyHz)
        } else {
            visibleFrequencies.insert(frequencyHz)
        }
        // Every frequency selected is the same as no filter, and storing
        // it as "no filter" means a newly-appearing frequency shows up
        // instead of being silently excluded.
        if visibleFrequencies == Set(available) { visibleFrequencies = [] }
    }

    /// Applies the filters. `showingHidden` overrides hiding so the
    /// operator can find and restore something they hid.
    func visible(_ stations: [WinlinkRMSStationRecord],
                 showingHidden: Bool = false) -> [WinlinkRMSStationRecord] {
        stations.filter { station in
            guard showsFrequency(station.frequencyHz) else { return false }
            return showingHidden || !isHidden(station)
        }
    }

    /// Frequencies present in the data, ascending — the choices worth
    /// offering, rather than every frequency an RMS might ever use.
    static func frequencies(in stations: [WinlinkRMSStationRecord]) -> [Int] {
        Array(Set(stations.map(\.frequencyHz))).sorted()
    }

    /// How many links a filter is hiding, for the "showing N of M" line.
    /// Silent truncation reads as "that is everything" when it is not.
    func hiddenCount(in stations: [WinlinkRMSStationRecord]) -> Int {
        stations.count - visible(stations).count
    }
}
