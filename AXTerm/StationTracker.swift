//
//  StationTracker.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

nonisolated struct StationTracker {
    private(set) var stations: [Station] = []
    private var stationIndex: [String: Int] = [:]

    /// The path a packet was actually HEARD over: the digipeaters whose H-bit
    /// is set, i.e. whose transmitter produced the copy that reached our
    /// antenna. Empty means we heard the station's own transmitter directly —
    /// even when a via path is listed but not yet acted on.
    static func heardVia(_ packet: Packet) -> [String] {
        packet.via.filter { $0.repeated }.map { $0.display }
    }

    /// Folds in lifetime totals read from the log.
    ///
    /// Applied to stations already listed rather than adding rows for every
    /// callsign ever heard: the sidebar lists what is on the air now, and
    /// turning it into a historical roster is a different feature. This only
    /// corrects the number beside a station that is already there.
    mutating func applyLifetimeCounts(_ counts: [String: Int]) {
        for index in stations.indices {
            if let lifetime = counts[stations[index].call.uppercased()] {
                stations[index].lifetimeCount = lifetime
            }
        }
    }

    /// Attach an APRS position from this packet, if it carries one. A fix is
    /// added to the trail only when the station has actually moved, so a fixed
    /// station beaconing every few minutes does not grow an endless track.
    static func applyAPRS(_ station: inout Station, packet: Packet) {
        guard !packet.info.isEmpty,
              let report = APRSParser.parse(destination: packet.to?.call ?? "", info: packet.info)
        else { return }
        station.aprs = report
        let fix = Station.APRSFix(latitude: report.latitude, longitude: report.longitude,
                                  timestamp: packet.timestamp)
        if let last = station.track.last,
           abs(last.latitude - fix.latitude) < 1e-5, abs(last.longitude - fix.longitude) < 1e-5 {
            station.track[station.track.count - 1].timestamp = fix.timestamp
        } else {
            station.track.append(fix)
            if station.track.count > 30 { station.track.removeFirst(station.track.count - 30) }
        }
    }

    mutating func update(with packet: Packet) {
        guard let from = packet.from else { return }
        let call = from.display
        let radio = packet.radioID ?? .primary
        let via = Self.heardVia(packet)

        if let index = stationIndex[call] {
            stations[index].lastHeard = packet.timestamp
            stations[index].heardCount += 1
            // Always overwrite — including with empty. The old code only wrote
            // non-empty paths, so a station once heard via a digi showed
            // "Via DRLNOD, FNKTWN" forever, even while an entire direct
            // session was proving we hear its own transmitter (sidebar said
            // via-digi while the session correctly said direct).
            stations[index].lastVia = via
            Self.note(&stations[index], radio: radio, at: packet.timestamp, via: via)
            Self.applyAPRS(&stations[index], packet: packet)
        } else {
            var station = Station(
                call: call,
                lastHeard: packet.timestamp,
                heardCount: 1,
                lastVia: via
            )
            Self.note(&station, radio: radio, at: packet.timestamp, via: via)
            Self.applyAPRS(&station, packet: packet)
            stations.append(station)
            stationIndex[call] = stations.count - 1
        }

        sortStations()
    }

    /// Another radio heard a frame this tracker already counted — the same
    /// transmission, a second receiver. The station's count does not move;
    /// which radios can hear it does.
    mutating func noteHeard(_ call: String, on radio: RadioID, at when: Date, via: [String]) {
        guard let index = stationIndex[call] else { return }
        Self.note(&stations[index], radio: radio, at: when, via: via)
    }

    private static func note(_ station: inout Station, radio: RadioID, at when: Date, via: [String]) {
        if var observation = station.perRadio[radio] {
            observation.lastHeard = max(observation.lastHeard, when)
            observation.heardCount += 1
            observation.lastVia = via
            station.perRadio[radio] = observation
        } else {
            station.perRadio[radio] = Station.RadioObservation(lastHeard: when, heardCount: 1, lastVia: via)
        }
    }

    mutating func reset() {
        stations.removeAll()
        stationIndex.removeAll()
    }

    mutating func rebuild(from packets: [Packet]) {
        stations.removeAll(keepingCapacity: true)
        stationIndex.removeAll(keepingCapacity: true)

        struct Aggregation {
            var lastHeard: Date?
            var heardCount: Int = 0
            var lastVia: [String] = []
            var perRadio: [RadioID: Station.RadioObservation] = [:]
        }

        var aggregates: [String: Aggregation] = [:]

        for packet in packets where !packet.isOwnEcho {
            guard let from = packet.from else { continue }
            let call = from.display
            var aggregate = aggregates[call, default: Aggregation()]
            aggregate.heardCount += 1
            let radio = packet.radioID ?? .primary
            if var observation = aggregate.perRadio[radio] {
                observation.lastHeard = max(observation.lastHeard, packet.timestamp)
                observation.heardCount += 1
                observation.lastVia = Self.heardVia(packet)
                aggregate.perRadio[radio] = observation
            } else {
                aggregate.perRadio[radio] = Station.RadioObservation(
                    lastHeard: packet.timestamp, heardCount: 1, lastVia: Self.heardVia(packet))
            }
            if let currentLastHeard = aggregate.lastHeard {
                if packet.timestamp >= currentLastHeard {
                    aggregate.lastHeard = packet.timestamp
                    aggregate.lastVia = Self.heardVia(packet)
                }
            } else {
                aggregate.lastHeard = packet.timestamp
                aggregate.lastVia = Self.heardVia(packet)
            }
            aggregates[call] = aggregate
        }

        stations = aggregates.map { call, aggregate in
            var station = Station(
                call: call,
                lastHeard: aggregate.lastHeard,
                heardCount: aggregate.heardCount,
                lastVia: aggregate.lastVia
            )
            station.perRadio = aggregate.perRadio
            return station
        }
        sortStations()
    }

    func heardCount(for call: String) -> Int? {
        guard let index = stationIndex[call] else { return nil }
        return stations[index].heardCount
    }

    private mutating func sortStations() {
        stations.sort {
            let leftDate = $0.lastHeard ?? .distantPast
            let rightDate = $1.lastHeard ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return $0.call.localizedCaseInsensitiveCompare($1.call) == .orderedAscending
        }
        stationIndex.removeAll()
        for (index, station) in stations.enumerated() {
            stationIndex[station.call] = index
        }
    }
}
