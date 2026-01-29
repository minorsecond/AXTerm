import CoreGraphics
import Foundation
import Testing
@testable import AXTerm

struct ForceLayoutEngineTests {
    @Test
    func deterministicPositionsWithFixedSeed() {
        let model = sampleModel()
        let stateA = ForceLayoutEngine.initialize(nodes: model.nodes, previous: [:], seed: 42)
        let stateB = ForceLayoutEngine.initialize(nodes: model.nodes, previous: [:], seed: 42)

        let tickA = ForceLayoutEngine.tick(
            model: model,
            state: stateA,
            iterations: 2,
            repulsion: 0.02,
            springStrength: 0.1,
            springLength: 0.2,
            damping: 0.9,
            timeStep: 0.02
        )

        let tickB = ForceLayoutEngine.tick(
            model: model,
            state: stateB,
            iterations: 2,
            repulsion: 0.02,
            springStrength: 0.1,
            springLength: 0.2,
            damping: 0.9,
            timeStep: 0.02
        )

        #expect(tickA.positions == tickB.positions)
    }

    @Test
    func positionsRemainFiniteAndBounded() {
        let model = sampleModel()
        var state = ForceLayoutEngine.initialize(nodes: model.nodes, previous: [:], seed: 1)

        for _ in 0..<5 {
            state = ForceLayoutEngine.tick(
                model: model,
                state: state,
                iterations: 2,
                repulsion: 0.02,
                springStrength: 0.1,
                springLength: 0.2,
                damping: 0.9,
                timeStep: 0.02
            )
        }

        for position in state.positions.values {
            #expect(position.x.isFinite)
            #expect(position.y.isFinite)
            #expect(position.x >= 0 && position.x <= 1)
            #expect(position.y >= 0 && position.y <= 1)
        }
    }

    @Test
    func energyDecreasesOverIterations() {
        let model = sampleModel()
        var state = ForceLayoutEngine.initialize(nodes: model.nodes, previous: [:], seed: 2)
        var energies: [Double] = []

        for _ in 0..<5 {
            state = ForceLayoutEngine.tick(
                model: model,
                state: state,
                iterations: 2,
                repulsion: 0.02,
                springStrength: 0.1,
                springLength: 0.2,
                damping: 0.9,
                timeStep: 0.02
            )
            energies.append(state.energy)
        }

        #expect((energies.last ?? 0) <= (energies.first ?? 0))
    }

    private func sampleModel() -> GraphModel {
        let nodes = [
            NetworkGraphNode(id: "A", callsign: "A", weight: 4, inCount: 2, outCount: 2, inBytes: 20, outBytes: 20, degree: 2),
            NetworkGraphNode(id: "B", callsign: "B", weight: 3, inCount: 1, outCount: 2, inBytes: 10, outBytes: 15, degree: 2),
            NetworkGraphNode(id: "C", callsign: "C", weight: 2, inCount: 2, outCount: 0, inBytes: 12, outBytes: 0, degree: 1)
        ]
        let edges = [
            NetworkGraphEdge(sourceID: "A", targetID: "B", weight: 3, bytes: 30),
            NetworkGraphEdge(sourceID: "B", targetID: "C", weight: 2, bytes: 20)
        ]
        return GraphModel(nodes: nodes, edges: edges, adjacency: [:], droppedNodesCount: 0)
    }
}
