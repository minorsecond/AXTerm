//
//  RadialGraphLayout.swift
//  AXTerm
//
//  Stable radial layout: BFS hop rings from center (my node or highest degree).
//  Positions are normalized [0,1]; only recomputed when topology changes (GraphLayoutKey).
//

import Foundation

/// Key from graph topology only; used to cache layout so positions only change when nodes/edges change.
nonisolated struct GraphLayoutKey: Hashable {
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

nonisolated enum RadialGraphLayout {
    /// Produces stable normalized positions [0,1] for all nodes: radial rings by BFS hop distance from center.
    /// Center = node matching myCallsign (base callsign) if present; otherwise highest-degree node.
    /// Within each ring, nodes ordered by descending edge weight then degree.
    static func layout(model: GraphModel, myCallsign: String) -> [NodePosition] {
        let nodes = model.nodes
        let edges = model.edges
        guard !nodes.isEmpty else { return [] }

        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        let normalizedMy = myCallsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .split(separator: "-").first.map(String.init) ?? ""

        let centerID: String = {
            if !normalizedMy.isEmpty,
               let my = nodes.first(where: { baseCallsign($0.callsign) == normalizedMy }) {
                return my.id
            }
            return nodes.max(by: { $0.degree < $1.degree })?.id ?? nodes[0].id
        }()

        // neighbors
        var neighbors: [String: [(id: String, weight: Int)]] = [:]
        neighbors.reserveCapacity(nodes.count)
        for n in nodes { neighbors[n.id] = [] }
        for e in edges where e.sourceID != e.targetID {
            neighbors[e.sourceID, default: []].append((e.targetID, e.weight))
            neighbors[e.targetID, default: []].append((e.sourceID, e.weight))
        }

        // BFS
        var hopRings: [Int: [(id: String, weight: Int, degree: Int)]] = [:]
        var visited = Set<String>()
        visited.reserveCapacity(nodes.count)

        var queue: [(id: String, hop: Int)] = [(centerID, 0)]
        var qIndex = 0
        visited.insert(centerID)

        while qIndex < queue.count {
            let (id, hop) = queue[qIndex]
            qIndex += 1

            guard let node = nodeByID[id] else { continue }
            let totalWeight = (neighbors[id] ?? []).reduce(0) { $0 + $1.weight }
            hopRings[hop, default: []].append((id, totalWeight, node.degree))

            for (nid, _) in neighbors[id] ?? [] {
                if visited.insert(nid).inserted {
                    queue.append((nid, hop + 1))
                }
            }
        }

        // nodes not reached by BFS (disconnected in the *view graph*)
        let unreachable = nodes.map(\.id).filter { !visited.contains($0) }

        // order rings
        let maxHop = hopRings.keys.max() ?? 0
        var ordered: [(id: String, hop: Int)] = []
        ordered.reserveCapacity(nodes.count)

        for h in 0...maxHop {
            let ring = hopRings[h] ?? []
            let sorted = ring.sorted { a, b in
                if a.weight != b.weight { return a.weight > b.weight }
                if a.degree != b.degree { return a.degree > b.degree }
                return a.id < b.id
            }
            ordered.append(contentsOf: sorted.map { ($0.id, h) })
        }

        // append unreachable as a final ring (maxHop+1)
        if !unreachable.isEmpty {
            let islandHop = maxHop + 1
            let sortedIslands = unreachable.sorted()
            ordered.append(contentsOf: sortedIslands.map { ($0, islandHop) })
        }

        // place
        let margin: Double = 0.12
        let centerX = 0.5
        let centerY = 0.5
        let maxR = 0.5 - margin

        let effectiveMaxHop = max(maxHop + (unreachable.isEmpty ? 0 : 1), 1)

        var positions: [NodePosition] = []
        positions.reserveCapacity(ordered.count)

        var ringIndexByHop: [Int: Int] = [:]

        // precompute ring sizes
        var ringCounts: [Int: Int] = [:]
        for (_, hop) in ordered { ringCounts[hop, default: 0] += 1 }

        for (id, hop) in ordered {
            let x: Double
            let y: Double
            if hop == 0 {
                x = centerX
                y = centerY
            } else {
                let ringCount = ringCounts[hop] ?? 1
                let idx = ringIndexByHop[hop] ?? 0
                ringIndexByHop[hop] = idx + 1

                let angleStep = ringCount > 1 ? (2.0 * .pi) / Double(ringCount) : 0
                let angle = angleStep * Double(idx) + (Double(hop).truncatingRemainder(dividingBy: 2) * 0.5)

                let r = maxR * (Double(hop) / Double(effectiveMaxHop))
                x = centerX + r * cos(angle)
                y = centerY + r * sin(angle)
            }

            let clampedX = min(1 - margin, max(margin, x))
            let clampedY = min(1 - margin, max(margin, y))
            positions.append(NodePosition(id: id, x: clampedX, y: clampedY))
        }

        // This should now always be true
        assert(positions.count == model.nodes.count, "Layout dropped nodes: \(positions.count)/\(model.nodes.count)")
        return positions
    }

    private static func baseCallsign(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .split(separator: "-").first.map(String.init) ?? ""
    }
}
