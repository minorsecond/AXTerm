//
//  StationInspectorViewModel.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-23.
//

import Combine
import Foundation

final class StationInspectorViewModel: ObservableObject, Identifiable {
    struct PeerStats: Identifiable, Equatable {
        let stationID: String
        let count: Int

        var id: String { stationID }
    }

    struct StationStats: Equatable {
        let stationID: String
        let fromCount: Int
        let toCount: Int
        let viaCount: Int
        let topPeers: [PeerStats]
    }

    let stationID: String

    @Published private(set) var stats: StationStats

    init(stationID: String, packets: [Packet], edges: [GraphEdge]) {
        self.stationID = stationID
        self.stats = StationInspectorViewModel.computeStats(
            stationID: stationID,
            packets: packets,
            edges: edges
        )
    }

    func update(packets: [Packet], edges: [GraphEdge]) {
        stats = StationInspectorViewModel.computeStats(
            stationID: stationID,
            packets: packets,
            edges: edges
        )
    }

    private static func computeStats(
        stationID: String,
        packets: [Packet],
        edges: [GraphEdge],
        topPeerLimit: Int = 6
    ) -> StationStats {
        Telemetry.measure(name: "analytics.station.inspect.compute") {
            let fromCount = packets.filter { $0.from?.call == stationID }.count
            let toCount = packets.filter { $0.to?.call == stationID }.count
            let viaCount = packets.filter { packet in
                packet.via.contains(where: { $0.call == stationID })
            }.count

            var peerCounts: [String: Int] = [:]
            for edge in edges {
                if edge.source == stationID {
                    peerCounts[edge.target, default: 0] += edge.count
                } else if edge.target == stationID {
                    peerCounts[edge.source, default: 0] += edge.count
                }
            }

            let topPeers = peerCounts
                .map { PeerStats(stationID: $0.key, count: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count {
                        return lhs.count > rhs.count
                    }
                    return lhs.stationID.localizedCaseInsensitiveCompare(rhs.stationID) == .orderedAscending
                }
                .prefix(topPeerLimit)

            return StationStats(
                stationID: stationID,
                fromCount: fromCount,
                toCount: toCount,
                viaCount: viaCount,
                topPeers: Array(topPeers)
            )
        }
    }
}
