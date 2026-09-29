//
//  GraphLayoutEngine.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-20.
//

import CoreGraphics
import Foundation

nonisolated struct GraphLayoutResult: Hashable, Sendable {
    let nodes: [NodePosition]
    let edges: [GraphEdge]

    static let empty = GraphLayoutResult(nodes: [], edges: [])
}

nonisolated enum GraphLayoutEngine {
    static let algorithmName = "radial"
    static let iterations = 1

    static func layout(
        nodes: [GraphNode],
        edges: [GraphEdge],
        size: CGSize,
        seed: Int
    ) -> [NodePosition] {
        _ = edges
        guard !nodes.isEmpty else { return [] }

        let orderedNodes = nodes.sorted { lhs, rhs in
            if lhs.degree != rhs.degree {
                return lhs.degree > rhs.degree
            }
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            let lhsBytes = lhs.bytes ?? 0
            let rhsBytes = rhs.bytes ?? 0
            if lhsBytes != rhsBytes {
                return lhsBytes > rhsBytes
            }
            return lhs.id < rhs.id
        }

        let safeWidth = size.width.isFinite ? Double(max(0, size.width)) : 0
        let safeHeight = size.height.isFinite ? Double(max(0, size.height)) : 0
        let padding = min(24.0, min(safeWidth, safeHeight) * 0.1)
        let paddingX = min(padding, safeWidth / 2)
        let paddingY = min(padding, safeHeight / 2)
        let centerX = safeWidth / 2
        let centerY = safeHeight / 2
        let availableWidth = max(0, safeWidth - paddingX * 2)
        let availableHeight = max(0, safeHeight - paddingY * 2)
        let radius = max(0, min(availableWidth, availableHeight) / 2)

        var generator = SeededGenerator(seed: seed)
        let startAngle: Double
        if orderedNodes.count > 1 {
            startAngle = Double.random(in: 0 ..< (Double.pi * 2), using: &generator)
        } else {
            startAngle = 0
        }
        let step = orderedNodes.count > 1 ? (Double.pi * 2) / Double(orderedNodes.count - 1) : 0

        var positions: [NodePosition] = []
        positions.reserveCapacity(orderedNodes.count)

        for (index, node) in orderedNodes.enumerated() {
            let x: Double
            let y: Double
            if index == 0 {
                x = centerX
                y = centerY
            } else {
                let angle = startAngle + step * Double(index - 1)
                x = centerX + radius * cos(angle)
                y = centerY + radius * sin(angle)
            }

            let clampedX = clamp(x, min: paddingX, max: safeWidth - paddingX)
            let clampedY = clamp(y, min: paddingY, max: safeHeight - paddingY)
            positions.append(NodePosition(id: node.id, x: clampedX, y: clampedY))
        }

        return positions
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        if min > max {
            return max
        }
        return Swift.max(min, Swift.min(max, value))
    }
}

nonisolated private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        let seedValue = UInt64(bitPattern: Int64(seed))
        state = seedValue == 0 ? 0x9E3779B97F4A7C15 : seedValue
    }

    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        return state
    }
}
