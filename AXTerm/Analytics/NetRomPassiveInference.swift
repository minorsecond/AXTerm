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

    private let router: NetRomRouter
    private let localCallsign: String
    private var evidenceByDestination: [String: [NetRomRouteEvidence]] = [:]

    init(router: NetRomRouter, localCallsign: String, config: NetRomInferenceConfig = .default) {
        self.router = router
        self.localCallsign = CallsignValidator.normalize(localCallsign)
        self.config = config
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
        // The radio that heard this frame. Inferred neighbours and routes are
        // its own — a station heard only on one radio is a neighbour on that
        // radio, not on the primary.
        let radio = packet.radioID ?? .primary

        // Case 1: Direct packet addressed to us (no via path)
        if packet.via.isEmpty && normalizedTo == localCallsign {
            guard classification.refreshesNeighbor else { return }
            router.observePacketInferred(
                makeSyntheticPacket(call: normalizedFrom, radio: radio, timestamp: timestamp),
                observedQuality: config.inferredBaseQuality,
                direction: .incoming,
                timestamp: timestamp
            )
            return
        }

        // Case 2: Digipeated packet (has via path)
        // This includes both packets addressed to us AND third-party traffic
        guard !packet.via.isEmpty else { return }

        // A beacon says where a station is, never that a circuit can be opened
        // to it. Treating digipeated APRS as routing evidence filled the table
        // with stations on the APRS frequency and then advertised them to the
        // packet network in NODES broadcasts, promising circuits to trackers
        // and weather stations that have no connected-mode stack at all
        // (2026-09-17). A NET/ROM broadcast is a UI frame too and is
        // classified separately, so node tables still learn normally.
        guard classification != .uiBeacon else { return }

        // Prefer the actual repeated chain (H-bit set) when present; this reflects
        // the path that truly delivered the frame to us.
        //
        // Aliases are dropped before the next hop is picked. A digipeater
        // consumes the alias it answered and sets the H bit on it, so a frame
        // repeated by WQ8M-9 for WIDE1-1 arrives as `WQ8M-9*,WIDE1*,WIDE2-1`
        // and the last repeated entry is the alias, not the station. Taking it
        // literally made WIDE1 a neighbour and hung every station heard
        // through any fill-in digi off it (2026-09-17). The station that
        // actually keyed up is the last repeated entry that is a real node.
        let repeatedViaNormalized = packet.via
            .filter(\.repeated)
            .compactMap { normalize($0.display) }
            .filter { CallsignValidator.isValidRoutingNode($0) }
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
                recordEvidence(destination: normalizedFrom, origin: nextHop, path: [nextHop, normalizedFrom], radio: radio, timestamp: timestamp, classification: classification, isRetry: true)
            }
            return
        }

        // Create inferred neighbor from the digipeater
        simulateNeighborObservationInferred(nextHop: nextHop, radio: radio, timestamp: timestamp)

        // Record route evidence using the path that actually repeated to us.
        // The path we follow to reach the destination is reverse(heardVia) + source.
        // Example: heard VIA W0TX, W0ARP (repeated) => connect path [W0ARP, W0TX, SRC].
        let fullPath = heardViaNormalized.reversed() + [normalizedFrom]
        recordEvidence(destination: normalizedFrom, origin: nextHop, path: fullPath, radio: radio, timestamp: timestamp, classification: classification, isRetry: isRetry)
    }

    #if DEBUG
    /// Test seam: the evidence behind every inferred route, with the numbers
    /// that decide whether it is published at all. See the note on
    /// `NetRomIntegration.observationTrace` for why this exists.
    var debugEvidenceSummary: String {
        guard !evidenceByDestination.isEmpty else {
            return "evidence: none (minQuality=\(config.inferredMinimumQuality) base=\(config.inferredBaseQuality))"
        }
        let lines = evidenceByDestination.keys.sorted().map { destination -> String in
            let bucket = evidenceByDestination[destination] ?? []
            let parts = bucket.map {
                "via \($0.origin) score=\(String(format: "%.2f", $0.reinforcementScore)) "
                + "quality=\($0.advertisedQuality(using: config))"
                + ($0.tombstonedAt == nil ? "" : " tombstoned")
            }
            return "\(destination): " + parts.joined(separator: ", ")
        }
        return "evidence[minQuality=\(config.inferredMinimumQuality)] " + lines.joined(separator: " | ")
    }
    #endif

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

    private func recordEvidence(destination: String, origin: String, path: [String], radio: RadioID, timestamp: Date, classification: PacketClassification, isRetry: Bool) {
        var bucket = evidenceByDestination[destination] ?? []

        // Evidence is per (origin, radio): the same next hop reached on two
        // radios is two ways in, not one — a different antenna and path.
        if let index = bucket.firstIndex(where: { $0.origin == origin && $0.radio == radio }) {
            bucket[index].path = path
            bucket[index].refresh(timestamp: timestamp, classification: classification, config: config, isRetry: isRetry)
        } else {
            if isRetry {
                return
            }
            let initialScore = config.weight(for: classification)
            bucket.append(NetRomRouteEvidence(destination: destination, origin: origin, path: path, lastObserved: timestamp, reinforcementScore: initialScore, radio: radio))
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
            // Publish the honest evidence-derived quality. The router combines it
            // with the neighbor's path quality; the displayed number then tracks
            // observation strength and decays on retries. The old code promoted
            // weak evidence to whatever value would exactly clear the router's
            // minimumRouteQuality, so every weakly-evidenced route displayed the
            // same fabricated floor (32) regardless of how good the path was.
            let advertisedQuality = evidence.advertisedQuality(using: config)
            guard advertisedQuality >= config.inferredMinimumQuality else { continue }
            router.broadcastRoutes(
                from: evidence.origin,
                radio: evidence.radio,
                quality: advertisedQuality,
                destinations: [
                    RouteInfo(destination: evidence.destination, origin: evidence.origin, quality: advertisedQuality, path: evidence.path, lastUpdated: timestamp, sourceType: "inferred", radioID: evidence.radio)
                ],
                timestamp: timestamp
            )
        }

        // Keep inferred routes in router aligned to active evidence so stale
        // (origin, radio) pairs do not linger after stronger candidates take
        // over. Keyed by both, so dropping one radio's stale route never sweeps
        // away the other radio's still-good route to the same origin.
        let active = Set(bucket.map { EvidenceRoute(origin: $0.origin, radio: $0.radio) })
        let stale = router.currentRoutes()
            .filter { $0.destination == destination && $0.sourceType == "inferred"
                && !active.contains(EvidenceRoute(origin: $0.origin, radio: $0.radioID)) }
        for route in stale {
            router.removeRoute(origin: route.origin, destination: destination, radio: route.radioID, sourceType: "inferred")
        }
    }

    /// An (origin, radio) pair — the identity of an inferred route candidate,
    /// so stale-cleanup distinguishes the same next hop on two radios.
    private struct EvidenceRoute: Hashable {
        let origin: String
        let radio: RadioID
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

    private func simulateNeighborObservationInferred(nextHop: String, radio: RadioID, timestamp: Date) {
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
            infoText: "INFER",
            radioID: radio
        )
        router.observePacketInferred(
            synthetic,
            observedQuality: config.inferredBaseQuality,
            direction: .incoming,
            timestamp: timestamp
        )
    }

    private func makeSyntheticPacket(call: String, radio: RadioID, timestamp: Date) -> Packet {
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
            infoText: "INFER",
            radioID: radio
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

}
