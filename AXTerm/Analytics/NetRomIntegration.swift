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

    private static var retainedForTests: [NetRomIntegration] = []

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

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            Self.retainedForTests.append(self)
        }
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

    /// Process an explicit NET/ROM broadcast (classic routing).
    func broadcastRoutes(from origin: String, quality: Int, destinations: [RouteInfo], timestamp: Date) {
        router.broadcastRoutes(from: origin, quality: quality, destinations: destinations, timestamp: timestamp)
    }

    // MARK: - Query Methods

    func currentNeighbors() -> [NeighborInfo] {
        router.currentNeighbors()
    }

    func currentRoutes() -> [RouteInfo] {
        router.currentRoutes()
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
        linkEstimator.importLinkStats(records)
    }

    func exportNeighbors() -> [NeighborInfo] {
        router.currentNeighbors()
    }

    func exportRoutes() -> [RouteInfo] {
        router.currentRoutes()
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
