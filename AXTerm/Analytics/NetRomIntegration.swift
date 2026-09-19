//
//  NetRomIntegration.swift
//  AXTerm
//
//  Created by Codex on 1/30/26.
//

import Combine
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
    let localCallsign: String
    private var mode: NetRomRoutingMode

    private let router: NetRomRouter
    private var passiveInference: NetRomPassiveInference?
    private var linkEstimator: LinkQualityEstimator
    /// One retry/duplicate tracker per radio. Two radios on one frequency
    /// each hear the same frame; the copy folded onto the second radio must
    /// not be judged against the first radio's sighting, or it is dropped as
    /// an ingestion artefact before it can count as that radio's evidence.
    private var duplicateTrackers: [RadioID: PacketDuplicateTracker] = [:]

    private let routerConfig: NetRomConfig
    private let inferenceConfig: NetRomInferenceConfig
    private let linkConfig: LinkQualityConfig
    
    // MARK: - Publishers
    
    private let updateSubject = PassthroughSubject<Void, Never>()
    
    /// Publishes when the integration state changes (e.g. new routing data, expiration)
    var didUpdate: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    /// Optional persistence for recording broadcast intervals (adaptive stale threshold).
    private weak var persistence: NetRomPersistence?


    init(
        localCallsign: String,
        mode: NetRomRoutingMode,
        routerConfig: NetRomConfig? = nil,
        inferenceConfig: NetRomInferenceConfig? = nil,
        linkConfig: LinkQualityConfig? = nil,
        persistence: NetRomPersistence? = nil
    ) {
        self.localCallsign = CallsignValidator.normalize(localCallsign)
        self.mode = mode
        
        let routerConfig = routerConfig ?? .default
        let inferenceConfig = inferenceConfig ?? .default
        let linkConfig = linkConfig ?? .default
        
        self.routerConfig = routerConfig
        self.inferenceConfig = inferenceConfig
        self.linkConfig = linkConfig
        self.persistence = persistence

        self.router = NetRomRouter(localCallsign: localCallsign, config: routerConfig)
        self.linkEstimator = LinkQualityEstimator(config: linkConfig)

        if mode == .inference || mode == .hybrid {
            self.passiveInference = NetRomPassiveInference(
                router: router,
                localCallsign: localCallsign,
                config: inferenceConfig
            )
        }

    }

    /// Set or update the persistence reference.
    func setPersistence(_ persistence: NetRomPersistence?) {
        self.persistence = persistence
    }

    // MARK: - Mode Management

    func setMode(_ newMode: NetRomRoutingMode) {
        guard mode != newMode else { return }
        // A mode switch changes routing semantics wholesale — always crumb it.
        Telemetry.breadcrumb(
            category: "netrom.routing",
            message: "Routing mode changed",
            data: ["from": String(describing: mode), "to": String(describing: newMode)],
            level: .info
        )
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
        let radio = packet.radioID ?? .primary
        var duplicateStatus = duplicateTrackers[radio, default: makeDuplicateTracker()].status(for: packet, at: timestamp)
        if isDuplicate && duplicateStatus != .ingestionDedup {
            duplicateStatus = .retryDuplicate
        }

        if duplicateStatus == .ingestionDedup {
            #if DEBUG
            appendTrace(packet, timestamp: timestamp, "dropped: ingestionDedup")
            #endif
            return
        }

        let baseClassification = PacketClassifier.classify(packet: packet)
        let classification: PacketClassification = duplicateStatus == .retryDuplicate ? .retryOrDuplicate : baseClassification
        #if DEBUG
        appendTrace(packet, timestamp: timestamp,
                    "dup=\(duplicateStatus) base=\(baseClassification) used=\(classification) mode=\(mode)")
        #endif

        // Always update link quality estimator
        linkEstimator.observePacket(
            packet,
            timestamp: timestamp,
            classification: classification,
            duplicateStatus: duplicateStatus
        )

        // Check for NET/ROM broadcast packets (PID 0xCF to NODES)
        // These are processed in all modes since they're explicit routing information
        if let broadcastResult = NetRomBroadcastParser.parse(packet: packet) {
            // Don't reinforce routing from retry/duplicate broadcasts.
            if classification != .retryOrDuplicate {
                processNetRomBroadcast(broadcastResult, classification: classification, radio: radio)
            }
            return // Don't double-process as regular packet
        }

        // Get current link quality for the sender
        let rawFrom = packet.from?.display ?? ""
        let normalizedFrom = CallsignValidator.normalize(rawFrom)
        let observedQuality = linkQualityForNeighbor(normalizedFrom)

        // allowedRouteSources deliberately excludes "harvested" (and "inferred")
        // in both branches below: hearing the anchor node on the air proves the
        // anchor is alive, not that the table we scraped from it is still true.
        // Harvested freshness renews only when a ROUTES listing is re-scraped.
        switch mode {
        case .classic:
            // Classic mode: only direct observations become neighbors
            if packet.via.isEmpty {
                applyRoutingFreshness(
                    packet: packet,
                    classification: classification,
                    observedQuality: observedQuality,
                    allowedRouteSources: Set(["classic", "broadcast"]),
                    timestamp: timestamp
                )
            }

        case .inference:
            // Inference mode: use passive inference for all observations
            passiveInference?.observePacket(packet, timestamp: timestamp, classification: classification, duplicateStatus: duplicateStatus)

        case .hybrid:
            // Hybrid mode: use both classic and inference
            if packet.via.isEmpty {
                applyRoutingFreshness(
                    packet: packet,
                    classification: classification,
                    observedQuality: observedQuality,
                    allowedRouteSources: Set(["classic", "broadcast"]),
                    timestamp: timestamp
                )
            }
            passiveInference?.observePacket(packet, timestamp: timestamp, classification: classification, duplicateStatus: duplicateStatus)
        }
    }

    /// Process a parsed NET/ROM broadcast, adding the sender as a neighbor and updating routes.
    private func processNetRomBroadcast(_ result: NetRomBroadcastResult, classification: PacketClassification,
                                        radio: RadioID = .primary) {
        let normalizedOrigin = CallsignValidator.normalize(result.originCallsign)
        guard !normalizedOrigin.isEmpty else { return }

        #if DEBUG
        print("[NETROM:INTEGRATION] Processing NET/ROM broadcast from \(normalizedOrigin) with \(result.entries.count) entries")
        #endif

        // Record broadcast for adaptive stale threshold calculation
        if let persistence = persistence {
            do {
                try persistence.recordBroadcast(from: normalizedOrigin, timestamp: result.timestamp)
                #if DEBUG
                print("[NETROM:INTEGRATION] ✅ Recorded broadcast from \(normalizedOrigin)")
                #endif
            } catch {
                #if DEBUG
                print("[NETROM:INTEGRATION] ❌ Failed to record broadcast: \(error)")
                #endif
            }
        } else {
            #if DEBUG
            print("[NETROM:INTEGRATION] ⚠️ Cannot record broadcast - persistence is nil")
            #endif
        }

        // First, ensure the broadcast sender is registered as a neighbor
        // NET/ROM broadcasts are always direct (no digipeating), so the sender is a neighbor.
        // Stamped with the radio that heard it, so the neighbour lands on the
        // right radio — and so `broadcastRoutes`' neighbour lookup, keyed by
        // (radio, origin), finds it and does not drop every route as "origin
        // is not a neighbour".
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
            infoText: nil,
            radioID: radio
        )

        // Register as neighbor with high quality (broadcast reception implies good link)
        if shouldRefreshNeighbor(for: classification) {
            let observedQuality = linkQualityForNeighbor(normalizedOrigin)
            router.observePacket(syntheticPacket, observedQuality: max(observedQuality, 200), direction: .incoming, timestamp: result.timestamp)
            router.markAsOfficial(call: normalizedOrigin, radio: radio)
        }

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

        // Process the broadcast routes through the router, on the radio that
        // heard the broadcast — its routes are reached through this radio.
        router.broadcastRoutes(
            from: normalizedOrigin,
            radio: radio,
            quality: 255, // Broadcast sender quality - actual route quality is in each entry
            destinations: routeInfos,
            timestamp: result.timestamp
        )
    }

    /// Process an explicit NET/ROM broadcast (classic routing).
    func broadcastRoutes(from origin: String, quality: Int, destinations: [RouteInfo], timestamp: Date) {
        router.broadcastRoutes(from: origin, quality: quality, destinations: destinations, timestamp: timestamp)
    }

    /// Session-scraped route knowledge (see HarvestedRoutePolicy).
    ///
    /// Same funnel as broadcasts on purpose: broadcastRoutes is the single
    /// place route learning is validated, scaled by our own link to the
    /// origin, and stored. The router silently drops claims from an origin
    /// that is not a neighbor — correct, since there is no link quality to
    /// scale by — but for harvested rows that silence would be baffling in
    /// the field (a session relayed through a digipeater harvests nothing),
    /// so the drop leaves a breadcrumb.
    func harvestedRoutes(from anchor: String, destinations: [RouteInfo], timestamp: Date) {
        guard !destinations.isEmpty else { return }
        let normalized = CallsignValidator.normalize(anchor)
        let isNeighbor = router.currentNeighbors().contains { $0.call == normalized }
        if !isNeighbor {
            Telemetry.breadcrumb(
                category: "netrom.harvest",
                message: "Harvested routes dropped — anchor is not a direct neighbor",
                data: ["anchor": normalized, "rows": destinations.count],
                level: .info
            )
        } else {
            Telemetry.breadcrumb(
                category: "netrom.harvest",
                message: "Routes harvested from a node's ROUTES table",
                data: [
                    "anchor": normalized,
                    "rows": destinations.count,
                    "destinations": destinations.map(\.destination).joined(separator: " ")
                ],
                level: .info
            )
        }
        router.broadcastRoutes(from: anchor, quality: 255, destinations: destinations, timestamp: timestamp)
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
    ///
    /// "harvested" routes (scraped from a node's own ROUTES listing) appear in
    /// hybrid mode only — deliberately. Classic mode is the protocol-faithful
    /// view and a scraped table is not protocol traffic; inference mode is the
    /// traffic-derived view and a scrape is not traffic. Hybrid already
    /// returns everything, so harvested rides along with no extra filter.
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

    func hasRoute(to destination: String) -> Bool {
        router.hasRoute(to: destination)
    }

    func bestRouteTo(_ destination: String) -> RouteInfo? {
        router.bestRouteTo(destination)
    }

    /// Every known next hop for a destination, best first — the attempt
    /// order for auto-try.
    func candidateRoutes(to destination: String) -> [RouteInfo] {
        router.candidateRoutes(to: destination)
    }

    func linkQuality(from: String, to: String, radio: RadioID = .primary) -> Int {
        linkEstimator.linkQuality(from: from, to: to, radio: radio)
    }

    func linkETX(from: String, to: String, radio: RadioID = .primary) -> Double? {
        linkEstimator.etx(from: from, to: to, radio: radio)
    }

    func effectiveTTL(from: String, to: String, radio: RadioID = .primary) -> TimeInterval {
        linkEstimator.effectiveTTL(from: from, to: to, radio: radio)
    }

    /// The radio a neighbor is best heard on, for choosing where a datagram
    /// to it should leave.
    func radio(forNeighbor call: String) -> RadioID? {
        router.radio(forNeighbor: call)
    }

    // MARK: - Maintenance

    func purgeStaleData(currentDate: Date) {
        linkEstimator.purgeStaleData(currentDate: currentDate)
        passiveInference?.purgeStaleEvidence(currentDate: currentDate)
        router.purgeStaleRoutes(currentDate: currentDate)
        updateSubject.send()
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

    // MARK: - Origin Interval Queries (Adaptive Stale Threshold)

    /// Get the estimated broadcast interval for a specific origin.
    ///
    /// - Parameter origin: The callsign of the origin station.
    /// - Returns: The interval info, or nil if no data exists.
    func getOriginInterval(for origin: String) -> OriginIntervalInfo? {
        guard let persistence = persistence else { return nil }
        return try? persistence.getOriginInterval(for: origin)
    }

    /// Get all tracked origin intervals.
    func getAllOriginIntervals() -> [OriginIntervalInfo] {
        guard let persistence = persistence else {
            #if DEBUG
            print("[NETROM:INTEGRATION] ⚠️ getAllOriginIntervals() - persistence is nil!")
            #endif
            return []
        }
        return (try? persistence.getAllOriginIntervals()) ?? []
    }

    #if DEBUG
    /// Test seam: one line per `observePacket`, for diagnosing inference that
    /// fails only under full-suite parallel load.
    ///
    /// Reading the code was not enough. Four inference tests in
    /// `NetRomIntegrationWiringTests` failed together once on 2026-09-19 and
    /// never again — not in ten fresh processes, not in eight further parallel
    /// full runs, and not in a single-process sequential run of all 7,213
    /// tests. Every gate on the path (the 0.25 s ingestion dedup, the 2 s retry
    /// window, the classifier, the 60-against-25 quality floor) reads as
    /// deterministic for those inputs, so the next occurrence needs the
    /// pipeline's own numbers rather than another reading of the source.
    private(set) var observationTrace: [String] = []

    private func appendTrace(_ packet: Packet, timestamp: Date, _ note: String) {
        guard AppEnvironment.isUnitTestHost, observationTrace.count < 1024 else { return }
        let from = packet.from?.display ?? "?"
        let to = packet.to?.display ?? "?"
        let via = packet.via.map { "\($0.display)\($0.repeated ? "*" : "")" }.joined(separator: ",")
        observationTrace.append(
            "t+\(Int(timestamp.timeIntervalSince1970) % 1000) \(from)>\(to)"
            + (via.isEmpty ? "" : " via \(via)") + " \(note)")
    }

    /// Everything the inference engine believes right now, in one line.
    var inferenceState: String {
        guard let passiveInference else { return "inference: off" }
        return passiveInference.debugEvidenceSummary
    }
    #endif

    // MARK: - Reset (Debug)

    /// Reset all routing state. Used by debug rebuild functionality.
    /// Creates fresh router and link estimator instances.
    private func makeDuplicateTracker() -> PacketDuplicateTracker {
        PacketDuplicateTracker(
            source: linkConfig.source,
            ingestionDedupWindow: linkConfig.ingestionDedupWindow,
            retryDuplicateWindow: linkConfig.retryDuplicateWindow
        )
    }

    func reset(localCallsign: String? = nil) {
        let callsign = localCallsign ?? self.localCallsign

        // Clear existing router data
        router.reset()

        // Create fresh link estimator
        linkEstimator = LinkQualityEstimator(config: linkConfig)
        duplicateTrackers.removeAll()

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

        // Use the average of the observed directions. The old code took the *max*
        // (discarding the worse direction) and floored the result at
        // neighborBaseQuality, so a neighbor could never read below ~80 no matter
        // how bad its link. Cold start is handled by the estimator's warm-up prior.
        if forwardQuality > 0 && reverseQuality > 0 {
            return (forwardQuality + reverseQuality) / 2
        }
        if forwardQuality > 0 { return forwardQuality }
        if reverseQuality > 0 { return reverseQuality }
        return routerConfig.neighborBaseQuality
    }

    private func applyRoutingFreshness(
        packet: Packet,
        classification: PacketClassification,
        observedQuality: Int,
        allowedRouteSources: Set<String>,
        timestamp: Date
    ) {
        let refreshNeighbor = shouldRefreshNeighbor(for: classification)
        let refreshRoutes = shouldRefreshRoute(for: classification)
        // The radio that heard this frame — its neighbours and routes are its
        // own. `router.observePacket` reads it from the packet; the route
        // refresh must be told, or it targets the primary radio's routes and
        // silently no-ops on the radio that actually heard the origin.
        let radio = packet.radioID ?? .primary

        if refreshNeighbor {
            router.observePacket(packet, observedQuality: observedQuality, direction: .incoming, timestamp: timestamp)
        }

        if refreshRoutes, let origin = packet.from?.display {
            router.refreshRoutes(from: origin, radio: radio, timestamp: timestamp, allowedSourceTypes: allowedRouteSources)
        }
    }

    private func shouldRefreshNeighbor(for classification: PacketClassification) -> Bool {
        switch classification {
        case .uiBeacon:
            return routerConfig.routingPolicy.uiBeaconRefreshesNeighbor
        case .routingBroadcast:
            return routerConfig.routingPolicy.routingBroadcastRefreshesNeighbor
        default:
            return classification.refreshesNeighbor
        }
    }

    private func shouldRefreshRoute(for classification: PacketClassification) -> Bool {
        switch classification {
        case .uiBeacon:
            return routerConfig.routingPolicy.uiBeaconRefreshesRoute
        default:
            return classification.refreshesRoute
        }
    }
}
