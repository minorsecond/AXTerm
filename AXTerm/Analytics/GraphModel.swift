//
//  GraphModel.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-01.
//

import Foundation

nonisolated struct NetworkGraphNode: Hashable, Sendable, Identifiable {
    let id: String
    let callsign: String
    let weight: Int
    let inCount: Int
    let outCount: Int
    let inBytes: Int
    let outBytes: Int
    let degree: Int
    /// SSIDs grouped into this node (only populated when stationIdentityMode == .station)
    /// Example: When "ANH", "ANH-1", and "ANH-15" are grouped, this contains ["ANH", "ANH-1", "ANH-15"]
    let groupedSSIDs: [String]
    let isNetRomOfficial: Bool

    init(
        id: String,
        callsign: String,
        weight: Int,
        inCount: Int,
        outCount: Int,
        inBytes: Int,
        outBytes: Int,
        degree: Int,
        groupedSSIDs: [String] = [],
        isNetRomOfficial: Bool = false
    ) {
        self.id = id
        self.callsign = callsign
        self.weight = weight
        self.inCount = inCount
        self.outCount = outCount
        self.inBytes = inBytes
        self.outBytes = outBytes
        self.degree = degree
        self.groupedSSIDs = groupedSSIDs.isEmpty ? [callsign] : groupedSSIDs
        self.isNetRomOfficial = isNetRomOfficial
    }

    /// Whether this node represents multiple grouped SSIDs
    var isGroupedStation: Bool {
        groupedSSIDs.count > 1
    }

    /// Display string showing grouped SSIDs (e.g., "ANH (ANH-1, ANH-15)")
    var groupedDisplayString: String {
        guard isGroupedStation else { return callsign }
        let others = groupedSSIDs.filter { $0 != callsign }
        if others.isEmpty { return callsign }
        return "\(callsign) (\(others.joined(separator: ", ")))"
    }
}

nonisolated struct NetworkGraphEdge: Hashable, Sendable {
    let sourceID: String
    let targetID: String
    let weight: Int
    let bytes: Int
    let linkType: LinkType
    let isStale: Bool

    init(
        sourceID: String,
        targetID: String,
        weight: Int,
        bytes: Int,
        linkType: LinkType = .directPeer,
        isStale: Bool
    ) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.weight = weight
        self.bytes = bytes
        self.linkType = linkType
        self.isStale = isStale
    }
}

nonisolated struct GraphNeighborStat: Hashable, Sendable {
    let id: String
    let weight: Int
    let bytes: Int
    let isStale: Bool
}

nonisolated struct GraphModel: Hashable, Sendable {
    let nodes: [NetworkGraphNode]
    let edges: [NetworkGraphEdge]
    let adjacency: [String: [GraphNeighborStat]]
    let droppedNodesCount: Int

    static let empty = GraphModel(nodes: [], edges: [], adjacency: [:], droppedNodesCount: 0)
}
