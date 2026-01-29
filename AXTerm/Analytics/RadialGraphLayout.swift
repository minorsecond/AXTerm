//
//  RadialGraphLayout.swift
//  AXTerm
//
//  Stable radial layout: BFS hop rings from center (my node or highest degree).
//  Positions are normalized [0,1]; only recomputed when topology changes (GraphLayoutKey).
//

import Foundation

/// Key from graph topology only; used to cache layout so positions only change when nodes/edges change.
struct GraphLayoutKey: Hashable {
    let nodeIDsChecksum: Int
    let edgeCount: Int
    let edgesChecksum: Int

    static func from(model: GraphModel) -> GraphLayoutKey {
        var nodeHasher = Hasher()
        for n in model.nodes.map(\.id).sorted() {
            n.hash(into: &nodeHasher)
        }
        var edgeHasher = Hasher()
        for e in model.edges.sorted(by: { a, b in
            if a.sourceID != b.sourceID { return a.sourceID < b.sourceID }
            if a.targetID != b.targetID { return a.targetID < b.targetID }
            return a.weight <= b.weight
        }) {
            e.sourceID.hash(into: &edgeHasher)
            e.targetID.hash(into: &edgeHasher)
        }
        return GraphLayoutKey(
            nodeIDsChecksum: nodeHasher.finalize(),
            edgeCount: model.edges.count,
            edgesChecksum: edgeHasher.finalize()
        )
    }
}

enum RadialGraphLayout {
    /// Produces stable normalized positions [0,1] for all nodes: radial rings by BFS hop distance from center.
    /// Center = node matching myCallsign (base callsign) if present; otherwise highest-degree node.
    /// Within each ring, nodes ordered by descending edge weight then degree.
    static func layout(model: GraphModel, myCallsign: String) -> [NodePosition] {
        let nodes = model.nodes
        let edges = model.edges
        guard !nodes.isEmpty else { return [] }

        let normalizedMy = myCallsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .split(separator: "-").first.map(String.init) ?? ""

        // Pick center: my node by base callsign, else highest degree
        let centerID: String = {
            if !normalizedMy.isEmpty,
               let my = nodes.first(where: { baseCallsign($0.callsign) == normalizedMy }) {
                return my.id
            }
            return nodes.max(by: { $0.degree < $1.degree })?.id ?? nodes[0].id
        }()

        // Adjacency: neighbor -> [(nodeID, edgeWeight)]
        var neighbors: [String: [(id: String, weight: Int)]] = [:]
        for n in nodes { neighbors[n.id] = [] }
        for e in edges {
            if e.sourceID != e.targetID {
                neighbors[e.sourceID, default: []].append((e.targetID, e.weight))
                neighbors[e.targetID, default: []].append((e.sourceID, e.weight))
            }
        }

        // BFS by hop distance; collect (nodeID, hop, totalEdgeWeight, degree)
        var hopRings: [Int: [(id: String, weight: Int, degree: Int)]] = [:]
        var visited = Set<String>()
        var queue: [(id: String, hop: Int)] = [(centerID, 0)]
        visited.insert(centerID)
        while !queue.isEmpty {
            let (id, hop) = queue.removeFirst()
            let node = nodes.first(where: { $0.id == id })!
            let totalWeight = (neighbors[id] ?? []).reduce(0) { $0 + $1.weight }
            hopRings[hop, default: []].append((id, totalWeight, node.degree))
            for (nid, _) in neighbors[id] ?? [] {
                if visited.insert(nid).inserted {
                    queue.append((nid, hop + 1))
                }
            }
        }

        // Order within each ring: by weight desc, then degree desc, then id
        let maxHop = hopRings.keys.max() ?? 0
        var ordered: [(id: String, hop: Int)] = []
        for h in 0...maxHop {
            let ring = hopRings[h] ?? []
            let sorted = ring.sorted { a, b in
                if a.weight != b.weight { return a.weight > b.weight }
                if a.degree != b.degree { return a.degree > b.degree }
                return a.id < b.id
            }
            ordered.append(contentsOf: sorted.map { ($0.id, h) })
        }

        // Place on concentric rings in [0,1]; center at (0.5, 0.5)
        let margin: Double = 0.12
        let centerX = 0.5
        let centerY = 0.5
        let maxR = 0.5 - margin
        var positions: [NodePosition] = []
        positions.reserveCapacity(ordered.count)
        var ringIndexByHop: [Int: Int] = [:]
        for (id, hop) in ordered {
            let x: Double
            let y: Double
            if hop == 0 {
                x = centerX
                y = centerY
            } else {
                let ringCount = hopRings[hop]?.count ?? 1
                let idx = ringIndexByHop[hop] ?? 0
                ringIndexByHop[hop] = idx + 1
                let angleStep = ringCount > 1 ? (2.0 * .pi) / Double(ringCount) : 0
                let angle = angleStep * Double(idx) + (Double(hop).truncatingRemainder(dividingBy: 2) * 0.5)
                let r = maxR * (Double(hop) / max(1, Double(maxHop)))
                x = centerX + r * cos(angle)
                y = centerY + r * sin(angle)
            }
            let clampedX = min(1 - margin, max(margin, x))
            let clampedY = min(1 - margin, max(margin, y))
            positions.append(NodePosition(id: id, x: clampedX, y: clampedY))
        }
        return positions
    }

    private static func baseCallsign(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .split(separator: "-").first.map(String.init) ?? ""
    }
}
