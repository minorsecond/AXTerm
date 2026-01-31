//
//  NetRomRouter.swift
//  AXTerm
//
//  Created by Codex on 1/30/26.
//

import Foundation

/// NET/ROM routing configuration constants.
/// Quality math follows section 10 of https://packet-radio.net/wp-content/uploads/2017/04/netrom1.pdf
struct NetRomConfig {
    let neighborBaseQuality: Int
    let neighborIncrement: Int
    let minimumRouteQuality: Int
    let maxRoutesPerDestination: Int
    let obsolescenceInit: Int
    let routeObsolescenceInterval: TimeInterval

    static let `default` = NetRomConfig(
        neighborBaseQuality: 80,
        neighborIncrement: 40,
        minimumRouteQuality: 32,
        maxRoutesPerDestination: 3,
        obsolescenceInit: 1,
        routeObsolescenceInterval: 60
    )

    static let maximumRouteQuality = 255
}

/// Packet direction used when observing quality events.
enum PacketDirection {
    case incoming, outgoing
}

/// Public representation of a NET/ROM neighbor for tests/UI.
struct NeighborInfo: Equatable {
    let call: String
    let quality: Int
    let lastSeen: Date
    let obsolescenceCount: Int
    let sourceType: String

    init(call: String, quality: Int, lastSeen: Date, obsolescenceCount: Int = 1, sourceType: String = "classic") {
        self.call = call
        self.quality = quality
        self.lastSeen = lastSeen
        self.obsolescenceCount = obsolescenceCount
        self.sourceType = sourceType
    }
}

/// Public route snapshot exposed to router tests / graph queries.
struct RouteInfo: Equatable {
    let destination: String
    let origin: String
    let quality: Int
    let path: [String]
    let lastUpdated: Date
    let sourceType: String

    init(destination: String, origin: String, quality: Int, path: [String], lastUpdated: Date, sourceType: String = "broadcast") {
        self.destination = destination
        self.origin = origin
        self.quality = quality
        self.path = path
        self.lastUpdated = lastUpdated
        self.sourceType = sourceType
    }
}

/// Path summary for best path lookups.
struct NetRomPath: Equatable, Hashable {
    let nodes: [String]
    let quality: Int
}

private struct NeighborRecord {
    let call: String
    var pathQuality: Int
    var lastUpdate: Date
    var obsolescenceCount: Int
    var sourceType: String  // "classic" or "inferred"
}

private struct RouteRecord {
    let destination: String
    let origin: String
    var quality: Int
    var path: [String]
    var lastHeard: Date
    var obsolescenceCount: Int
    var sourceType: String  // "classic", "broadcast", or "inferred"
}

final class NetRomRouter {
    let localCallsign: String
    let config: NetRomConfig
    #if DEBUG
    private static var retainedForTests: [NetRomRouter] = []
    #endif

    private var neighbors: [String: NeighborRecord] = [:]
    private var routesByDestination: [String: [RouteRecord]] = [:]

    init(localCallsign: String, config: NetRomConfig = .default) {
        self.localCallsign = CallsignValidator.normalize(localCallsign)
        self.config = config
        #if DEBUG
        Self.retainedForTests.append(self)
        #endif
    }

    func observePacket(
        _ packet: Packet,
        observedQuality: Int,
        direction: PacketDirection,
        timestamp: Date
    ) {
        guard let normalizedFrom = normalize(packet.from?.display),
              let normalizedTo = normalize(packet.to?.display) else { return }

        // Only direct (non-digipeated) packets count for neighbors.
        guard packet.via.isEmpty else { return }
        guard !isInfrastructurePacket(packet) else { return }

        switch direction {
        case .incoming:
            updateNeighbor(call: normalizedFrom, observedQuality: observedQuality, timestamp: timestamp, sourceType: "classic")
        case .outgoing:
            updateNeighbor(call: normalizedTo, observedQuality: observedQuality, timestamp: timestamp, sourceType: "classic")
        }
    }

