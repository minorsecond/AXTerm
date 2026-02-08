import CoreGraphics
import Foundation
import XCTest
@testable import AXTerm

final class ForceLayoutEngineTests: XCTestCase {

    func testDeterministicPositionsWithFixedSeed() {
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

        XCTAssertEqual(tickA.positions, tickB.positions)
    }

    func testPositionsRemainFiniteAndBounded() {
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
            XCTAssertTrue(position.x.isFinite)
            XCTAssertTrue(position.y.isFinite)
            XCTAssertTrue(position.x >= 0 && position.x <= 1)
            XCTAssertTrue(position.y >= 0 && position.y <= 1)
        }
    }

    func testEnergyDecreasesOverIterations() {
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

        // Energy should decrease or remain stable over iterations (damped system)
        // Using >= comparison since last energy should be <= first energy
        XCTAssertLessThanOrEqual(energies.last ?? 0, energies.first ?? 0,
                                  "Energy should decrease or stay stable over iterations")
    }

    private func sampleModel() -> GraphModel {
        let nodes = [
            NetworkGraphNode(id: "W1AAA", callsign: "W1AAA", weight: 4, inCount: 2, outCount: 2, inBytes: 20, outBytes: 20, degree: 2),
            NetworkGraphNode(id: "K2BBB", callsign: "K2BBB", weight: 3, inCount: 1, outCount: 2, inBytes: 10, outBytes: 15, degree: 2),
            NetworkGraphNode(id: "N3CCC", callsign: "N3CCC", weight: 2, inCount: 2, outCount: 0, inBytes: 12, outBytes: 0, degree: 1)
        ]
        let edges = [
            NetworkGraphEdge(sourceID: "W1AAA", targetID: "K2BBB", weight: 3, bytes: 30, isStale: false),
            NetworkGraphEdge(sourceID: "K2BBB", targetID: "N3CCC", weight: 2, bytes: 20, isStale: false)
        ]
        return GraphModel(nodes: nodes, edges: edges, adjacency: [:], droppedNodesCount: 0)
    }
}
