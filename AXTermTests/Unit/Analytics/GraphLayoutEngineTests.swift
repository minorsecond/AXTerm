//
//  GraphLayoutEngineTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-20.
//

import CoreGraphics
import XCTest
@testable import AXTerm

final class GraphLayoutEngineTests: XCTestCase {
    func testLayoutIsDeterministicWithSeed() {
        let nodes = [
            GraphNode(id: "A", degree: 2, count: 10, bytes: 50),
            GraphNode(id: "B", degree: 1, count: 5, bytes: 20),
            GraphNode(id: "C", degree: 1, count: 2, bytes: 10)
        ]
        let edges = [
            GraphEdge(source: "A", target: "B", count: 5, bytes: 20),
            GraphEdge(source: "A", target: "C", count: 2, bytes: 10)
        ]
        let size = CGSize(width: 200, height: 160)

        let first = GraphLayoutEngine.layout(nodes: nodes, edges: edges, size: size, seed: 42)
        let second = GraphLayoutEngine.layout(nodes: nodes, edges: edges, size: size, seed: 42)

        XCTAssertEqual(first, second)
    }

    func testLayoutPositionsAreFinite() {
        let nodes = [
            GraphNode(id: "A", degree: 2, count: 10, bytes: 50),
            GraphNode(id: "B", degree: 1, count: 5, bytes: 20)
        ]
        let edges = [
            GraphEdge(source: "A", target: "B", count: 5, bytes: 20)
        ]
        let size = CGSize(width: 120, height: 120)

        let positions = GraphLayoutEngine.layout(nodes: nodes, edges: edges, size: size, seed: 7)

        XCTAssertTrue(positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testLayoutPositionsAreWithinBounds() {
        let nodes = [
            GraphNode(id: "A", degree: 3, count: 10, bytes: 50),
            GraphNode(id: "B", degree: 2, count: 7, bytes: 20),
            GraphNode(id: "C", degree: 1, count: 3, bytes: 12)
        ]
        let edges = [
            GraphEdge(source: "A", target: "B", count: 3, bytes: 12),
            GraphEdge(source: "A", target: "C", count: 1, bytes: 5)
        ]
        let size = CGSize(width: 180, height: 140)

        let positions = GraphLayoutEngine.layout(nodes: nodes, edges: edges, size: size, seed: 11)

        for position in positions {
            XCTAssertGreaterThanOrEqual(position.x, 0)
            XCTAssertLessThanOrEqual(position.x, Double(size.width))
            XCTAssertGreaterThanOrEqual(position.y, 0)
            XCTAssertLessThanOrEqual(position.y, Double(size.height))
        }
    }

    func testLayoutHandlesEmptyNodes() {
        let positions = GraphLayoutEngine.layout(nodes: [], edges: [], size: .zero, seed: 0)

        XCTAssertTrue(positions.isEmpty)
    }
}