    /// Observe a packet and create inferred neighbor (used by passive inference).
    func observePacketInferred(
        _ packet: Packet,
        observedQuality: Int,
        direction: PacketDirection,
        timestamp: Date
    ) {
        guard let normalizedFrom = normalize(packet.from?.display),
              let normalizedTo = normalize(packet.to?.display) else { return }

        // Only direct (non-digipeated) packets count for neighbors.
        guard packet.via.isEmpty else { return }
        guard !isInfrastructurePacket(packet) else { return }

        switch direction {
        case .incoming:
            updateNeighbor(call: normalizedFrom, observedQuality: observedQuality, timestamp: timestamp, sourceType: "inferred")
        case .outgoing:
            updateNeighbor(call: normalizedTo, observedQuality: observedQuality, timestamp: timestamp, sourceType: "inferred")
        }
    }

    #if DEBUG
    private static var hasLoggedBroadcast = false
    #endif

    func broadcastRoutes(from origin: String, quality: Int, destinations: [RouteInfo], timestamp: Date) {
        guard let normalizedOrigin = normalize(origin) else {
            #if DEBUG
            if !Self.hasLoggedBroadcast {
                print("[NETROM:ROUTER] broadcastRoutes: origin '\(origin)' failed normalization")
            }
            #endif
            return
        }
        guard let neighbor = neighbors[normalizedOrigin] else {
            #if DEBUG
            if !Self.hasLoggedBroadcast {
                print("[NETROM:ROUTER] broadcastRoutes: origin '\(normalizedOrigin)' is NOT a neighbor")
                print("[NETROM:ROUTER]   Current neighbors: \(neighbors.keys.sorted())")
                Self.hasLoggedBroadcast = true
            }
            #endif
            return
        }

        #if DEBUG
        print("[NETROM:ROUTER] broadcastRoutes: processing \(destinations.count) destinations from \(normalizedOrigin)")
        #endif

        for advertised in destinations {
            guard let normalizedDestination = normalize(advertised.destination) else { continue }
            if normalizedDestination == localCallsign { continue }
            if normalizedDestination == normalizedOrigin { continue }
            if advertised.path.contains(where: { normalize($0) == localCallsign }) { continue }

            let combined = combinedQuality(broadcastQuality: advertised.quality, pathQuality: neighbor.pathQuality)
            guard combined >= config.minimumRouteQuality else {
                #if DEBUG
                print("[NETROM:ROUTER]   Route to \(normalizedDestination) rejected: quality \(combined) < min \(config.minimumRouteQuality)")
                #endif
                continue
            }

            var normalizedPath = advertised.path.compactMap { normalize($0) }
            if normalizedPath.first != normalizedOrigin {
                normalizedPath.insert(normalizedOrigin, at: 0)
            }
            if normalizedPath.contains(localCallsign) { continue }

            // Determine sourceType: use the advertised sourceType, but ensure inferred routes stay inferred
            let effectiveSourceType = advertised.sourceType.isEmpty ? "broadcast" : advertised.sourceType

            #if DEBUG
            print("[NETROM:ROUTER]   ✓ Storing route: \(normalizedDestination) via \(normalizedOrigin) quality=\(combined) source=\(effectiveSourceType)")
            #endif

            storeRoute(
                destination: normalizedDestination,
                origin: normalizedOrigin,
                quality: combined,
                path: normalizedPath,
                timestamp: timestamp,
                sourceType: effectiveSourceType
            )
        }
    }

    func currentNeighbors() -> [NeighborInfo] {
        neighbors
            .values
            .sorted(by: neighborSort)
            .map { NeighborInfo(call: $0.call, quality: $0.pathQuality, lastSeen: $0.lastUpdate, obsolescenceCount: $0.obsolescenceCount, sourceType: $0.sourceType) }
    }

    func currentRoutes() -> [RouteInfo] {
        let sortedDestinations = routesByDestination.keys.sorted()
        return sortedDestinations.flatMap { destination in
            let bucket = routesByDestination[destination] ?? []
            return bucket.map { route in
                RouteInfo(destination: destination, origin: route.origin, quality: route.quality, path: route.path, lastUpdated: route.lastHeard, sourceType: route.sourceType)
            }
        }
    }

