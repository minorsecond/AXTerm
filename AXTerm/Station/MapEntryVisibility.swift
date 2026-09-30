import Foundation

/// Which heard entries the Map draws, and which rows its station list shows.
///
/// The markers and the list beside them used to be filtered in two places.
/// The markers went through "Drop after", Transmitted Positions and the four
/// station-type switches; the list went through none of them, so a station
/// that had gone quiet for a day, or a license-address dot hidden by
/// Transmitted Positions, stayed in "On the map" with nothing drawn for it.
/// Both now ask this one value.
nonisolated struct MapEntryVisibility: Sendable {

    /// "Drop after", in minutes. Zero keeps everything.
    var falloffMinutes: Int = 0
    /// Transmitted Positions: a placed station shows only at its own beaconed
    /// fix, when it was heard on a radio carrying APRS.
    var prefersTransmittedPosition: Bool = false
    var showsDigipeaters: Bool = true
    var showsWeather: Bool = true
    var showsVehicles: Bool = true
    var showsFixed: Bool = true
    /// Callsigns heard on at least one radio carrying APRS, upper-cased. See
    /// `callsOnAPRSChannels`.
    var callsOnAPRSChannels: Set<String> = []
    var now: Date = Date()

    /// Whether an entry has been heard recently enough to stay listed.
    ///
    /// An entry with no heard time at all is a directory lead rather than a
    /// heard station and is governed by its own layer, so it always passes.
    func withinFalloff(_ entry: HeardStationMap.Entry) -> Bool {
        guard falloffMinutes > 0 else { return true }
        guard let lastHeard = entry.lastHeard else { return true }
        return now.timeIntervalSince(lastHeard) <= Double(falloffMinutes) * 60
    }

    /// Whether a placed entry survives the per-type switches. Only a station
    /// at its transmitted fix carries a symbol to classify; everything else
    /// passes untouched.
    func typeVisible(_ entry: HeardStationMap.Entry) -> Bool {
        guard let code = entry.aprsSymbol?.code else { return true }
        switch APRSTypeBucket.of(code: code) {
        case .digipeater: return showsDigipeaters
        case .weather:    return showsWeather
        case .vehicle:    return showsVehicles
        case .fixed:      return showsFixed
        }
    }

    /// Whether a placed entry gets a marker.
    func drawsMarker(_ entry: HeardStationMap.Entry) -> Bool {
        guard entry.isPlaced, withinFalloff(entry) else { return false }
        guard prefersTransmittedPosition else { return true }
        // An APRS layer only governs APRS stations. A station heard only on a
        // radio that carries no APRS (a packet channel of nodes and sessions)
        // has no beaconed fix to prefer and must not be hidden for lacking
        // one, which emptied the whole map whenever such a radio was the one
        // being shown.
        guard entry.isNodeAlias || entry.origin == .transmittedAPRS
                || !callsOnAPRSChannels.contains(entry.callsign.uppercased())
        else { return false }
        return typeVisible(entry)
    }

    /// The entries the map's scope is built from. Unplaced entries pass
    /// through untouched: the scope ignores them, and the analysis layers
    /// downstream still want them.
    func entriesForMap(_ entries: [HeardStationMap.Entry]) -> [HeardStationMap.Entry] {
        entries.filter { !$0.isPlaced || drawsMarker($0) }
    }

    /// The station list's two sections. "On the map" is exactly the placed
    /// entries that get a marker; "No known position" is the unplaced ones
    /// still inside "Drop after".
    func listSections(_ entries: [HeardStationMap.Entry])
        -> (onMap: [HeardStationMap.Entry], noPosition: [HeardStationMap.Entry]) {
        var onMap: [HeardStationMap.Entry] = []
        var noPosition: [HeardStationMap.Entry] = []
        for entry in entries {
            if entry.isPlaced {
                if drawsMarker(entry) { onMap.append(entry) }
            } else if withinFalloff(entry) {
                noPosition.append(entry)
            }
        }
        return (onMap, noPosition)
    }

    /// Callsigns heard on at least one radio that carries APRS.
    ///
    /// A radio that has heard nothing classifiable yet counts as APRS, so a
    /// fresh session behaves exactly as it did before any evidence arrived
    /// rather than briefly drawing a different map. A station with no
    /// per-radio record at all counts too, for the same reason.
    ///
    /// - Parameter families: what each radio carries, already narrowed by
    ///   `RadioTrafficClassifier.mapFamilies` so a radio marked as on an APRS
    ///   channel counts as APRS whatever else it has heard.
    static func callsOnAPRSChannels(stations: [Station],
                                    families: [RadioID: Set<RadioTrafficFamily>]) -> Set<String> {
        var result: Set<String> = []
        for station in stations {
            let onAPRS = station.perRadio.keys.contains { radio in
                guard let known = families[radio], !known.isEmpty else { return true }
                return known.contains(.aprs)
            }
            if onAPRS || station.perRadio.isEmpty { result.insert(station.call.uppercased()) }
        }
        return result
    }
}
