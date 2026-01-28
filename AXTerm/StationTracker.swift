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

    private mutating func sortStations() {
        stations.sort { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
        stationIndex.removeAll()
        for (index, station) in stations.enumerated() {
            stationIndex[station.call] = index
        }
    }
}
