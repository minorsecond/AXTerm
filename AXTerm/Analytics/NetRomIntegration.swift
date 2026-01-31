//
//  NetRomIntegration.swift
//  AXTerm
//
//  Created by Codex on 1/30/26.
//

import Foundation

/// Routing mode for NET/ROM integration.
enum NetRomRoutingMode: Sendable {
    /// Classic mode: only uses explicit NET/ROM broadcasts for routing.
    case classic

    /// Inference mode: uses passive observations to infer routes.
    case inference

    /// Hybrid mode: combines classic broadcasts with passive inference.
    case hybrid
}

/// Unified NET/ROM routing integration combining the classic router,
/// passive inference engine, and link quality estimator.
@MainActor
final class NetRomIntegration {
    private let localCallsign: String
    private var mode: NetRomRoutingMode

    private let router: NetRomRouter
    private var passiveInference: NetRomPassiveInference?
    private var linkEstimator: LinkQualityEstimator

    private let routerConfig: NetRomConfig
    private let inferenceConfig: NetRomInferenceConfig
    private let linkConfig: LinkQualityConfig

    #if DEBUG
    private static var retainedForTests: [NetRomIntegration] = []
    #endif

    init(
        localCallsign: String,
        mode: NetRomRoutingMode,
        routerConfig: NetRomConfig = .default,
        inferenceConfig: NetRomInferenceConfig = .default,
        linkConfig: LinkQualityConfig = .default
    ) {
        self.localCallsign = CallsignValidator.normalize(localCallsign)
        self.mode = mode
        self.routerConfig = routerConfig
        self.inferenceConfig = inferenceConfig
        self.linkConfig = linkConfig

        self.router = NetRomRouter(localCallsign: localCallsign, config: routerConfig)
        self.linkEstimator = LinkQualityEstimator(config: linkConfig)

        if mode == .inference || mode == .hybrid {
            self.passiveInference = NetRomPassiveInference(
                router: router,
                localCallsign: localCallsign,
                config: inferenceConfig
            )
        }

        #if DEBUG
        Self.retainedForTests.append(self)
        #endif
    }

    // MARK: - Mode Management

    func setMode(_ newMode: NetRomRoutingMode) {
        guard mode != newMode else { return }
        mode = newMode

        if newMode == .inference || newMode == .hybrid {
            if passiveInference == nil {
                passiveInference = NetRomPassiveInference(
                    router: router,
                    localCallsign: localCallsign,
                    config: inferenceConfig
                )
            }
        }
    }

    var currentMode: NetRomRoutingMode {
        mode
    }

    // MARK: - Packet Observation

    func observePacket(_ packet: Packet, timestamp: Date, isDuplicate: Bool = false) {
        // Always update link quality estimator
        linkEstimator.observePacket(packet, timestamp: timestamp, isDuplicate: isDuplicate)

        // Check for NET/ROM broadcast packets (PID 0xCF to NODES)
        // These are processed in all modes since they're explicit routing information
        if let broadcastResult = NetRomBroadcastParser.parse(packet: packet) {
            processNetRomBroadcast(broadcastResult)
            return // Don't double-process as regular packet
        }

        // Get current link quality for the sender
        let rawFrom = packet.from?.display ?? ""
        let normalizedFrom = CallsignValidator.normalize(rawFrom)
        let observedQuality = linkQualityForNeighbor(normalizedFrom)

        switch mode {
        case .classic:
            // Classic mode: only direct observations become neighbors
            if packet.via.isEmpty {
                router.observePacket(packet, observedQuality: observedQuality, direction: .incoming, timestamp: timestamp)
            }

        case .inference:
            // Inference mode: use passive inference for all observations
            passiveInference?.observePacket(packet, timestamp: timestamp)

        case .hybrid:
            // Hybrid mode: use both classic and inference
            if packet.via.isEmpty {
                router.observePacket(packet, observedQuality: observedQuality, direction: .incoming, timestamp: timestamp)
            }
            passiveInference?.observePacket(packet, timestamp: timestamp)
        }
    }