    func removeRoute(origin: String, destination: String) {
        guard let normalizedDestination = normalize(destination) else { return }
        guard var bucket = routesByDestination[normalizedDestination] else { return }
        bucket.removeAll { $0.origin == origin }
        if bucket.isEmpty {
            routesByDestination.removeValue(forKey: normalizedDestination)
            return
        }
        bucket.sort(by: routeSort)
        routesByDestination[normalizedDestination] = bucket
    }

    func bestPaths(from destination: String) -> [NetRomPath] {
        guard let normalized = normalize(destination),
              let routes = routesByDestination[normalized] else { return [] }
        return routes.map { NetRomPath(nodes: $0.path, quality: $0.quality) }
    }

    func neighborsForStation(_ station: String) -> [NeighborInfo] {
        guard let normalized = normalize(station) else { return [] }
        return currentNeighbors().filter { $0.call == normalized }
    }

    func bestRouteTo(_ destination: String) -> RouteInfo? {
        guard let normalized = normalize(destination) else { return nil }
        return currentRoutes().first { $0.destination == normalized }
    }

    // MARK: - Import from Persistence

    func importNeighbors(_ infos: [NeighborInfo]) {
        for info in infos {
            let normalized = CallsignValidator.normalize(info.call)
            guard !normalized.isEmpty, normalized != localCallsign else { continue }
            neighbors[normalized] = NeighborRecord(
                call: normalized,
                pathQuality: info.quality,
                lastUpdate: info.lastSeen,
                obsolescenceCount: info.obsolescenceCount,
                sourceType: info.sourceType
            )
        }
    }

    func importRoutes(_ infos: [RouteInfo]) {
        #if DEBUG
        print("[NETROM:ROUTER] importRoutes called with \(infos.count) routes")
        for (i, info) in infos.prefix(5).enumerated() {
            print("[NETROM:ROUTER]   [\(i)] \(info.destination) via \(info.origin) quality=\(info.quality)")
        }
        if infos.count > 5 { print("[NETROM:ROUTER]   ... and \(infos.count - 5) more") }
        #endif

        for info in infos {
            let normalizedDest = CallsignValidator.normalize(info.destination)
            guard !normalizedDest.isEmpty, normalizedDest != localCallsign else { continue }
            let normalizedPath = info.path.map { CallsignValidator.normalize($0) }
            let record = RouteRecord(
                destination: normalizedDest,
                origin: info.origin,
                quality: info.quality,
                path: normalizedPath,
                lastHeard: info.lastUpdated,
                obsolescenceCount: config.obsolescenceInit,
                sourceType: info.sourceType
            )
            var bucket = routesByDestination[normalizedDest] ?? []
            if let existingIndex = bucket.firstIndex(where: { $0.origin == info.origin }) {
                bucket[existingIndex] = record
            } else {
                bucket.append(record)
            }
            bucket.sort(by: routeSort)
            routesByDestination[normalizedDest] = bucket
        }

        #if DEBUG
        print("[NETROM:ROUTER] After import, routesByDestination has \(routesByDestination.count) destinations")
        #endif
    }

    func purgeStaleRoutes(currentDate: Date) {
        var refreshedRoutes: [String: [RouteRecord]] = [:]
        for (destination, routeList) in routesByDestination {
            let updated = routeList.compactMap { route -> RouteRecord? in
                let age = currentDate.timeIntervalSince(route.lastHeard)
                let intervals = max(0, Int(age / config.routeObsolescenceInterval))
                let remaining = route.obsolescenceCount - intervals
                guard remaining > 0 else { return nil }
                var refreshed = route
                refreshed.obsolescenceCount = remaining
                return refreshed
            }
            guard !updated.isEmpty else { continue }
            refreshedRoutes[destination] = updated.sorted(by: routeSort)
        }
        routesByDestination = refreshedRoutes

        neighbors = neighbors.compactMapValues { neighbor in
            let age = currentDate.timeIntervalSince(neighbor.lastUpdate)
            let intervals = max(0, Int(age / config.routeObsolescenceInterval))
            let remaining = neighbor.obsolescenceCount - intervals
            guard remaining > 0 else { return nil }
            var refreshed = neighbor
            refreshed.obsolescenceCount = remaining
            return refreshed
        }
    }

