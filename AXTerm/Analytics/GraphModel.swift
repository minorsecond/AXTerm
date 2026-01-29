//
//  GraphModel.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-01.
//

import Foundation

struct NetworkGraphNode: Hashable, Sendable, Identifiable {
    let id: String
    let callsign: String
    let weight: Int
    let inCount: Int
    let outCount: Int
    let inBytes: Int
    let outBytes: Int
    let degree: Int
}

struct NetworkGraphEdge: Hashable, Sendable {
    let sourceID: String
    let targetID: String
    let weight: Int
    let bytes: Int
}

struct GraphNeighborStat: Hashable, Sendable {
    let id: String
    let weight: Int
    let bytes: Int
}

struct GraphModel: Hashable, Sendable {
    let nodes: [NetworkGraphNode]
    let edges: [NetworkGraphEdge]
    let adjacency: [String: [GraphNeighborStat]]
    let droppedNodesCount: Int

    static let empty = GraphModel(nodes: [], edges: [], adjacency: [:], droppedNodesCount: 0)
}
