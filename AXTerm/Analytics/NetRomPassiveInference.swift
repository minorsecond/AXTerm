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

    func observePacket(_ packet: Packet, timestamp: Date) {
        guard let rawFrom = packet.from?.display,
              let normalizedFrom = normalize(rawFrom),
              let rawTo = packet.to?.display,
              let normalizedTo = normalize(rawTo),
              normalizedTo == localCallsign,
              !isInfrastructure(packet)
        else {
            return
        }

        if packet.via.isEmpty {
            router.observePacket(
                makeSyntheticPacket(call: normalizedFrom, timestamp: timestamp),
                observedQuality: config.inferredBaseQuality,
                direction: .incoming,
                timestamp: timestamp
            )
            return
        }

        let viaNormalized = packet.via.compactMap { normalize($0.display) }
        guard let nextHop = viaNormalized.last else { return }
        guard nextHop != localCallsign, nextHop != normalizedFrom else { return }

        simulateNeighborObservation(nextHop: nextHop, timestamp: timestamp)
        recordEvidence(destination: normalizedFrom, origin: nextHop, path: [nextHop, normalizedFrom], timestamp: timestamp)
    }

    func purgeStaleEvidence(currentDate: Date) {
        var refreshedEvidence: [String: [NetRomRouteEvidence]] = [:]
        var removals: [(origin: String, destination: String)] = []

        for (destination, bucket) in evidenceByDestination {
            let filtered = bucket.filter { currentDate.timeIntervalSince($0.lastObserved) < config.inferredRouteHalfLifeSeconds }
            guard !filtered.isEmpty else {
                bucket.forEach { evidence in
                    removals.append((origin: evidence.origin, destination: destination))
                }
                continue
            }
            let filteredOrigins = Set(filtered.map(\.origin))
            for evidence in bucket where !filteredOrigins.contains(evidence.origin) {
                removals.append((origin: evidence.origin, destination: destination))
            }
            refreshedEvidence[destination] = filtered
        }

        evidenceByDestination = refreshedEvidence
        for removal in removals {
            router.removeRoute(origin: removal.origin, destination: removal.destination)
        }

        router.purgeStaleRoutes(currentDate: currentDate)
    }

    // MARK: - Helpers

    private func recordEvidence(destination: String, origin: String, path: [String], timestamp: Date) {
        var bucket = evidenceByDestination[destination] ?? []

        if let index = bucket.firstIndex(where: { $0.origin == origin }) {
            bucket[index].path = path
            bucket[index].refresh(timestamp: timestamp, config: config)
        } else {
            bucket.append(NetRomRouteEvidence(destination: destination, origin: origin, path: path, lastObserved: timestamp, reinforcementLevel: 1))
        }

        bucket.sort { $0.advertisedQuality(using: config) > $1.advertisedQuality(using: config) }
        if bucket.count > config.maxInferredRoutesPerDestination {
            bucket = Array(bucket.prefix(config.maxInferredRoutesPerDestination))
        }
        evidenceByDestination[destination] = bucket

        publishEvidence(bucket, timestamp: timestamp)
    }

    private func publishEvidence(_ bucket: [NetRomRouteEvidence], timestamp: Date) {
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
                    RouteInfo(destination: evidence.destination, origin: evidence.origin, quality: effectiveQuality, path: evidence.path)
                ],
                timestamp: timestamp
            )
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
