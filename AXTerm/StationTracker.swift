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

    mutating func update(with packet: Packet) {
        guard let from = packet.from else { return }
        let call = from.display

        if let index = stationIndex[call] {
            stations[index].lastHeard = packet.timestamp
            stations[index].heardCount += 1
            // Always overwrite — including with empty. The old code only wrote
            // non-empty paths, so a station once heard via a digi showed
            // "Via DRLNOD, FNKTWN" forever, even while an entire direct
            // session was proving we hear its own transmitter (sidebar said
            // via-digi while the session correctly said direct).
            stations[index].lastVia = Self.heardVia(packet)
        } else {
            let station = Station(
                call: call,
                lastHeard: packet.timestamp,
                heardCount: 1,
                lastVia: Self.heardVia(packet)
            )
            stations.append(station)
            stationIndex[call] = stations.count - 1
        }

        sortStations()
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
        }

        var aggregates: [String: Aggregation] = [:]

        for packet in packets {
            guard let from = packet.from else { continue }
            let call = from.display
            var aggregate = aggregates[call, default: Aggregation()]
            aggregate.heardCount += 1
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
            Station(
                call: call,
                lastHeard: aggregate.lastHeard,
                heardCount: aggregate.heardCount,
                lastVia: aggregate.lastVia
            )
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
