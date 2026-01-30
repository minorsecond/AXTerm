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
        let stationIdentityMode: StationIdentityMode

        init(
            includeViaDigipeaters: Bool,
            minimumEdgeCount: Int,
            maxNodes: Int,
            stationIdentityMode: StationIdentityMode = .station
        ) {
            self.includeViaDigipeaters = includeViaDigipeaters
            self.minimumEdgeCount = minimumEdgeCount
            self.maxNodes = maxNodes
            self.stationIdentityMode = stationIdentityMode
        }
    }

    // MARK: - Standard Graph Building

    static func build(packets: [Packet], options: Options) -> GraphModel {
        let events = packets.map { PacketEvent(packet: $0) }
        return build(events: events, options: options)
    }

    // MARK: - Classified Graph Building (Part B)

    /// Build a classified graph with edges categorized by relationship type.
    ///
    /// Relationship types:
    /// - **DirectPeer**: Endpoint-to-endpoint packet exchange (from=S, to=P or vice versa)
    /// - **HeardDirect**: Packets decoded with no via path (direct RF likely)
    /// - **HeardVia**: Packets only observed through digipeater paths
    ///
    /// See Docs/NetworkGraphSemantics.md for full documentation.
    static func buildClassified(packets: [Packet], options: Options, now: Date = Date()) -> ClassifiedGraphModel {
        let events = packets.map { PacketEvent(packet: $0) }
        return buildClassified(events: events, options: options, now: now)
    }

    static func buildClassified(events: [PacketEvent], options: Options, now: Date = Date()) -> ClassifiedGraphModel {
        guard !events.isEmpty else { return .empty }

        let identityMode = options.stationIdentityMode

        // Helper: get identity key for a callsign based on mode
        func identityKey(for callsign: String) -> String {
            CallsignParser.identityKey(for: callsign, mode: identityMode)
        }

        // PHASE 1: Collect directional endpoint traffic for DirectPeer detection
        // DirectPeer requires BIDIRECTIONAL endpoint traffic: A→B AND B→A both exist
        var directionalEndpointTraffic: [DirectedKey: DirectionalTrafficAggregate] = [:]

        // Track HeardDirect data (one-way direct reception, no via path)
        var heardDirectData: [String: [String: HeardDirectAggregate]] = [:] // observer -> sender -> data

        // Track HeardVia data (observed via digipeaters only)
        var heardViaData: [String: [String: HeardViaAggregate]] = [:] // observer -> sender -> data

        // Track via path edges for graph visualization (digipeater links)
        var viaPathEdges: [UndirectedKey: ClassifiedEdgeAggregate] = [:]

        var nodeStats: [String: NodeAggregate] = [:]
        var identityMembers: [String: Set<String>] = [:]

        for event in events {
            guard let rawFrom = event.from, let rawTo = event.to else { continue }
            guard CallsignValidator.isValidCallsign(rawFrom) else { continue }
            guard CallsignValidator.isValidCallsign(rawTo) else { continue }

            // Convert to identity keys
            let from = identityKey(for: rawFrom)
            let to = identityKey(for: rawTo)

            // Track members
            identityMembers[from, default: []].insert(rawFrom.uppercased())
            identityMembers[to, default: []].insert(rawTo.uppercased())

            // Check if this is infrastructure traffic (excluded from DirectPeer)
            let isInfrastructure = event.frameType == .ui && (
                to.uppercased() == "ID" ||
                to.uppercased() == "BEACON" ||
                to.uppercased().hasPrefix("BBS")
            )

            // Update node stats
            var fromStats = nodeStats[from, default: NodeAggregate()]
            fromStats.outCount += 1
            fromStats.outBytes += event.payloadBytes
            nodeStats[from] = fromStats

            var toStats = nodeStats[to, default: NodeAggregate()]
            toStats.inCount += 1
            toStats.inBytes += event.payloadBytes
            nodeStats[to] = toStats

            if event.via.isEmpty {
                // Direct packet (no digipeaters in path)
                // This is endpoint traffic for DirectPeer detection
                if !isInfrastructure {
                    let directedKey = DirectedKey(source: from, target: to)
                    var agg = directionalEndpointTraffic[directedKey, default: DirectionalTrafficAggregate()]
                    agg.count += 1
                    agg.bytes += event.payloadBytes
                    agg.lastHeard = max(agg.lastHeard ?? .distantPast, event.timestamp)
                    directionalEndpointTraffic[directedKey] = agg
                }

                // Track as HeardDirect: 'to' heard 'from' directly (no via path)
                var toHeardDirect = heardDirectData[to, default: [:]]
                var fromAgg = toHeardDirect[from, default: HeardDirectAggregate()]
                fromAgg.count += 1
                fromAgg.lastHeard = max(fromAgg.lastHeard ?? .distantPast, event.timestamp)
                // Track distinct 5-minute buckets for scoring
                let bucket = Int(event.timestamp.timeIntervalSince1970 / 300)
                fromAgg.distinctBuckets.insert(bucket)
                toHeardDirect[from] = fromAgg
                heardDirectData[to] = toHeardDirect
            } else {
                // Packet with via path (digipeaters)
                // Convert via callsigns to identity keys
                let viaKeys = event.via.compactMap { rawVia -> String? in
                    guard CallsignValidator.isValidCallsign(rawVia) else { return nil }
                    return identityKey(for: rawVia)
                }

                // Track via members
                for (i, rawVia) in event.via.enumerated() where i < viaKeys.count {
                    identityMembers[viaKeys[i], default: []].insert(rawVia.uppercased())
                }

                // Track HeardVia: 'to' heard 'from' via digipeaters
                var toHeardVia = heardViaData[to, default: [:]]
                var fromAgg = toHeardVia[from, default: HeardViaAggregate()]
                fromAgg.count += 1
                fromAgg.lastHeard = max(fromAgg.lastHeard ?? .distantPast, event.timestamp)
                for digiKey in viaKeys {
                    fromAgg.viaDigipeaters[digiKey, default: 0] += 1
                }
                toHeardVia[from] = fromAgg
                heardViaData[to] = toHeardVia

                // Build edges through the via path for graph visualization (only if enabled)
                if options.includeViaDigipeaters {
                    let path = [from] + viaKeys + [to]
                    for i in 0..<(path.count - 1) {
                        let source = path[i]
                        let target = path[i + 1]

                        let key = UndirectedKey(lhs: source, rhs: target)
                        var agg = viaPathEdges[key, default: ClassifiedEdgeAggregate()]
                        agg.count += 1
                        agg.bytes += event.payloadBytes
                        agg.lastHeard = max(agg.lastHeard ?? .distantPast, event.timestamp)
                        agg.hasViaPath = true
                        viaPathEdges[key] = agg
                    }

                    // Also add digipeaters to nodeStats so they appear as nodes
                    for digiKey in viaKeys {
                        var digiStats = nodeStats[digiKey, default: NodeAggregate()]
                        digiStats.inCount += 1  // Count as "relayed through"
                        digiStats.outCount += 1
                        digiStats.inBytes += event.payloadBytes
                        digiStats.outBytes += event.payloadBytes
                        nodeStats[digiKey] = digiStats
                    }
                }
            }
        }

        // PHASE 2: Classify edges based on relationship type

        var classifiedEdges: [ClassifiedEdge] = []
        var directPeerKeys: Set<UndirectedKey> = []

        // DirectPeer edges: Require BIDIRECTIONAL endpoint traffic (A→B AND B→A)
        // Group directed keys into undirected pairs and check for bidirectionality
        var undirectedEndpointTraffic: [UndirectedKey: BidirectionalTrafficAggregate] = [:]
        for (directedKey, agg) in directionalEndpointTraffic {
            let undirectedKey = UndirectedKey(lhs: directedKey.source, rhs: directedKey.target)
            var biAgg = undirectedEndpointTraffic[undirectedKey, default: BidirectionalTrafficAggregate()]
            // Track traffic in each direction
            if directedKey.source == undirectedKey.source {
                // source → target direction
                biAgg.forwardCount += agg.count
                biAgg.forwardBytes += agg.bytes
            } else {
                // target → source direction
                biAgg.reverseCount += agg.count
                biAgg.reverseBytes += agg.bytes
            }
            biAgg.lastHeard = max(biAgg.lastHeard ?? .distantPast, agg.lastHeard ?? .distantPast)
            undirectedEndpointTraffic[undirectedKey] = biAgg
        }

        // Create DirectPeer edges only for BIDIRECTIONAL traffic
        for (key, biAgg) in undirectedEndpointTraffic {
            let totalCount = biAgg.forwardCount + biAgg.reverseCount
            guard totalCount >= options.minimumEdgeCount else { continue }

            // CRITICAL: DirectPeer requires traffic in BOTH directions
            let isBidirectional = biAgg.forwardCount >= 1 && biAgg.reverseCount >= 1

            if isBidirectional {
                directPeerKeys.insert(key)
                classifiedEdges.append(ClassifiedEdge(
                    sourceID: key.source,
                    targetID: key.target,
                    linkType: .directPeer,
                    weight: totalCount,
                    bytes: biAgg.forwardBytes + biAgg.reverseBytes,
                    lastHeard: biAgg.lastHeard,
                    viaDigipeaters: []
                ))
            }
        }

        // HeardDirect edges: One-way direct reception that meets scoring thresholds
        // Collapse directional HeardDirect data into undirected edges
        var heardDirectEdges: [UndirectedKey: HeardDirectEdgeAggregate] = [:]

        for (observer, senders) in heardDirectData {
            for (sender, agg) in senders {
                let key = UndirectedKey(lhs: observer, rhs: sender)

                // Skip if this pair is already a DirectPeer
                if directPeerKeys.contains(key) { continue }

                // Calculate HeardDirect score
                let age = now.timeIntervalSince(agg.lastHeard ?? now)
                let score = HeardDirectScoring.calculateScore(
                    directHeardCount: agg.count,
                    directHeardMinutes: agg.distinctBuckets.count,
                    lastDirectHeardAge: age
                )

                guard score >= HeardDirectScoring.minimumScore else { continue }

                var edgeAgg = heardDirectEdges[key, default: HeardDirectEdgeAggregate()]
                edgeAgg.count += agg.count
                edgeAgg.lastHeard = max(edgeAgg.lastHeard ?? .distantPast, agg.lastHeard ?? .distantPast)
                edgeAgg.score = max(edgeAgg.score, score)
                heardDirectEdges[key] = edgeAgg
            }
        }

        // Add HeardDirect edges to classified edges
        for (key, agg) in heardDirectEdges {
            guard agg.count >= options.minimumEdgeCount else { continue }
            classifiedEdges.append(ClassifiedEdge(
                sourceID: key.source,
                targetID: key.target,
                linkType: .heardDirect,
                weight: agg.count,
                bytes: 0, // HeardDirect doesn't track bytes (it's reception evidence, not endpoint traffic)
                lastHeard: agg.lastHeard,
                viaDigipeaters: []
            ))
        }

        // SeenVia (HeardVia) edges: Observed only through digipeaters
        // Only create if includeViaDigipeaters is enabled
        if options.includeViaDigipeaters {
            var seenViaEdges: [UndirectedKey: SeenViaEdgeAggregate] = [:]

            for (observer, senders) in heardViaData {
                for (sender, agg) in senders {
                    let key = UndirectedKey(lhs: observer, rhs: sender)

                    // Skip if this pair is a DirectPeer or HeardDirect
                    if directPeerKeys.contains(key) { continue }
                    if heardDirectEdges.keys.contains(key) { continue }

                    var edgeAgg = seenViaEdges[key, default: SeenViaEdgeAggregate()]
                    edgeAgg.count += agg.count
                    edgeAgg.lastHeard = max(edgeAgg.lastHeard ?? .distantPast, agg.lastHeard ?? .distantPast)
                    // Merge digipeater counts
                    for (digi, count) in agg.viaDigipeaters {
                        edgeAgg.viaDigipeaters[digi, default: 0] += count
                    }
                    seenViaEdges[key] = edgeAgg
                }
            }

            // Add SeenVia edges
            for (key, agg) in seenViaEdges {
                guard agg.count >= options.minimumEdgeCount else { continue }
                let topDigis = agg.viaDigipeaters
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { $0.key }

                classifiedEdges.append(ClassifiedEdge(
                    sourceID: key.source,
                    targetID: key.target,
                    linkType: .heardVia,
                    weight: agg.count,
                    bytes: 0,
                    lastHeard: agg.lastHeard,
                    viaDigipeaters: topDigis
                ))
            }

            // Add via path edges (digipeater link edges for routing visualization)
            for (key, agg) in viaPathEdges {
                guard agg.count >= options.minimumEdgeCount else { continue }
                // Skip if already covered by another edge type
                if directPeerKeys.contains(key) { continue }
                if heardDirectEdges.keys.contains(key) { continue }
                if seenViaEdges.keys.contains(key) { continue }

                classifiedEdges.append(ClassifiedEdge(
                    sourceID: key.source,
                    targetID: key.target,
                    linkType: .heardVia,
                    weight: agg.count,
                    bytes: agg.bytes,
                    lastHeard: agg.lastHeard,
                    viaDigipeaters: []
                ))
            }
        }

        // PHASE 3: Build station relationships for adjacency (inspector display)
        var relationships: [String: [StationRelationship]] = [:]

        // Add DirectPeer relationships
        for edge in classifiedEdges where edge.linkType == .directPeer {
            for (nodeID, peerID) in [(edge.sourceID, edge.targetID), (edge.targetID, edge.sourceID)] {
                var nodeRels = relationships[nodeID, default: []]
                if !nodeRels.contains(where: { $0.id == peerID && $0.linkType == .directPeer }) {
                    nodeRels.append(StationRelationship(
                        id: peerID,
                        linkType: .directPeer,
                        packetCount: edge.weight,
                        lastHeard: edge.lastHeard,
                        viaDigipeaters: [],
                        score: 1.0
                    ))
                }
                relationships[nodeID] = nodeRels
            }
        }

        // Add HeardDirect relationships (with score)
        for (observer, senders) in heardDirectData {
            var observerRels = relationships[observer, default: []]
            for (sender, agg) in senders {
                // Skip if already a DirectPeer
                let key = UndirectedKey(lhs: observer, rhs: sender)
                if directPeerKeys.contains(key) { continue }

                let age = now.timeIntervalSince(agg.lastHeard ?? now)
                let score = HeardDirectScoring.calculateScore(
                    directHeardCount: agg.count,
                    directHeardMinutes: agg.distinctBuckets.count,
                    lastDirectHeardAge: age
                )

                guard score >= HeardDirectScoring.minimumScore else { continue }

                if !observerRels.contains(where: { $0.id == sender && $0.linkType == .heardDirect }) {
                    observerRels.append(StationRelationship(
                        id: sender,
                        linkType: .heardDirect,
                        packetCount: agg.count,
                        lastHeard: agg.lastHeard,
                        viaDigipeaters: [],
                        score: score
                    ))
                }
            }
            relationships[observer] = observerRels
        }

        // Add HeardVia relationships (with digipeater info)
        for (observer, senders) in heardViaData {
            var observerRels = relationships[observer, default: []]
            for (sender, agg) in senders {
                let key = UndirectedKey(lhs: observer, rhs: sender)

                // Skip if already a DirectPeer or HeardDirect
                if directPeerKeys.contains(key) { continue }
                if observerRels.contains(where: { $0.id == sender && $0.linkType == .heardDirect }) {
                    continue
                }

                let topDigis = agg.viaDigipeaters
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { $0.key }

                observerRels.append(StationRelationship(
                    id: sender,
                    linkType: .heardVia,
                    packetCount: agg.count,
                    lastHeard: agg.lastHeard,
                    viaDigipeaters: topDigis,
                    score: 0
                ))
            }
            relationships[observer] = observerRels
        }

        // PHASE 4: Build nodes from all stations heard in the timeframe (not just from edges)
        // CRITICAL FIX: Previously, nodes were built only from edges, which caused stations
        // to disappear when includeViaDigipeaters was OFF (because heardVia edges weren't created).
        // Now we build nodes from nodeStats, which tracks ALL stations seen in packets.
        // This ensures the local station and all heard stations are always present,
        // regardless of whether they have qualifying edges.
        let activeNodeIDs = Set(nodeStats.keys)
        var nodes: [NetworkGraphNode] = []
        nodes.reserveCapacity(activeNodeIDs.count)

        for id in activeNodeIDs {
            let stats = nodeStats[id] ?? NodeAggregate()
            let nodeRels = relationships[id] ?? []
            let members = identityMembers[id] ?? [id]
            let groupedSSIDs = Array(members).sorted()
            let node = NetworkGraphNode(
                id: id,
                callsign: id,
                weight: stats.inCount + stats.outCount,
                inCount: stats.inCount,
                outCount: stats.outCount,
                inBytes: stats.inBytes,
                outBytes: stats.outBytes,
                degree: nodeRels.filter { $0.linkType == .directPeer }.count,
                groupedSSIDs: groupedSSIDs
            )
            nodes.append(node)
        }

        // Sort by weight descending
        nodes.sort { lhs, rhs in
            if lhs.weight != rhs.weight {
                return lhs.weight > rhs.weight
            }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }

        // Cap nodes
        let maxNodes = max(1, options.maxNodes)
        let keptNodes = Array(nodes.prefix(maxNodes))
        let keptIDs = Set(keptNodes.map { $0.id })
        let droppedCount = max(0, nodes.count - keptNodes.count)

        // Filter edges and relationships to kept nodes
        let filteredEdges = classifiedEdges
            .filter { keptIDs.contains($0.sourceID) && keptIDs.contains($0.targetID) }
            .sorted { lhs, rhs in
                // Sort by link type priority, then by weight
                if lhs.linkType.renderPriority != rhs.linkType.renderPriority {
                    return lhs.linkType.renderPriority < rhs.linkType.renderPriority
                }
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.sourceID < rhs.sourceID
            }

        let filteredRelationships = relationships.reduce(into: [String: [StationRelationship]]()) { result, entry in
            let (id, rels) = entry
            guard keptIDs.contains(id) else { return }
            let keptRels = rels
                .filter { keptIDs.contains($0.id) }
                .sorted { lhs, rhs in
                    // Sort by link type priority, then by packet count
                    if lhs.linkType.renderPriority != rhs.linkType.renderPriority {
                        return lhs.linkType.renderPriority < rhs.linkType.renderPriority
                    }
                    return lhs.packetCount > rhs.packetCount
                }
            result[id] = keptRels
        }

        // Update node degrees based on filtered relationships
        let finalNodes = keptNodes.map { node in
            let rels = filteredRelationships[node.id] ?? []
            let directPeerCount = rels.filter { $0.linkType == .directPeer }.count
            return NetworkGraphNode(
                id: node.id,
                callsign: node.callsign,
                weight: node.weight,
                inCount: node.inCount,
                outCount: node.outCount,
                inBytes: node.inBytes,
                outBytes: node.outBytes,
                degree: directPeerCount,
                groupedSSIDs: node.groupedSSIDs
            )
        }

        return ClassifiedGraphModel(
            nodes: finalNodes,
            edges: filteredEdges,
            adjacency: filteredRelationships,
            droppedNodesCount: droppedCount
        )
    }

    static func build(events: [PacketEvent], options: Options) -> GraphModel {
        guard !events.isEmpty else { return .empty }

        let identityMode = options.stationIdentityMode

        // Helper: get identity key for a callsign based on mode
        func identityKey(for callsign: String) -> String {
            CallsignParser.identityKey(for: callsign, mode: identityMode)
        }

        var directedEdges: [DirectedKey: EdgeAggregate] = [:]
        var nodeStats: [String: NodeAggregate] = [:]
        // Track which raw SSIDs belong to each identity key (for display)
        var identityMembers: [String: Set<String>] = [:]

        for event in events {
            guard let rawFrom = event.from, let rawTo = event.to else { continue }

            // Convert callsigns to identity keys
            let from = identityKey(for: rawFrom)
            let to = identityKey(for: rawTo)

            // Track members
            identityMembers[from, default: []].insert(rawFrom.uppercased())
            identityMembers[to, default: []].insert(rawTo.uppercased())

            let path: [String]
            if options.includeViaDigipeaters {
                // Also convert via callsigns to identity keys
                let viaKeys = event.via.map { identityKey(for: $0) }
                // Track via members
                for (i, rawVia) in event.via.enumerated() {
                    identityMembers[viaKeys[i], default: []].insert(rawVia.uppercased())
                }
                path = [from] + viaKeys + [to]
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

        // Filter edges to only include valid amateur radio callsigns
        // This excludes non-callsign entities like BEACON, ID, WIDE1-1, etc.
        // Note: We check the identity key (which is the base callsign in station mode)
        let edgesExcludingSpecial = filteredEdges.filter { key, _ in
            CallsignValidator.isValidCallsign(key.source) &&
            CallsignValidator.isValidCallsign(key.target)
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

        // Build nodes from all stations heard in the timeframe (not just from edges)
        // This ensures stations are present even when filters remove all their edges.
        let activeNodeIDs = Set(nodeStats.keys).filter { CallsignValidator.isValidCallsign($0) }
        var nodes: [NetworkGraphNode] = []
        nodes.reserveCapacity(activeNodeIDs.count)

        for id in activeNodeIDs {
            let stats = nodeStats[id] ?? NodeAggregate()
            let neighbors = adjacency[id] ?? []
            let totalWeight = stats.inCount + stats.outCount
            // Get display callsign - in station mode, use base; in ssid mode, use full
            let displayCallsign = id
            // Get grouped SSIDs for this node
            let members = identityMembers[id] ?? [id]
            let groupedSSIDs = Array(members).sorted()
            let node = NetworkGraphNode(
                id: id,
                callsign: displayCallsign,
                weight: totalWeight,
                inCount: stats.inCount,
                outCount: stats.outCount,
                inBytes: stats.inBytes,
                outBytes: stats.outBytes,
                degree: neighbors.count,
                groupedSSIDs: groupedSSIDs
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
                degree: neighbors.count,
                groupedSSIDs: node.groupedSSIDs
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

// MARK: - Classified Graph Aggregates

private struct ClassifiedEdgeAggregate {
    var count: Int = 0
    var bytes: Int = 0
    var lastHeard: Date?
    var hasViaPath: Bool = false
}

private struct HeardDirectAggregate {
    var count: Int = 0
    var lastHeard: Date?
    var distinctBuckets: Set<Int> = []
}

private struct HeardViaAggregate {
    var count: Int = 0
    var lastHeard: Date?
    var viaDigipeaters: [String: Int] = [:]
}

// MARK: - Bidirectional Traffic Tracking (for DirectPeer detection)

private struct DirectionalTrafficAggregate {
    var count: Int = 0
    var bytes: Int = 0
    var lastHeard: Date?
}

private struct BidirectionalTrafficAggregate {
    var forwardCount: Int = 0
    var forwardBytes: Int = 0
    var reverseCount: Int = 0
    var reverseBytes: Int = 0
    var lastHeard: Date?
}

// MARK: - Edge Aggregates for Classified Graph

private struct HeardDirectEdgeAggregate {
    var count: Int = 0
    var lastHeard: Date?
    var score: Double = 0
}

private struct SeenViaEdgeAggregate {
    var count: Int = 0
    var lastHeard: Date?
    var viaDigipeaters: [String: Int] = [:]
}
