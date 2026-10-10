import Foundation

typealias RouteRow = RouteInfo
typealias NeighborRow = NeighborInfo

nonisolated struct ObservedPath: Hashable {
    let peer: String
    let digis: [String]
    var lastSeen: Date
    var count: Int
}

nonisolated struct ConnectSuggestions: Equatable {
    struct DigiPath: Hashable {
        let digis: [String]
        let score: Double
        let source: Source

        enum Source: Int, CaseIterable {
            case routeDerived = 0
            case observedForDestination = 1
            case historicalSuccess = 2
            case neighborStrong = 3
        }
    }

    struct NetRomNextHop: Hashable {
        let callsign: String
        let score: Double
        let source: Source

        enum Source: Int, CaseIterable {
            case routePreferred = 0
            case historicalSuccess = 1
            case neighborStrong = 2
        }
    }

    let recommendedDigiPaths: [DigiPath]
    let fallbackDigiPaths: [DigiPath]
    let recommendedNextHops: [NetRomNextHop]
    let fallbackNextHops: [NetRomNextHop]

    static let empty = ConnectSuggestions(
        recommendedDigiPaths: [],
        fallbackDigiPaths: [],
        recommendedNextHops: [],
        fallbackNextHops: []
    )
}

nonisolated struct ConnectSuggestionEngine {
    private static let goodNeighborQualityThreshold = 128
    private static let strongFreshnessThreshold = 0.8
    private static let observedFreshWindow: TimeInterval = 10 * 60
    private static let recentFailureWindow: TimeInterval = 30 * 60
    private static let maxDigis = DigipeaterListParser.maxDigipeaters
    private static let maxRecommended = 4
    private static let maxNetRomTotal = 10

    static func build(
        to destination: String,
        mode: ConnectBarMode,
        routes: [RouteRow],
        neighbors: [NeighborRow],
        observedPaths: [ObservedPath],
        attemptHistory: [ConnectAttempt]
    ) -> ConnectSuggestions {
        let now = Date()
        let destinationKey = callsignKey(destination)
        guard !destinationKey.isEmpty else { return .empty }

        let digiSuggestions = buildDigiSuggestions(
            destination: destination,
            destinationKey: destinationKey,
            mode: mode,
            routes: routes,
            neighbors: neighbors,
            observedPaths: observedPaths,
            attemptHistory: attemptHistory,
            now: now
        )

        let netRomSuggestions = buildNetRomNextHops(
            destination: destination,
            destinationKey: destinationKey,
            mode: mode,
            routes: routes,
            neighbors: neighbors,
            attemptHistory: attemptHistory,
            now: now
        )

        return ConnectSuggestions(
            recommendedDigiPaths: Array(digiSuggestions.prefix(maxRecommended)),
            fallbackDigiPaths: Array(digiSuggestions.dropFirst(maxRecommended)),
            recommendedNextHops: Array(netRomSuggestions.prefix(maxRecommended)),
            fallbackNextHops: Array(netRomSuggestions.dropFirst(maxRecommended))
        )
    }

    private static func buildDigiSuggestions(
        destination: String,
        destinationKey: String,
        mode: ConnectBarMode,
        routes: [RouteRow],
        neighbors: [NeighborRow],
        observedPaths: [ObservedPath],
        attemptHistory: [ConnectAttempt],
        now: Date
    ) -> [ConnectSuggestions.DigiPath] {
        guard mode == .ax25ViaDigi else { return [] }
        var candidates: [String: ConnectSuggestions.DigiPath] = [:]

        if let bestRoute = bestRouteRow(for: destinationKey, from: routes),
           let routePath = routeDerivedDigis(from: bestRoute, destinationKey: destinationKey),
           !routePath.isEmpty {
            addDigiCandidate(
                path: routePath,
                score: 1.0,
                source: .routeDerived,
                into: &candidates
            )
        }

        let observedMatches = observedPaths.filter { callsignKey($0.peer) == destinationKey }
        for observed in observedMatches {
            var score = 0.80
            if now.timeIntervalSince(observed.lastSeen) <= observedFreshWindow {
                score += 0.05
            }
            addDigiCandidate(
                path: observed.digis,
                score: score,
                source: .observedForDestination,
                into: &candidates
            )
        }

        let historySuccess = attemptHistory.filter {
            $0.mode == .ax25ViaDigi &&
            $0.success &&
            callsignKey($0.to) == destinationKey &&
            !$0.digis.isEmpty
        }
        for success in historySuccess {
            let normalizedDigis = normalizePath(success.digis)
            guard !normalizedDigis.isEmpty else { continue }
            var score = 0.90
            let hasRecentFailure = attemptHistory.contains {
                $0.mode == .ax25ViaDigi &&
                !$0.success &&
                callsignKey($0.to) == destinationKey &&
                normalizePath($0.digis) == normalizedDigis &&
                now.timeIntervalSince($0.timestamp) <= recentFailureWindow
            }
            if hasRecentFailure {
                score -= 0.20
            }
            addDigiCandidate(
                path: normalizedDigis,
                score: score,
                source: .historicalSuccess,
                into: &candidates
            )
        }

        for neighbor in strongNeighbors(from: neighbors, now: now) {
            addDigiCandidate(
                path: [neighbor],
                score: 0.60,
                source: .neighborStrong,
                into: &candidates
            )
        }

        return candidates.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if sourcePriority(lhs.source) != sourcePriority(rhs.source) {
                return sourcePriority(lhs.source) < sourcePriority(rhs.source)
            }
            return lhs.digis.joined(separator: ",") < rhs.digis.joined(separator: ",")
        }
    }

    private static func buildNetRomNextHops(
        destination: String,
        destinationKey: String,
        mode: ConnectBarMode,
        routes: [RouteRow],
        neighbors: [NeighborRow],
        attemptHistory: [ConnectAttempt],
        now: Date
    ) -> [ConnectSuggestions.NetRomNextHop] {
        guard mode == .netrom else { return [] }
        var candidates: [String: ConnectSuggestions.NetRomNextHop] = [:]

        if let bestRoute = bestRouteRow(for: destinationKey, from: routes) {
            let nextHop = normalizeCallsign(bestRoute.path.first ?? bestRoute.origin)
            if !nextHop.isEmpty {
                addNextHopCandidate(
                    hop: nextHop,
                    score: 1.0,
                    source: .routePreferred,
                    into: &candidates
                )
            }
        }

        let historySuccess = attemptHistory.filter {
            $0.mode == .netrom &&
            $0.success &&
            callsignKey($0.to) == destinationKey &&
            !normalizeCallsign($0.nextHopOverride ?? "").isEmpty
        }
        for success in historySuccess {
            let override = normalizeCallsign(success.nextHopOverride ?? "")
            guard !override.isEmpty else { continue }
            var score = 0.90
            let hasRecentFailure = attemptHistory.contains {
                $0.mode == .netrom &&
                !$0.success &&
                callsignKey($0.to) == destinationKey &&
                normalizeCallsign($0.nextHopOverride ?? "") == override &&
                now.timeIntervalSince($0.timestamp) <= recentFailureWindow
            }
            if hasRecentFailure {
                score -= 0.20
            }
            addNextHopCandidate(
                hop: override,
                score: score,
                source: .historicalSuccess,
                into: &candidates
            )
        }

        for neighbor in strongNeighbors(from: neighbors, now: now) {
            addNextHopCandidate(
                hop: neighbor,
                score: 0.70,
                source: .neighborStrong,
                into: &candidates
            )
        }

        let sorted = candidates.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if nextHopSourcePriority(lhs.source) != nextHopSourcePriority(rhs.source) {
                return nextHopSourcePriority(lhs.source) < nextHopSourcePriority(rhs.source)
            }
            return lhs.callsign < rhs.callsign
        }
        return Array(sorted.prefix(maxNetRomTotal))
    }

    private static func sourcePriority(_ source: ConnectSuggestions.DigiPath.Source) -> Int {
        switch source {
        case .routeDerived:
            return 0
        case .historicalSuccess:
            return 1
        case .observedForDestination:
            return 2
        case .neighborStrong:
            return 3
        }
    }

    private static func nextHopSourcePriority(_ source: ConnectSuggestions.NetRomNextHop.Source) -> Int {
        switch source {
        case .routePreferred:
            return 0
        case .historicalSuccess:
            return 1
        case .neighborStrong:
            return 2
        }
    }

    private static func strongNeighbors(from neighbors: [NeighborRow], now: Date) -> [String] {
        neighbors.compactMap { neighbor in
            let normalized = normalizeCallsign(neighbor.call)
            guard !normalized.isEmpty else { return nil }
            guard neighbor.quality >= goodNeighborQualityThreshold else { return nil }
            let freshness = neighbor.freshness(now: now, ttl: FreshnessCalculator.defaultTTL)
            guard freshness >= strongFreshnessThreshold else { return nil }
            return normalized
        }
    }

    private static func routeDerivedDigis(from route: RouteRow, destinationKey: String) -> [String]? {
        var path = normalizePath(route.path)
        if path.isEmpty {
            let fallback = normalizeCallsign(route.origin)
            path = fallback.isEmpty ? [] : [fallback]
        }
        guard !path.isEmpty else { return nil }

        if callsignKey(path.last ?? "") == destinationKey {
            path.removeLast()
        }
        if let first = path.first, callsignKey(first) == destinationKey {
            path.removeFirst()
        }

        return Array(path.prefix(2))
    }

    private static func bestRouteRow(for destinationKey: String, from routes: [RouteRow]) -> RouteRow? {
        routes
            .filter { callsignKey($0.destination) == destinationKey }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated > rhs.lastUpdated }
                if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
                return lhs.origin < rhs.origin
            }
            .first
    }

    private static func addDigiCandidate(
        path: [String],
        score: Double,
        source: ConnectSuggestions.DigiPath.Source,
        into candidates: inout [String: ConnectSuggestions.DigiPath]
    ) {
        let normalizedPath = normalizePath(path)
        guard !normalizedPath.isEmpty else { return }
        guard normalizedPath.count <= maxDigis else { return }

        let key = normalizedPath.joined(separator: ",")
        let candidate = ConnectSuggestions.DigiPath(
            digis: normalizedPath,
            score: score,
            source: source
        )

        if let existing = candidates[key] {
            if candidate.score > existing.score {
                candidates[key] = candidate
            } else if candidate.score == existing.score &&
                        sourcePriority(candidate.source) < sourcePriority(existing.source) {
                candidates[key] = candidate
            }
        } else {
            candidates[key] = candidate
        }
    }

    private static func addNextHopCandidate(
        hop: String,
        score: Double,
        source: ConnectSuggestions.NetRomNextHop.Source,
        into candidates: inout [String: ConnectSuggestions.NetRomNextHop]
    ) {
        let normalizedHop = normalizeCallsign(hop)
        guard !normalizedHop.isEmpty else { return }

        let candidate = ConnectSuggestions.NetRomNextHop(
            callsign: normalizedHop,
            score: score,
            source: source
        )

        if let existing = candidates[normalizedHop] {
            if candidate.score > existing.score {
                candidates[normalizedHop] = candidate
            } else if candidate.score == existing.score &&
                        nextHopSourcePriority(candidate.source) < nextHopSourcePriority(existing.source) {
                candidates[normalizedHop] = candidate
            }
        } else {
            candidates[normalizedHop] = candidate
        }
    }

    private static func normalizePath(_ path: [String]) -> [String] {
        path
            .map { normalizeCallsign($0) }
            .filter { !$0.isEmpty && CallsignValidator.isValidDigipeaterAddress($0) }
    }

    private static func normalizeCallsign(_ raw: String) -> String {
        let normalized = CallsignValidator.normalize(raw)
        guard !normalized.isEmpty else { return "" }
        let parsed = CallsignNormalizer.parse(normalized)
        guard !parsed.call.isEmpty else { return "" }
        return CallsignNormalizer.display(call: parsed.call, ssid: parsed.ssid)
    }

    private static func callsignKey(_ raw: String) -> String {
        let normalized = normalizeCallsign(raw)
        guard !normalized.isEmpty else { return "" }
        let parsed = CallsignNormalizer.parse(normalized)
        return "\(parsed.call)-\(parsed.ssid)"
    }
}

