//
//  NetworkGraphBuilder.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-01.
//

import Foundation

struct NetworkGraphBuilder {
    struct Options: Hashable, Sendable {
        let includeViaDigipeaters: Bool
        let minimumEdgeCount: Int
        let maxNodes: Int
    }

    static func build(packets: [Packet], options: Options) -> GraphModel {
        let events = packets.map { PacketEvent(packet: $0) }
        return build(events: events, options: options)
    }

    static func build(events: [PacketEvent], options: Options) -> GraphModel {
        guard !events.isEmpty else { return .empty }

        var directedEdges: [DirectedKey: EdgeAggregate] = [:]
        var nodeStats: [String: NodeAggregate] = [:]

        for event in events {
            guard let from = event.from, let to = event.to else { continue }
            let path: [String]
            if options.includeViaDigipeaters {
                path = [from] + event.via + [to]
            } else {
                path = [from, to]
            }
            guard path.count >= 2 else { continue }

            for index in 0..<(path.count - 1) {
                let source = path[index]
                let target = path[index + 1]
                guard !source.isEmpty, !target.isEmpty else { continue }

                let key = DirectedKey(source: source, target: target)
                var aggregate = directedEdges[key, default: EdgeAggregate()]
                aggregate.count += 1
                aggregate.bytes += event.payloadBytes
                directedEdges[key] = aggregate

                var sourceStats = nodeStats[source, default: NodeAggregate()]
                sourceStats.outCount += 1
                sourceStats.outBytes += event.payloadBytes
                nodeStats[source] = sourceStats

                var targetStats = nodeStats[target, default: NodeAggregate()]
                targetStats.inCount += 1
                targetStats.inBytes += event.payloadBytes
                nodeStats[target] = targetStats
            }
        }

        var undirectedEdges: [UndirectedKey: EdgeAggregate] = [:]
        for (key, aggregate) in directedEdges {
            let undirectedKey = UndirectedKey(lhs: key.source, rhs: key.target)
            var existing = undirectedEdges[undirectedKey, default: EdgeAggregate()]
            existing.count += aggregate.count
            existing.bytes += aggregate.bytes
            undirectedEdges[undirectedKey] = existing
        }

        let filteredEdges = undirectedEdges
            .filter { $0.value.count >= max(1, options.minimumEdgeCount) }

        let specialDestinations = Set([
            "ID", "BEACON", "CQ", "QST", "SK", "CQ DX", "QSO", "TEST", "RELAY",
            "WIDEn", "WIDE1", "WIDE2", "TRACE", "TEMP", "GATE", "ECHO"
        ].map { $0.uppercased() })
        func isSpecialDestination(_ id: String) -> Bool {
            let upper = id.uppercased()
            if specialDestinations.contains(upper) { return true }
            if upper.hasPrefix("WIDE") && upper.count <= 6 { return true }
            return false
        }

        let edgesExcludingSpecial = filteredEdges.filter { key, _ in
            !isSpecialDestination(key.source) && !isSpecialDestination(key.target)
        }

        var adjacency: [String: [GraphNeighborStat]] = [:]
        for (key, aggregate) in edgesExcludingSpecial {
            adjacency[key.source, default: []].append(
                GraphNeighborStat(id: key.target, weight: aggregate.count, bytes: aggregate.bytes)
            )
            adjacency[key.target, default: []].append(
                GraphNeighborStat(id: key.source, weight: aggregate.count, bytes: aggregate.bytes)
            )
        }

        let activeNodeIDs = Set(edgesExcludingSpecial.flatMap { [$0.key.source, $0.key.target] })
        var nodes: [NetworkGraphNode] = []
        nodes.reserveCapacity(activeNodeIDs.count)

        for id in activeNodeIDs {
            guard let stats = nodeStats[id] else { continue }
            let neighbors = adjacency[id] ?? []
            let totalWeight = stats.inCount + stats.outCount
            let node = NetworkGraphNode(
                id: id,
                callsign: id,
                weight: totalWeight,
                inCount: stats.inCount,
                outCount: stats.outCount,
                inBytes: stats.inBytes,
                outBytes: stats.outBytes,
                degree: neighbors.count
            )
            nodes.append(node)
        }

        nodes.sort { lhs, rhs in
            if lhs.weight != rhs.weight {
                return lhs.weight > rhs.weight
            }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }

        let maxNodes = max(1, options.maxNodes)
        let keptNodes = Array(nodes.prefix(maxNodes))
        let keptIDs = Set(keptNodes.map { $0.id })
        let droppedCount = max(0, nodes.count - keptNodes.count)

        let edges: [NetworkGraphEdge] = edgesExcludingSpecial
            .filter { keptIDs.contains($0.key.source) && keptIDs.contains($0.key.target) }
            .map { key, aggregate in
                NetworkGraphEdge(
                    sourceID: key.source,
                    targetID: key.target,
                    weight: aggregate.count,
                    bytes: aggregate.bytes
                )
            }
            .sorted { lhs, rhs in
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.sourceID < rhs.sourceID
            }

        let prunedAdjacency = adjacency.reduce(into: [String: [GraphNeighborStat]]()) { result, entry in
            let (id, neighbors) = entry
            guard keptIDs.contains(id) else { return }
            let keptNeighbors = neighbors.filter { keptIDs.contains($0.id) }
            result[id] = keptNeighbors.sorted { lhs, rhs in
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.id < rhs.id
            }
        }

        let filteredNodes = keptNodes.map { node in
            guard let neighbors = prunedAdjacency[node.id] else { return node }
            return NetworkGraphNode(
                id: node.id,
                callsign: node.callsign,
                weight: node.weight,
                inCount: node.inCount,
                outCount: node.outCount,
                inBytes: node.inBytes,
                outBytes: node.outBytes,
                degree: neighbors.count
            )
        }

        return GraphModel(
            nodes: filteredNodes,
            edges: edges,
            adjacency: prunedAdjacency,
            droppedNodesCount: droppedCount
        )
    }
}

private struct DirectedKey: Hashable {
    let source: String
    let target: String
}

private struct UndirectedKey: Hashable {
    let source: String
    let target: String

    init(lhs: String, rhs: String) {
        if lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending {
            self.source = lhs
            self.target = rhs
        } else {
            self.source = rhs
            self.target = lhs
        }
    }
}

private struct EdgeAggregate {
    var count: Int = 0
    var bytes: Int = 0
}

private struct NodeAggregate {
    var inCount: Int = 0
    var outCount: Int = 0
    var inBytes: Int = 0
    var outBytes: Int = 0
}