    // MARK: - Private helpers

    private func updateNeighbor(call: String, observedQuality: Int, timestamp: Date, sourceType: String = "classic") {
        guard call != localCallsign else { return }
        var candidate = neighbors[call] ?? NeighborRecord(
            call: call,
            pathQuality: config.neighborBaseQuality,
            lastUpdate: timestamp,
            obsolescenceCount: config.obsolescenceInit,
            sourceType: sourceType
        )
        let normalizedQuality = clampQuality(observedQuality)
        let boostedQuality = min(NetRomConfig.maximumRouteQuality, max(candidate.pathQuality, normalizedQuality) + config.neighborIncrement)
        candidate.pathQuality = boostedQuality
        candidate.lastUpdate = timestamp
        candidate.obsolescenceCount = config.obsolescenceInit
        // Don't overwrite classic with inferred
        if candidate.sourceType != "classic" {
            candidate.sourceType = sourceType
        }
        neighbors[call] = candidate
    }

    private func storeRoute(
        destination: String,
        origin: String,
        quality: Int,
        path: [String],
        timestamp: Date,
        sourceType: String = "broadcast"
    ) {
        var bucket = routesByDestination[destination] ?? []
        if let existingIndex = bucket.firstIndex(where: { $0.origin == origin }) {
            var existing = bucket[existingIndex]
            existing.quality = max(existing.quality, quality)
            existing.path = path
            existing.lastHeard = timestamp
            existing.obsolescenceCount = config.obsolescenceInit
            // Don't overwrite classic/broadcast with inferred
            if existing.sourceType == "inferred" && sourceType != "inferred" {
                existing.sourceType = sourceType
            }
            bucket[existingIndex] = existing
        } else {
            let newRoute = RouteRecord(
                destination: destination,
                origin: origin,
                quality: quality,
                path: path,
                lastHeard: timestamp,
                obsolescenceCount: config.obsolescenceInit,
                sourceType: sourceType
            )
            bucket.append(newRoute)
        }
        bucket.sort(by: routeSort)
        if bucket.count > config.maxRoutesPerDestination {
            bucket = Array(bucket.prefix(config.maxRoutesPerDestination))
        }
        routesByDestination[destination] = bucket
    }

    private func combinedQuality(broadcastQuality: Int, pathQuality: Int) -> Int {
        let normalizedBroadcast = clampQuality(broadcastQuality)
        let normalizedPath = clampQuality(pathQuality)
        let combined = (normalizedBroadcast * normalizedPath) + 128
        return min(NetRomConfig.maximumRouteQuality, combined / 256)
    }

    private func clampQuality(_ value: Int) -> Int {
        min(max(value, 0), NetRomConfig.maximumRouteQuality)
    }

    private func routeSort(lhs: RouteRecord, rhs: RouteRecord) -> Bool {
        if lhs.quality != rhs.quality {
            return lhs.quality > rhs.quality
        }
        if lhs.origin != rhs.origin {
            return lhs.origin < rhs.origin
        }
        return lhs.path.count < rhs.path.count
    }

    private func neighborSort(lhs: NeighborRecord, rhs: NeighborRecord) -> Bool {
        if lhs.pathQuality != rhs.pathQuality {
            return lhs.pathQuality > rhs.pathQuality
        }
        return lhs.call < rhs.call
    }

    private func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = CallsignValidator.normalize(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func isInfrastructurePacket(_ packet: Packet) -> Bool {
        guard packet.frameType == .ui else { return false }
        guard let text = packet.infoText?.uppercased() else { return false }
        return text == "BEACON" || text.hasPrefix("BEACON ") || text == "ID" || text.hasPrefix("ID ")
    }

}