    /// Process a parsed NET/ROM broadcast, adding the sender as a neighbor and updating routes.
    private func processNetRomBroadcast(_ result: NetRomBroadcastResult) {
        let normalizedOrigin = CallsignValidator.normalize(result.originCallsign)
        guard !normalizedOrigin.isEmpty else { return }

        #if DEBUG
        print("[NETROM:INTEGRATION] Processing NET/ROM broadcast from \(normalizedOrigin) with \(result.entries.count) entries")
        #endif

        // First, ensure the broadcast sender is registered as a neighbor
        // NET/ROM broadcasts are always direct (no digipeating), so the sender is a neighbor
        let syntheticPacket = Packet(
            timestamp: result.timestamp,
            from: AX25Address(call: normalizedOrigin),
            to: AX25Address(call: localCallsign),
            via: [],
            frameType: .ui,
            control: 0,
            pid: NetRomBroadcastParser.netromPID,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )

        // Register as neighbor with high quality (broadcast reception implies good link)
        let observedQuality = linkQualityForNeighbor(normalizedOrigin)
        router.observePacket(syntheticPacket, observedQuality: max(observedQuality, 200), direction: .incoming, timestamp: result.timestamp)

        // Convert broadcast entries to RouteInfo and feed to router
        let routeInfos = result.entries.map { entry in
            RouteInfo(
                destination: CallsignValidator.normalize(entry.destinationCallsign),
                origin: normalizedOrigin,
                quality: entry.quality,
                path: [normalizedOrigin, CallsignValidator.normalize(entry.destinationCallsign)],
                lastUpdated: result.timestamp,
                sourceType: "broadcast"
            )
        }

        // Process the broadcast routes through the router
        router.broadcastRoutes(
            from: normalizedOrigin,
            quality: 255, // Broadcast sender quality - actual route quality is in each entry
            destinations: routeInfos,
            timestamp: result.timestamp
        )
    }

    /// Process an explicit NET/ROM broadcast (classic routing).
    func broadcastRoutes(from origin: String, quality: Int, destinations: [RouteInfo], timestamp: Date) {
        router.broadcastRoutes(from: origin, quality: quality, destinations: destinations, timestamp: timestamp)
    }

    // MARK: - Query Methods

    private var hasLoggedFirstQuery = false

    func currentNeighbors() -> [NeighborInfo] {
        let result = router.currentNeighbors()
        #if DEBUG
        if !hasLoggedFirstQuery {
            print("[NETROM:INTEGRATION] currentNeighbors() returning \(result.count) neighbors")
        }
        #endif
        return result
    }

    func currentRoutes() -> [RouteInfo] {
        let result = router.currentRoutes()
        #if DEBUG
        if !hasLoggedFirstQuery {
            print("[NETROM:INTEGRATION] currentRoutes() returning \(result.count) routes")
            hasLoggedFirstQuery = true
        }
        #endif
        return result
    }

    // MARK: - Mode-Filtered Query Methods

    /// Get neighbors filtered by mode.
    func currentNeighbors(forMode mode: NetRomRoutingMode) -> [NeighborInfo] {
        let all = router.currentNeighbors()
        switch mode {
        case .classic:
            return all.filter { $0.sourceType == "classic" }
        case .inference:
            return all.filter { $0.sourceType == "inferred" }
        case .hybrid:
            return all
        }
    }

    /// Get routes filtered by mode.
    func currentRoutes(forMode mode: NetRomRoutingMode) -> [RouteInfo] {
        let all = router.currentRoutes()
        switch mode {
        case .classic:
            return all.filter { $0.sourceType == "classic" || $0.sourceType == "broadcast" }
        case .inference:
            return all.filter { $0.sourceType == "inferred" }
        case .hybrid:
            return all
        }
    }

    /// Get link stats filtered by mode (based on which neighbors are relevant).
    func exportLinkStats(forMode mode: NetRomRoutingMode) -> [LinkStatRecord] {
        let allStats = linkEstimator.exportLinkStats()
        let relevantNeighbors = Set(currentNeighbors(forMode: mode).map { $0.call })

        switch mode {
        case .classic:
            // For classic mode, include links involving classic neighbors or local callsign
            return allStats.filter { stat in
                relevantNeighbors.contains(stat.fromCall) ||
                relevantNeighbors.contains(stat.toCall) ||
                stat.fromCall == localCallsign ||
                stat.toCall == localCallsign
            }
        case .inference:
            // For inference mode, only include links involving inferred neighbors
            // Don't include local callsign links unless they involve an inferred neighbor
            return allStats.filter { stat in
                relevantNeighbors.contains(stat.fromCall) ||
                relevantNeighbors.contains(stat.toCall)
            }
        case .hybrid:
            return allStats
        }
    }

