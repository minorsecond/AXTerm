//
//  ForceLayoutEngine.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-01.
//

import CoreGraphics
import Foundation

struct ForceLayoutState: Hashable, Sendable {
    var positions: [String: CGPoint]
    var velocities: [String: CGVector]
    var energy: Double
}

enum ForceLayoutEngine {
    static func initialize(
        nodes: [NetworkGraphNode],
        previous: [String: CGPoint],
        seed: Int
    ) -> ForceLayoutState {
        var positions: [String: CGPoint] = [:]
        var velocities: [String: CGVector] = [:]

        for node in nodes {
            if let existing = previous[node.id] {
                positions[node.id] = clamp(position: existing)
            } else {
                positions[node.id] = seededPosition(for: node.id, seed: seed)
            }
            velocities[node.id] = .zero
        }

        return ForceLayoutState(positions: positions, velocities: velocities, energy: .infinity)
    }

    static func tick(
        model: GraphModel,
        state: ForceLayoutState,
        iterations: Int,
        repulsion: Double,
        springStrength: Double,
        springLength: Double,
        damping: Double,
        timeStep: Double
    ) -> ForceLayoutState {
        guard !model.nodes.isEmpty else { return state }

        var positions = state.positions
        var velocities = state.velocities

        let nodeIDs = model.nodes.map { $0.id }
        let nodeCount = nodeIDs.count
        let iterationCount = max(1, iterations)

        var energy: Double = 0

        for _ in 0..<iterationCount {
            energy = 0
            var forces: [String: CGVector] = [:]
            forces.reserveCapacity(nodeCount)
            nodeIDs.forEach { forces[$0] = .zero }

            for i in 0..<nodeCount {
                for j in (i + 1)..<nodeCount {
                    let idA = nodeIDs[i]
                    let idB = nodeIDs[j]
                    let positionA = positions[idA] ?? .zero
                    let positionB = positions[idB] ?? .zero

                    let dx = positionB.x - positionA.x
                    let dy = positionB.y - positionA.y
                    let distanceSquared = max(0.0001, dx * dx + dy * dy)
                    let distance = sqrt(distanceSquared)
                    let force = repulsion / distanceSquared
                    let fx = force * dx / distance
                    let fy = force * dy / distance

                    forces[idA] = forces[idA, default: .zero] - CGVector(dx: fx, dy: fy)
                    forces[idB] = forces[idB, default: .zero] + CGVector(dx: fx, dy: fy)
                }
            }

            for edge in model.edges {
                guard let source = positions[edge.sourceID], let target = positions[edge.targetID] else { continue }
                let dx = target.x - source.x
                let dy = target.y - source.y
                let distance = max(0.0001, hypot(dx, dy))
                let delta = distance - springLength
                let strength = springStrength * Double(edge.weight)
                let fx = strength * delta * dx / distance
                let fy = strength * delta * dy / distance

                forces[edge.sourceID] = forces[edge.sourceID, default: .zero] + CGVector(dx: fx, dy: fy)
                forces[edge.targetID] = forces[edge.targetID, default: .zero] - CGVector(dx: fx, dy: fy)
            }

            for id in nodeIDs {
                let velocity = velocities[id, default: .zero]
                let force = forces[id, default: .zero]
                let updatedVelocity = CGVector(
                    dx: (velocity.dx + force.dx * timeStep) * damping,
                    dy: (velocity.dy + force.dy * timeStep) * damping
                )
                velocities[id] = updatedVelocity
                let position = positions[id, default: .zero]
                let updatedPosition = CGPoint(
                    x: position.x + updatedVelocity.dx * timeStep,
                    y: position.y + updatedVelocity.dy * timeStep
                )
                positions[id] = clamp(position: updatedPosition)
                energy += Double(updatedVelocity.dx * updatedVelocity.dx + updatedVelocity.dy * updatedVelocity.dy)
            }
        }

        let normalizedEnergy: Double
        if state.energy.isFinite {
            normalizedEnergy = min(state.energy, energy)
        } else {
            normalizedEnergy = energy
        }

        return ForceLayoutState(positions: positions, velocities: velocities, energy: normalizedEnergy)
    }

    static func clamp(position: CGPoint) -> CGPoint {
        CGPoint(x: clamp(position.x), y: clamp(position.y))
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private static func seededPosition(for id: String, seed: Int) -> CGPoint {
        let hash = stableHash(id, seed: seed)
        let x = Double(hash & 0xFFFF_FFFF) / Double(UInt32.max)
        let y = Double((hash >> 32) & 0xFFFF_FFFF) / Double(UInt32.max)
        return CGPoint(x: clamp(CGFloat(x)), y: clamp(CGFloat(y)))
    }

    private static func stableHash(_ value: String, seed: Int) -> UInt64 {
        let seedValue = UInt64(bitPattern: Int64(seed))
        var hash: UInt64 = 14695981039346656037 ^ seedValue
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }
}

private extension CGVector {
    static func + (lhs: CGVector, rhs: CGVector) -> CGVector {
        CGVector(dx: lhs.dx + rhs.dx, dy: lhs.dy + rhs.dy)
    }

    static func - (lhs: CGVector, rhs: CGVector) -> CGVector {
        CGVector(dx: lhs.dx - rhs.dx, dy: lhs.dy - rhs.dy)
    }
}
