//
//  StationTracker.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

struct StationTracker {
    private(set) var stations: [Station] = []
    private var stationIndex: [String: Int] = [:]

    mutating func update(with packet: Packet) {
        guard let from = packet.from else { return }
        let call = from.display

        if let index = stationIndex[call] {
            stations[index].lastHeard = packet.timestamp
            stations[index].heardCount += 1
            if !packet.via.isEmpty {
                stations[index].lastVia = packet.via.map { $0.display }
            }
        } else {
            let station = Station(
                call: call,
                lastHeard: packet.timestamp,
                heardCount: 1,
                lastVia: packet.via.map { $0.display }
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
                    if !packet.via.isEmpty {
                        aggregate.lastVia = packet.via.map { $0.display }
                    }
                }
            } else {
                aggregate.lastHeard = packet.timestamp
                aggregate.lastVia = packet.via.map { $0.display }
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
