//
//  NetRomPassiveInference.swift
//  AXTerm
//
//  Created by Codex on 1/30/26.
//

import Foundation

/// Passive NET/ROM inference uses overheard packets to seed neighbor quality and
/// inferred routes without relying on explicit routing broadcasts.
@MainActor
final class NetRomPassiveInference {
    let config: NetRomInferenceConfig
    #if DEBUG
    private static var retainedForTests: [NetRomPassiveInference] = []
    #endif

    private let router: NetRomRouter
    private let localCallsign: String
    private var evidenceByDestination: [String: [NetRomRouteEvidence]] = [:]

    init(router: NetRomRouter, localCallsign: String, config: NetRomInferenceConfig = .default) {
        self.router = router
        self.localCallsign = CallsignValidator.normalize(localCallsign)
        self.config = config
        #if DEBUG
        Self.retainedForTests.append(self)
        #endif
    }

    #if DEBUG
    private static var hasLoggedObserve = false
    private static var inferenceCount = 0
    #endif

    func observePacket(_ packet: Packet, timestamp: Date, classification: PacketClassification, duplicateStatus: PacketDuplicateStatus) {
        guard let rawFrom = packet.from?.display,
              let normalizedFrom = normalize(rawFrom),
              let rawTo = packet.to?.display,
              let normalizedTo = normalize(rawTo)
        else {
            return
        }

        // Skip infrastructure packets (beacons, ID)
        guard !isInfrastructure(packet) else { return }

        #if DEBUG
        if !Self.hasLoggedObserve {
            print("[NETROM:INFERENCE] First packet observed:")
            print("[NETROM:INFERENCE]   from=\(normalizedFrom) to=\(normalizedTo) via=\(packet.via.map { $0.display })")
            print("[NETROM:INFERENCE]   localCallsign=\(localCallsign)")
            Self.hasLoggedObserve = true
        }
        #endif

        let isRetry = duplicateStatus == .retryDuplicate || classification == .retryOrDuplicate

        // Case 1: Direct packet addressed to us (no via path)
        if packet.via.isEmpty && normalizedTo == localCallsign {
            guard classification.refreshesNeighbor else { return }
            router.observePacketInferred(
                makeSyntheticPacket(call: normalizedFrom, timestamp: timestamp),
                observedQuality: config.inferredBaseQuality,
                direction: .incoming,
                timestamp: timestamp
            )
            return
        }

        // Case 2: Digipeated packet (has via path)
        // This includes both packets addressed to us AND third-party traffic
        guard !packet.via.isEmpty else { return }

        let viaNormalized = packet.via.compactMap { normalize($0.display) }
        // Prefer the actual repeated chain (H-bit set) when present; this reflects
        // the path that truly delivered the frame to us.
        let repeatedViaNormalized = packet.via
            .filter(\.repeated)
            .compactMap { normalize($0.display) }
        // Inference should represent routes that actually carried traffic. If no
        // repeated hops were observed, treat this as ambiguous and skip inference.
        guard !repeatedViaNormalized.isEmpty else { return }
        let heardViaNormalized = repeatedViaNormalized
        guard let nextHop = heardViaNormalized.last else { return }

        // Guardrails: prevent loops and invalid routes
        // 1. Never infer if local callsign is in via path (avoid learning through ourselves)
        guard !heardViaNormalized.contains(localCallsign) else { return }
        // 2. Never infer route to self
        guard normalizedFrom != localCallsign else { return }
        // 3. Never infer if nextHop equals destination (degenerate case)
        guard nextHop != normalizedFrom else { return }
        // 4. Never infer if nextHop is local callsign
        guard nextHop != localCallsign else { return }

        #if DEBUG
        Self.inferenceCount += 1
        if Self.inferenceCount <= 5 {
            print("[NETROM:INFERENCE] inferred route dest=\(normalizedFrom) via=\(nextHop) reason=digipeated-third-party")
        }
        #endif

        let weight = config.weight(for: classification)
        let canInfer = weight > 0 && classification != .ackOnly
        if !canInfer {
            if classification == .retryOrDuplicate {
                recordEvidence(destination: normalizedFrom, origin: nextHop, path: [nextHop, normalizedFrom], timestamp: timestamp, classification: classification, isRetry: true)
            }
            return
        }

        // Create inferred neighbor from the digipeater
        simulateNeighborObservationInferred(nextHop: nextHop, timestamp: timestamp)

        // Record route evidence using the path that actually repeated to us.
        // The path we follow to reach the destination is reverse(heardVia) + source.
        // Example: heard VIA W0TX, W0ARP (repeated) => connect path [W0ARP, W0TX, SRC].
        let fullPath = heardViaNormalized.reversed() + [normalizedFrom]
        recordEvidence(destination: normalizedFrom, origin: nextHop, path: fullPath, timestamp: timestamp, classification: classification, isRetry: isRetry)
    }

    func purgeStaleEvidence(currentDate: Date) {
        let tombstoneWindow = config.inferredRouteHalfLifeSeconds * config.tombstoneWindowMultiplier
        var refreshedEvidence: [String: [NetRomRouteEvidence]] = [:]

        for (destination, bucket) in evidenceByDestination {
            var kept: [NetRomRouteEvidence] = []
            for var evidence in bucket {
                let age = currentDate.timeIntervalSince(evidence.lastObserved)

                if age < config.inferredRouteHalfLifeSeconds {
                    // Still live — clear any tombstone
                    evidence.tombstonedAt = nil
                    kept.append(evidence)
                } else if evidence.tombstonedAt == nil {
                    // Phase 1: Enter tombstone state
                    evidence.tombstonedAt = currentDate
                    kept.append(evidence)
                } else {
                    // Phase 2: Check if tombstone window has elapsed
                    let tombstoneAge = currentDate.timeIntervalSince(evidence.tombstonedAt!)
                    if tombstoneAge < tombstoneWindow {
                        kept.append(evidence)
                    }
                    // else: fully expired, drop it
                }
            }
            if !kept.isEmpty {
                refreshedEvidence[destination] = kept
            }
        }

        evidenceByDestination = refreshedEvidence
    }