    func bestRouteTo(_ destination: String) -> RouteInfo? {
        router.bestRouteTo(destination)
    }

    func linkQuality(from: String, to: String) -> Int {
        linkEstimator.linkQuality(from: from, to: to)
    }

    // MARK: - Maintenance

    func purgeStaleData(currentDate: Date) {
        linkEstimator.purgeStaleData(currentDate: currentDate)
        passiveInference?.purgeStaleEvidence(currentDate: currentDate)
        router.purgeStaleRoutes(currentDate: currentDate)
    }

    // MARK: - Export/Import

    func exportLinkStats() -> [LinkStatRecord] {
        linkEstimator.exportLinkStats()
    }

    func importLinkStats(_ records: [LinkStatRecord]) {
        #if DEBUG
        print("[NETROM:INTEGRATION] importLinkStats called with \(records.count) records")
        #endif
        linkEstimator.importLinkStats(records)
        #if DEBUG
        let exported = linkEstimator.exportLinkStats()
        print("[NETROM:INTEGRATION] After import, exportLinkStats returns \(exported.count) records")
        #endif
    }

    func importNeighbors(_ neighbors: [NeighborInfo]) {
        #if DEBUG
        print("[NETROM:INTEGRATION] importNeighbors called with \(neighbors.count) neighbors")
        #endif
        router.importNeighbors(neighbors)
        #if DEBUG
        let current = router.currentNeighbors()
        print("[NETROM:INTEGRATION] After import, currentNeighbors returns \(current.count) neighbors")
        #endif
    }

    func importRoutes(_ routes: [RouteInfo]) {
        #if DEBUG
        print("[NETROM:INTEGRATION] importRoutes called with \(routes.count) routes")
        #endif
        router.importRoutes(routes)
        #if DEBUG
        let current = router.currentRoutes()
        print("[NETROM:INTEGRATION] After import, currentRoutes returns \(current.count) routes")
        #endif
    }

    func exportNeighbors() -> [NeighborInfo] {
        router.currentNeighbors()
    }

    func exportRoutes() -> [RouteInfo] {
        router.currentRoutes()
    }

    // MARK: - Reset (Debug)

    /// Reset all routing state. Used by debug rebuild functionality.
    /// Creates fresh router and link estimator instances.
    func reset(localCallsign: String? = nil) {
        let callsign = localCallsign ?? self.localCallsign

        // Create fresh router
        let newRouter = NetRomRouter(localCallsign: callsign, config: routerConfig)

        // Replace the router reference - this requires making router a var
        // Since router is let, we need a different approach
        // We'll clear the existing data by importing empty arrays
        router.importNeighbors([])
        router.importRoutes([])

        // Create fresh link estimator
        linkEstimator = LinkQualityEstimator(config: linkConfig)

        // Recreate passive inference if needed
        if mode == .inference || mode == .hybrid {
            passiveInference = NetRomPassiveInference(
                router: router,
                localCallsign: callsign,
                config: inferenceConfig
            )
        }

        #if DEBUG
        print("[NETROM:INTEGRATION] Reset complete - cleared all neighbors, routes, and link stats")
        #endif
    }

    // MARK: - Private Helpers

    /// Calculate observed quality for a neighbor, optionally influenced by link quality.
    private func linkQualityForNeighbor(_ call: String) -> Int {
        let normalized = CallsignValidator.normalize(call)
        guard !normalized.isEmpty else { return routerConfig.neighborBaseQuality }

        // Get bidirectional link quality
        let forwardQuality = linkEstimator.linkQuality(from: normalized, to: localCallsign)
        let reverseQuality = linkEstimator.linkQuality(from: localCallsign, to: normalized)

        // If we have link quality observations, use the average
        if forwardQuality > 0 || reverseQuality > 0 {
            let avgQuality = max(forwardQuality, reverseQuality)
            // Blend with base quality to avoid cold start issues
            return max(routerConfig.neighborBaseQuality, avgQuality)
        }

        return routerConfig.neighborBaseQuality
    }
}
