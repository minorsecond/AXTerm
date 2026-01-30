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

    // MARK: - Classified Graph Building (Evidence Model)

    /// Build a classified graph with edges categorized by relationship type.
    ///
    /// Evidence tiers:
    /// - **DirectPeer**: bidirectional endpoint traffic, no digipeaters (A→B and B→A)
    /// - **HeardMutual**: mutual direct RF decode evidence (both directions observed directly)
    /// - **HeardDirect**: one-way direct RF decode evidence
    /// - **HeardVia**: observed via digipeaters (always computed; not gated by includeViaDigipeaters)
    ///
    /// IMPORTANT:
    /// - `includeViaDigipeaters` controls *expanding* via paths into hop-by-hop edges and promoting digi nodes,
    ///   not whether HeardVia relationships exist.
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

        // PHASE 1: Collect evidence aggregates

        // DirectPeer (bidirectional endpoint traffic, no via, not infra)
        var directionalEndpointTraffic: [DirectedKey: DirectionalTrafficAggregate] = [:]

        // HeardDirect (directional RF decode evidence, no via)
        // observer -> sender -> data
        var heardDirectData: [String: [String: HeardDirectAggregate]] = [:]

        // HeardVia (directional via-mediated observation)
        // observer -> sender -> data
        var heardViaData: [String: [String: HeardViaAggregate]] = [:]

        // Optional hop-by-hop via path edges (only when includeViaDigipeaters is enabled)
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

            // Infrastructure traffic (excluded from DirectPeer)
            let isInfrastructure = event.frameType == .ui && (
                rawTo.uppercased() == "ID" ||
                rawTo.uppercased() == "BEACON" ||
                rawTo.uppercased().hasPrefix("BBS")
            )

            // Update node stats (all stations seen in packets)
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

                // Endpoint traffic evidence for DirectPeer (exclude infra)
                if !isInfrastructure {
                    let directedKey = DirectedKey(source: from, target: to)
                    var agg = directionalEndpointTraffic[directedKey, default: DirectionalTrafficAggregate()]
                    agg.count += 1
                    agg.bytes += event.payloadBytes
                    agg.lastHeard = max(agg.lastHeard ?? .distantPast, event.timestamp)
                    directionalEndpointTraffic[directedKey] = agg
                }

                // HeardDirect: 'to' heard 'from' directly (directional RF decode evidence)
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

                // HeardVia: 'to' observed 'from' via digipeaters (always tracked)
                var toHeardVia = heardViaData[to, default: [:]]
                var fromAgg = toHeardVia[from, default: HeardViaAggregate()]
                fromAgg.count += 1
                fromAgg.lastHeard = max(fromAgg.lastHeard ?? .distantPast, event.timestamp)
                for digiKey in viaKeys {
                    fromAgg.viaDigipeaters[digiKey, default: 0] += 1
                }
                toHeardVia[from] = fromAgg
                heardViaData[to] = toHeardVia

                // CRITICAL: includeViaDigipeaters only controls expanding hop-by-hop path edges
                // and whether digipeaters become nodes. It does NOT gate HeardVia relationships.
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

                    // Promote digipeaters into nodeStats so they appear as nodes
                    for digiKey in viaKeys {
                        var digiStats = nodeStats[digiKey, default: NodeAggregate()]
                        digiStats.inCount += 1
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
        classifiedEdges.reserveCapacity(256)

        // DirectPeer keys
        var directPeerKeys: Set<UndirectedKey> = []

        // 2A) DirectPeer edges (bidirectional endpoint traffic, no via)
        var undirectedEndpointTraffic: [UndirectedKey: BidirectionalTrafficAggregate] = [:]
        for (directedKey, agg) in directionalEndpointTraffic {
            let undirectedKey = UndirectedKey(lhs: directedKey.source, rhs: directedKey.target)
            var biAgg = undirectedEndpointTraffic[undirectedKey, default: BidirectionalTrafficAggregate()]

            // Track traffic in each direction
            if directedKey.source == undirectedKey.source {
                biAgg.forwardCount += agg.count
                biAgg.forwardBytes += agg.bytes
            } else {
                biAgg.reverseCount += agg.count
                biAgg.reverseBytes += agg.bytes
            }
            biAgg.lastHeard = max(biAgg.lastHeard ?? .distantPast, agg.lastHeard ?? .distantPast)
            undirectedEndpointTraffic[undirectedKey] = biAgg
        }

        for (key, biAgg) in undirectedEndpointTraffic {
            let totalCount = biAgg.forwardCount + biAgg.reverseCount
            guard totalCount >= options.minimumEdgeCount else { continue }

            // DirectPeer requires both directions present
            let isBidirectional = biAgg.forwardCount >= 1 && biAgg.reverseCount >= 1
            if isBidirectional {
                directPeerKeys.insert(key)
                classifiedEdges.append(
                    ClassifiedEdge(
                        sourceID: key.source,
                        targetID: key.target,
                        linkType: .directPeer,
                        weight: totalCount,
                        bytes: biAgg.forwardBytes + biAgg.reverseBytes,
                        lastHeard: biAgg.lastHeard,
                        viaDigipeaters: []
                    )
                )
            }
        }

        // 2B) HeardDirect / HeardMutual edges from directional direct-RF evidence
        //
        // We compute directional HeardDirect scores, then promote to HeardMutual when BOTH directions
        // meet minimum evidence.
        //
        // IMPORTANT UX:
        // - We still show weak one-way HeardDirect (e.g., count >= 1) so “I can hear them” is visible.
        // - Stronger confidence can be conveyed via styling elsewhere (e.g. weight/alpha).
        //
        // Implementation:
        // - Compute per-direction score using the existing scoring function (0 if not eligible).
        // - For “mutual,” we require BOTH directions to have at least minimal evidence:
        //   count >= 2 OR distinctBuckets >= 2 (each direction).
        //
        // - For “one-way,” we include any direction with count >= 1 (but avoid duplicating if mutual edge exists).
        //
        // Note: We intentionally do NOT apply options.minimumEdgeCount to HeardDirect evidence. That slider
        // is for “relationship strength” in traffic terms; RF decode evidence needs a “show me it exists” baseline.
        struct DirectEvidence {
            let count: Int
            let buckets: Int
            let lastHeard: Date?
            let score: Double
        }

        func evidence(from agg: HeardDirectAggregate) -> DirectEvidence {
            let age = now.timeIntervalSince(agg.lastHeard ?? now)
            let score = HeardDirectScoring.calculateScore(
                directHeardCount: agg.count,
                directHeardMinutes: agg.distinctBuckets.count,
                lastDirectHeardAge: age
            )
            return DirectEvidence(
                count: agg.count,
                buckets: agg.distinctBuckets.count,
                lastHeard: agg.lastHeard,
                score: score
            )
        }

        // Flatten directional evidence: observer -> sender -> evidence
        var directEvidence: [DirectedKey: DirectEvidence] = [:]
        directEvidence.reserveCapacity(heardDirectData.count * 4)

        for (observer, senders) in heardDirectData {
            for (sender, agg) in senders {
                let dKey = DirectedKey(source: observer, target: sender) // observer heard sender
                directEvidence[dKey] = evidence(from: agg)
            }
        }

        // Compute mutual edges (undirected)
        var heardMutualKeys: Set<UndirectedKey> = []
        for (dKey, ev) in directEvidence {
            // Skip trivial entries
            guard ev.count >= 1 else { continue }

            // Pair key
            let reverseKey = DirectedKey(source: dKey.target, target: dKey.source)
            guard let rev = directEvidence[reverseKey] else { continue }

            // Must have minimal evidence on both directions
            let evOk = (ev.count >= 2) || (ev.buckets >= 2)
            let revOk = (rev.count >= 2) || (rev.buckets >= 2)
            guard evOk && revOk else { continue }

            let uKey = UndirectedKey(lhs: dKey.source, rhs: dKey.target)

            // Do not create if already DirectPeer (DirectPeer is a different concept, but stronger traffic proof)
            // We still allow HeardMutual even if DirectPeer exists, but it’s redundant in connectivity.
            // To keep the edge set clean, skip if DirectPeer exists.
            if directPeerKeys.contains(uKey) { continue }

            if heardMutualKeys.insert(uKey).inserted {
                let combinedCount = ev.count + rev.count
                let last = max(ev.lastHeard ?? .distantPast, rev.lastHeard ?? .distantPast)
                classifiedEdges.append(
                    ClassifiedEdge(
                        sourceID: uKey.source,
                        targetID: uKey.target,
                        linkType: .heardMutual,
                        weight: combinedCount,
                        bytes: 0,
                        lastHeard: last == .distantPast ? nil : last,
                        viaDigipeaters: []
                    )
                )
            }
        }

        // One-way HeardDirect edges (undirected display edge, but evidence is directional)
        // We collapse to an undirected edge for rendering simplicity, while inspector remains directional via adjacency.
        var heardDirectEdges: [UndirectedKey: HeardDirectEdgeAggregate] = [:]

        for (observer, senders) in heardDirectData {
            for (sender, agg) in senders {
                let uKey = UndirectedKey(lhs: observer, rhs: sender)

                // Skip if already DirectPeer or HeardMutual
                if directPeerKeys.contains(uKey) { continue }
                if heardMutualKeys.contains(uKey) { continue }

                // Show *any* direct decode evidence (count >= 1)
                guard agg.count >= 1 else { continue }

                let age = now.timeIntervalSince(agg.lastHeard ?? now)
                let score = HeardDirectScoring.calculateScore(
                    directHeardCount: agg.count,
                    directHeardMinutes: agg.distinctBuckets.count,
                    lastDirectHeardAge: age
                )

                var edgeAgg = heardDirectEdges[uKey, default: HeardDirectEdgeAggregate()]
                edgeAgg.count += agg.count
                edgeAgg.lastHeard = max(edgeAgg.lastHeard ?? .distantPast, agg.lastHeard ?? .distantPast)
                edgeAgg.score = max(edgeAgg.score, score)
                heardDirectEdges[uKey] = edgeAgg
            }
        }

        for (key, agg) in heardDirectEdges {
            classifiedEdges.append(
                ClassifiedEdge(
                    sourceID: key.source,
                    targetID: key.target,
                    linkType: .heardDirect,
                    weight: agg.count,
                    bytes: 0,
                    lastHeard: agg.lastHeard == .distantPast ? nil : agg.lastHeard,
                    viaDigipeaters: []
                )
            )
        }

        // 2C) HeardVia summary edges (ALWAYS computed, NOT gated by includeViaDigipeaters)
        //
        // This is the big semantic fix: even with “include digipeaters” OFF, users should still see
        // “Observed via digipeaters” relationships between endpoints.
        var heardViaEdges: [UndirectedKey: SeenViaEdgeAggregate] = [:]

        for (observer, senders) in heardViaData {
            for (sender, agg) in senders {
                let key = UndirectedKey(lhs: observer, rhs: sender)

                // Skip if already direct peer or heard mutual or heard direct
                if directPeerKeys.contains(key) { continue }
                if heardMutualKeys.contains(key) { continue }
                if heardDirectEdges.keys.contains(key) { continue }

                var edgeAgg = heardViaEdges[key, default: SeenViaEdgeAggregate()]
                edgeAgg.count += agg.count
                edgeAgg.lastHeard = max(edgeAgg.lastHeard ?? .distantPast, agg.lastHeard ?? .distantPast)
                for (digi, count) in agg.viaDigipeaters {
                    edgeAgg.viaDigipeaters[digi, default: 0] += count
                }
                heardViaEdges[key] = edgeAgg
            }
        }

        for (key, agg) in heardViaEdges {
            // Keep it visible even at low counts; apply minimumEdgeCount if you really want,
            // but default behavior should show evidence exists.
            // If you want a compromise, uncomment the next line:
            // guard agg.count >= max(1, options.minimumEdgeCount) else { continue }

            let topDigis = agg.viaDigipeaters
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { $0.key }

            classifiedEdges.append(
                ClassifiedEdge(
                    sourceID: key.source,
                    targetID: key.target,
                    linkType: .heardVia,
                    weight: agg.count,
                    bytes: 0,
                    lastHeard: agg.lastHeard == .distantPast ? nil : agg.lastHeard,
                    viaDigipeaters: topDigis
                )
            )
        }

        // 2D) Optional hop-by-hop via path edges (ONLY when includeViaDigipeaters is enabled)
        if options.includeViaDigipeaters {
            for (key, agg) in viaPathEdges {
                // Apply minimumEdgeCount for path edges to reduce noise
                guard agg.count >= max(1, options.minimumEdgeCount) else { continue }

                // Skip if already covered by another edge type
                if directPeerKeys.contains(key) { continue }
                if heardMutualKeys.contains(key) { continue }
                if heardDirectEdges.keys.contains(key) { continue }
                if heardViaEdges.keys.contains(key) { continue }

                classifiedEdges.append(
                    ClassifiedEdge(
                        sourceID: key.source,
                        targetID: key.target,
                        linkType: .heardVia,
                        weight: agg.count,
                        bytes: agg.bytes,
                        lastHeard: agg.lastHeard,
                        viaDigipeaters: []
                    )
                )
            }
        }

        // PHASE 3: Build station relationships for adjacency (inspector display)
        //
        // NOTE: adjacency remains directional where it matters (observer→sender), but the main
        // rendered edge list is undirected for readability.

        var relationships: [String: [StationRelationship]] = [:]

        // DirectPeer relationships
        for edge in classifiedEdges where edge.linkType == .directPeer {
            for (nodeID, peerID) in [(edge.sourceID, edge.targetID), (edge.targetID, edge.sourceID)] {
                var nodeRels = relationships[nodeID, default: []]
                if !nodeRels.contains(where: { $0.id == peerID && $0.linkType == .directPeer }) {
                    nodeRels.append(
                        StationRelationship(
                            id: peerID,
                            linkType: .directPeer,
                            packetCount: edge.weight,
                            lastHeard: edge.lastHeard,
                            viaDigipeaters: [],
                            score: 1.0
                        )
                    )
                }
                relationships[nodeID] = nodeRels
            }
        }

        // HeardMutual relationships (symmetric)
        for edge in classifiedEdges where edge.linkType == .heardMutual {
            for (nodeID, peerID) in [(edge.sourceID, edge.targetID), (edge.targetID, edge.sourceID)] {
                var nodeRels = relationships[nodeID, default: []]
                if !nodeRels.contains(where: { $0.id == peerID && $0.linkType == .heardMutual }) {
                    nodeRels.append(
                        StationRelationship(
                            id: peerID,
                            linkType: .heardMutual,
                            packetCount: edge.weight,
                            lastHeard: edge.lastHeard,
                            viaDigipeaters: [],
                            score: 1.0
                        )
                    )
                }
                relationships[nodeID] = nodeRels
            }
        }

        // HeardDirect relationships (directional observer->sender) with score
        for (observer, senders) in heardDirectData {
            var observerRels = relationships[observer, default: []]
            for (sender, agg) in senders {
                let uKey = UndirectedKey(lhs: observer, rhs: sender)

                // Skip if already DirectPeer or HeardMutual (keep the inspector clean)
                if directPeerKeys.contains(uKey) { continue }
                if heardMutualKeys.contains(uKey) { continue }

                let age = now.timeIntervalSince(agg.lastHeard ?? now)
                let score = HeardDirectScoring.calculateScore(
                    directHeardCount: agg.count,
                    directHeardMinutes: agg.distinctBuckets.count,
                    lastDirectHeardAge: age
                )

                // Show even weak evidence (count>=1); score may be 0.
                guard agg.count >= 1 else { continue }

                if !observerRels.contains(where: { $0.id == sender && $0.linkType == .heardDirect }) {
                    observerRels.append(
                        StationRelationship(
                            id: sender,
                            linkType: .heardDirect,
                            packetCount: agg.count,
                            lastHeard: agg.lastHeard,
                            viaDigipeaters: [],
                            score: score
                        )
                    )
                }
            }
            relationships[observer] = observerRels
        }

        // HeardVia relationships (directional observer->sender) with digipeater info
        for (observer, senders) in heardViaData {
            var observerRels = relationships[observer, default: []]
            for (sender, agg) in senders {
                let uKey = UndirectedKey(lhs: observer, rhs: sender)

                // Skip if already DirectPeer / HeardMutual / HeardDirect
                if directPeerKeys.contains(uKey) { continue }
                if heardMutualKeys.contains(uKey) { continue }
                if observerRels.contains(where: { $0.id == sender && $0.linkType == .heardDirect }) { continue }

                let topDigis = agg.viaDigipeaters
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { $0.key }

                observerRels.append(
                    StationRelationship(
                        id: sender,
                        linkType: .heardVia,
                        packetCount: agg.count,
                        lastHeard: agg.lastHeard,
                        viaDigipeaters: topDigis,
                        score: 0
                    )
                )
            }
            relationships[observer] = observerRels
        }

        // PHASE 4: Build nodes from ALL stations seen in packets (nodeStats)
        let activeNodeIDs = Set(nodeStats.keys)
        var nodes: [NetworkGraphNode] = []
        nodes.reserveCapacity(activeNodeIDs.count)

        for id in activeNodeIDs {
            let stats = nodeStats[id] ?? NodeAggregate()
            let nodeRels = relationships[id] ?? []
            let members = identityMembers[id] ?? [id]
            let groupedSSIDs = Array(members).sorted()

            // Degree in the node model is used for sizing/center selection.
            // For “connectivity,” degree should reflect meaningful connectivity; we’ll count:
            // - directPeer + heardMutual as “strong”
            // (heardDirect one-way is intentionally excluded from degree to avoid inflating hubs)
            let strongDegree = nodeRels.filter { rel in
                rel.linkType == .directPeer || rel.linkType == .heardMutual
            }.count

            let node = NetworkGraphNode(
                id: id,
                callsign: id,
                weight: stats.inCount + stats.outCount,
                inCount: stats.inCount,
                outCount: stats.outCount,
                inBytes: stats.inBytes,
                outBytes: stats.outBytes,
                degree: strongDegree,
                groupedSSIDs: groupedSSIDs
            )
            nodes.append(node)
        }

        // Sort by weight descending
        nodes.sort { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
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
            let strongDegree = rels.filter { $0.linkType == .directPeer || $0.linkType == .heardMutual }.count
            return NetworkGraphNode(
                id: node.id,
                callsign: node.callsign,
                weight: node.weight,
                inCount: node.inCount,
                outCount: node.outCount,
                inBytes: node.inBytes,
                outBytes: node.outBytes,
                degree: strongDegree,
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

    // MARK: - Legacy Graph (unchanged)

    static func build(events: [PacketEvent], options: Options) -> GraphModel {
        guard !events.isEmpty else { return .empty }

        let identityMode = options.stationIdentityMode

        func identityKey(for callsign: String) -> String {
            CallsignParser.identityKey(for: callsign, mode: identityMode)
        }

        var directedEdges: [DirectedKey: EdgeAggregate] = [:]
        var nodeStats: [String: NodeAggregate] = [:]
        var identityMembers: [String: Set<String>] = [:]

        for event in events {
            guard let rawFrom = event.from, let rawTo = event.to else { continue }

            let from = identityKey(for: rawFrom)
            let to = identityKey(for: rawTo)

            identityMembers[from, default: []].insert(rawFrom.uppercased())
            identityMembers[to, default: []].insert(rawTo.uppercased())

            let path: [String]
            if options.includeViaDigipeaters {
                let viaKeys = event.via.map { identityKey(for: $0) }
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

        let activeNodeIDs = Set(edgesExcludingSpecial.keys.flatMap { [$0.source, $0.target] })
            .filter { CallsignValidator.isValidCallsign($0) }
        var nodes: [NetworkGraphNode] = []
        nodes.reserveCapacity(activeNodeIDs.count)

        for id in activeNodeIDs {
            let stats = nodeStats[id] ?? NodeAggregate()
            let neighbors = adjacency[id] ?? []
            let totalWeight = stats.inCount + stats.outCount
            let displayCallsign = id
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
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
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
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                return lhs.sourceID < rhs.sourceID
            }

        let prunedAdjacency = adjacency.reduce(into: [String: [GraphNeighborStat]]()) { result, entry in
            let (id, neighbors) = entry
            guard keptIDs.contains(id) else { return }
            let keptNeighbors = neighbors.filter { keptIDs.contains($0.id) }
            result[id] = keptNeighbors.sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
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

// MARK: - Keys and Aggregates

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