/// The digipeater paths seen in stored traffic, per peer, for the connect
/// bar. Rebuilt from every packet a moment after each burst; each distinct
/// callsign is normalized and judged once per rebuild. Judging it again for
/// each of 9,000 packets took about 350 ms on the main thread (2026-10-10).
nonisolated enum ObservedPathIndex {
    struct Result {
        var paths: [ObservedPath]
        var knownDigis: Set<String>
    }

    static func build(_ packets: [Packet], canonical: (String) -> String, isDigi: (String) -> Bool) -> Result {
        var canonicalOf: [String: String] = [:]
        var digiVerdict: [String: Bool] = [:]
        func canon(_ raw: String) -> String {
            if let known = canonicalOf[raw] { return known }
            let value = canonical(raw)
            canonicalOf[raw] = value
            return value
        }
        func digi(_ call: String) -> Bool {
            if let known = digiVerdict[call] { return known }
            let value = isDigi(call)
            digiVerdict[call] = value
            return value
        }

        var paths: [String: ObservedPath] = [:]
        var knownDigis = Set<String>()
        for packet in packets {
            let via = packet.via.map { canon($0.display) }.filter { !$0.isEmpty && digi($0) }
            guard !via.isEmpty else { continue }
            knownDigis.formUnion(via)
            let signature = via.joined(separator: ",")
            let peers = [packet.to.map { canon($0.display) } ?? "", packet.from.map { canon($0.display) } ?? ""]
            for peer in peers where !peer.isEmpty {
                let key = peer + "|" + signature
                if var existing = paths[key] {
                    existing.count += 1
                    if packet.timestamp > existing.lastSeen { existing.lastSeen = packet.timestamp }
                    paths[key] = existing
                } else {
                    paths[key] = ObservedPath(peer: peer, digis: via, lastSeen: packet.timestamp, count: 1)
                }
            }
        }
        return Result(paths: Array(paths.values), knownDigis: knownDigis)
    }
}