    // MARK: - Helpers

    private func recordEvidence(destination: String, origin: String, path: [String], timestamp: Date, classification: PacketClassification, isRetry: Bool) {
        var bucket = evidenceByDestination[destination] ?? []

        if let index = bucket.firstIndex(where: { $0.origin == origin }) {
            bucket[index].path = path
            bucket[index].refresh(timestamp: timestamp, classification: classification, config: config, isRetry: isRetry)
        } else {
            if isRetry {
                return
            }
            let initialScore = config.weight(for: classification)
            bucket.append(NetRomRouteEvidence(destination: destination, origin: origin, path: path, lastObserved: timestamp, reinforcementScore: initialScore))
        }

        bucket.sort { $0.advertisedQuality(using: config) > $1.advertisedQuality(using: config) }
        if bucket.count > config.maxInferredRoutesPerDestination {
            bucket = Array(bucket.prefix(config.maxInferredRoutesPerDestination))
        }
        evidenceByDestination[destination] = bucket

        publishEvidence(bucket, destination: destination, timestamp: timestamp)
    }

    private func publishEvidence(_ bucket: [NetRomRouteEvidence], destination: String, timestamp: Date) {
        for evidence in bucket {
            let advertisedQuality = evidence.advertisedQuality(using: config)
            let neighborQuality = router.neighborsForStation(evidence.origin).first?.quality ?? 0
            let requiredQuality = minimumBroadcastQuality(
                minimumCombined: router.config.minimumRouteQuality,
                pathQuality: neighborQuality
            )
            let effectiveQuality = min(
                NetRomConfig.maximumRouteQuality,
                max(advertisedQuality, requiredQuality)
            )
            guard effectiveQuality >= config.inferredMinimumQuality else { continue }
            router.broadcastRoutes(
                from: evidence.origin,
                quality: effectiveQuality,
                destinations: [
                    RouteInfo(destination: evidence.destination, origin: evidence.origin, quality: effectiveQuality, path: evidence.path, lastUpdated: timestamp, sourceType: "inferred")
                ],
                timestamp: timestamp
            )
        }

        // Keep inferred routes in router aligned to active evidence so stale origins
        // do not continue to appear after stronger candidates take over.
        let activeOrigins = Set(bucket.map(\.origin))
        let staleOrigins = router.currentRoutes()
            .filter { $0.destination == destination && $0.sourceType == "inferred" && !activeOrigins.contains($0.origin) }
            .map(\.origin)
        for origin in staleOrigins {
            router.removeRoute(origin: origin, destination: destination, sourceType: "inferred")
        }
    }

    private func simulateNeighborObservation(nextHop: String, timestamp: Date) {
        let neighborAddress = AX25Address(call: nextHop)
        let localAddress = AX25Address(call: localCallsign)
        guard !neighborAddress.call.isEmpty, !localAddress.call.isEmpty else { return }
        let synthetic = Packet(
            timestamp: timestamp,
            from: neighborAddress,
            to: localAddress,
            via: [],
            frameType: .ui,
            control: 0,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: "INFER"
        )
        router.observePacket(
            synthetic,
            observedQuality: config.inferredBaseQuality,
            direction: .incoming,
            timestamp: timestamp
        )
    }

    private func simulateNeighborObservationInferred(nextHop: String, timestamp: Date) {
        let neighborAddress = AX25Address(call: nextHop)
        let localAddress = AX25Address(call: localCallsign)
        guard !neighborAddress.call.isEmpty, !localAddress.call.isEmpty else { return }
        let synthetic = Packet(
            timestamp: timestamp,
            from: neighborAddress,
            to: localAddress,
            via: [],
            frameType: .ui,
            control: 0,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: "INFER"
        )
        router.observePacketInferred(
            synthetic,
            observedQuality: config.inferredBaseQuality,
            direction: .incoming,
            timestamp: timestamp
        )
    }

    private func makeSyntheticPacket(call: String, timestamp: Date) -> Packet {
        let from = AX25Address(call: call)
        let to = AX25Address(call: localCallsign)
        guard !from.call.isEmpty, !to.call.isEmpty else {
            return Packet(timestamp: timestamp)
        }
        return Packet(
            timestamp: timestamp,
            from: from,
            to: to,
            via: [],
            frameType: .ui,
            control: 0,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: "INFER"
        )
    }

    private func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = CallsignValidator.normalize(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func isInfrastructure(_ packet: Packet) -> Bool {
        guard packet.frameType == .ui else { return false }
        guard let text = packet.infoText?.uppercased() else { return false }
        return text == "BEACON" || text.hasPrefix("BEACON ") || text == "ID" || text.hasPrefix("ID ")
    }

    private func minimumBroadcastQuality(minimumCombined: Int, pathQuality: Int) -> Int {
        guard pathQuality > 0 else { return NetRomConfig.maximumRouteQuality }
        let numerator = max(0, (minimumCombined * 256) - 128)
        return (numerator + pathQuality - 1) / pathQuality
    }
}
