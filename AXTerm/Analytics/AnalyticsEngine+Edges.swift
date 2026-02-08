//
//  AnalyticsEngine+Edges.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-20.
//

import Foundation

extension AnalyticsEngine {
    static func computeEdges(
        packets: [Packet],
        includeViaDigipeaters: Bool,
        minCount: Int
    ) -> [GraphEdge] {
        guard !packets.isEmpty else { return [] }
        let events = normalizePackets(packets)
        var edges: [EdgeKey: EdgeAggregate] = [:]

        events.forEach { event in
            guard let from = event.from, let to = event.to else { return }
            let path: [String]
            if includeViaDigipeaters {
                path = [from] + event.via + [to]
            } else {
                path = [from, to]
            }
            guard path.count >= 2 else { return }

            for index in 0..<(path.count - 1) {
                let source = path[index]
                let target = path[index + 1]
                guard !source.isEmpty, !target.isEmpty else { continue }
                let key = EdgeKey(source: source, target: target)
                var aggregate = edges[key, default: EdgeAggregate()]
                aggregate.count += 1
                aggregate.bytes += event.payloadBytes
                edges[key] = aggregate
            }
        }

        return edges
            .map { GraphEdge(source: $0.key.source, target: $0.key.target, count: $0.value.count, bytes: $0.value.bytes) }
            .filter { $0.count >= minCount }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    if lhs.source == rhs.source {
                        return lhs.target < rhs.target
                    }
                    return lhs.source < rhs.source
                }
                return lhs.count > rhs.count
            }
    }
}

private struct EdgeKey: Hashable {
    let source: String
    let target: String
}

private struct EdgeAggregate {
    var count: Int = 0
    var bytes: Int = 0
}
