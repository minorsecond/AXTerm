//
//  LinkQualityEstimator.swift
//  AXTerm
//
//  ETX-style link quality estimation for directional radio links.
//
//  The ETX (Expected Transmission Count) metric from De Couto/Roofnet lineage:
//    ETX = 1 / (df * dr)
//  where df = forward delivery probability and dr = reverse delivery probability.
//
//  Quality mapping: quality = clamp(round(255 / ETX), 0...255)
//
//  Since AX.25 often has UI-only frames (no ACK), dr is frequently unobservable.
//  We support partial observability:
//    1) Full ETX when both df and dr are estimable
//    2) Unidirectional fallback: assumes a conservative dr of 0.99 when dr is
//       unknown, so one-way evidence can never read as a fully confirmed link
//
//  EWMA smoothing ensures stability - quality doesn't spike from transient conditions.
//  Directionality is critical: A→B stats MUST NOT affect B→A unless explicit reverse evidence exists.
//
//  Investigation note (axterm.sqlite, 2026-01-31):
//  - link_stats rows showed quality=255 with dfEstimate=1.0, drEstimate=NULL, dupCount=0.
//  - importLinkStats previously reconstructed ewmaRatio from quality (255 => 1.0)
//    and quality used ewmaRatio directly, pegging quality at 255 regardless of ACK/retry evidence.
//  - df was derived only from duplicate ratios, and dr was never populated.
//  This rewrite uses control-aware evidence, time-based EWMA, and ETX mapping.
//

import Foundation

/// Configuration for link quality estimation.
nonisolated struct LinkQualityConfig: Equatable, Sendable {
    /// Capture source type for ingestion semantics.
    let source: CaptureSourceType

    /// Sliding window duration for observations (seconds).
    let slidingWindowSeconds: TimeInterval

    /// Half-life for forward EWMA (seconds).
    let forwardHalfLifeSeconds: TimeInterval

    /// Half-life for reverse EWMA (seconds).
    let reverseHalfLifeSeconds: TimeInterval

    /// Initial delivery ratio for cold-start links.
    let initialDeliveryRatio: Double

    /// Minimum delivery ratio used for ETX clamping.
    let minDeliveryRatio: Double

    /// Maximum ETX value used for quality mapping.
    let maxETX: Double

    /// Weight for reverse ACK progress from N(R).
    let ackProgressWeight: Double

    /// Maximum observations to retain per directional link (ring buffer bound).
    let maxObservationsPerLink: Int

    /// Whether to exclude service destinations (BEACON, ID, NODES, MAIL, etc.)
    /// from link quality edges. Default is true. Endpoints are accepted per
    /// `CallsignValidator.isValidRoutingNode`, so tactical aliases are tracked
    /// while service names, pseudo-paths, and corrupt garbage are not.
    let excludeServiceDestinations: Bool

    /// Multiplier for inter-arrival time → adaptive TTL (e.g. 6.0 means 6× avg inter-arrival).
    let adaptiveTTLMultiplier: Double

    /// Maximum adaptive TTL in seconds (cap for sparse links).
    let maxAdaptiveTTLSeconds: TimeInterval

    /// Ingestion de-duplication window (seconds).
    var ingestionDedupWindow: TimeInterval {
        source == .kiss ? 0.25 : 0.0
    }

    /// Retry duplicate window (seconds).
    var retryDuplicateWindow: TimeInterval { 2.0 }

    init(
        source: CaptureSourceType = .kiss,
        slidingWindowSeconds: TimeInterval,
        forwardHalfLifeSeconds: TimeInterval,
        reverseHalfLifeSeconds: TimeInterval,
        initialDeliveryRatio: Double,
        minDeliveryRatio: Double,
        maxETX: Double,
        ackProgressWeight: Double,
        maxObservationsPerLink: Int,
        excludeServiceDestinations: Bool = true,
        adaptiveTTLMultiplier: Double = 6.0,
        maxAdaptiveTTLSeconds: TimeInterval = 7200.0
    ) {
        self.source = source
        self.slidingWindowSeconds = slidingWindowSeconds
        self.forwardHalfLifeSeconds = forwardHalfLifeSeconds
        self.reverseHalfLifeSeconds = reverseHalfLifeSeconds
        self.initialDeliveryRatio = initialDeliveryRatio
        self.minDeliveryRatio = minDeliveryRatio
        self.maxETX = maxETX
        self.ackProgressWeight = ackProgressWeight
        self.maxObservationsPerLink = maxObservationsPerLink
        self.excludeServiceDestinations = excludeServiceDestinations
        self.adaptiveTTLMultiplier = adaptiveTTLMultiplier
        self.maxAdaptiveTTLSeconds = maxAdaptiveTTLSeconds
    }

    static let `default` = LinkQualityConfig(
        source: .kiss,
        slidingWindowSeconds: FreshnessCalculator.defaultTTL,
        forwardHalfLifeSeconds: 30 * 60,
        reverseHalfLifeSeconds: 30 * 60,
        initialDeliveryRatio: 0.5,
        minDeliveryRatio: 0.05,
        maxETX: 20.0,
        ackProgressWeight: 0.6,
        maxObservationsPerLink: 200,
        excludeServiceDestinations: true,
        adaptiveTTLMultiplier: 6.0,
        maxAdaptiveTTLSeconds: 7200.0
    )

    /// Generate a hash for config invalidation purposes.
    func configHash() -> String {
        "link_v4_\(source)_\(slidingWindowSeconds)_\(forwardHalfLifeSeconds)_\(reverseHalfLifeSeconds)_\(initialDeliveryRatio)_\(minDeliveryRatio)_\(maxETX)_\(ackProgressWeight)_\(maxObservationsPerLink)_\(excludeServiceDestinations)_\(adaptiveTTLMultiplier)_\(maxAdaptiveTTLSeconds)"
    }
}

/// Statistics for a directional link, exposed for testing and persistence.
nonisolated struct LinkStats: Equatable {
    /// Total observations within the sliding window.
    let observationCount: Int

    /// Number of duplicate/retry packets observed.
    let duplicateCount: Int

    /// Forward delivery probability estimate (0.0...1.0), nil if insufficient data.
    let dfEstimate: Double?

    /// Reverse delivery probability estimate (0.0...1.0), nil if no reverse direction data.
    let drEstimate: Double?

    /// Current EWMA-smoothed quality (0...255).
    let ewmaQuality: Int

    /// Timestamp of last observation.
    let lastUpdate: Date?

    /// Empty stats for unknown links.
    static let empty = LinkStats(
        observationCount: 0,
        duplicateCount: 0,
        dfEstimate: nil,
        drEstimate: nil,
        ewmaQuality: 0,
        lastUpdate: nil
    )
}

/// Record for persisting link statistics.
nonisolated struct LinkStatRecord: Equatable {
    let fromCall: String
    let toCall: String
    let quality: Int
    let lastUpdated: Date

    /// Forward delivery probability estimate, nil if unknown.
    let dfEstimate: Double?

    /// Reverse delivery probability estimate, nil if unknown.
    let drEstimate: Double?

    /// Count of duplicate/retry packets observed.
    let duplicateCount: Int

    /// Total observation count.
    let observationCount: Int

    init(fromCall: String, toCall: String, quality: Int, lastUpdated: Date, dfEstimate: Double? = nil, drEstimate: Double? = nil, duplicateCount: Int = 0, observationCount: Int = 0) {
        self.fromCall = fromCall
        self.toCall = toCall
        self.quality = quality
        self.lastUpdated = lastUpdated
        self.dfEstimate = dfEstimate
        self.drEstimate = drEstimate
        self.duplicateCount = duplicateCount
        self.observationCount = observationCount
    }
}

/// ETX-style link quality estimator with directional tracking and EWMA smoothing.
///
/// Key design principles:
/// - Directionality: A→B and B→A are tracked completely independently
/// - Bounded memory: Ring buffer limits per-link observation storage
/// - Determinism: Same inputs always produce same outputs (injectable clock)
/// - EWMA smoothing: Prevents quality spikes from transient conditions
nonisolated struct LinkQualityEstimator {
    let config: LinkQualityConfig

    /// Injectable clock for deterministic testing.
    private let clock: () -> Date

    /// Internal storage keyed by "FROM→TO".
    private var stats: [String: DirectionalLinkStats] = [:]

    init(config: LinkQualityConfig = .default, clock: @escaping () -> Date = { Date() }) {
        self.config = config
        self.clock = clock
    }

    /// Legacy observation entry point (used by existing tests).
    mutating func observePacket(_ packet: Packet, timestamp: Date, isDuplicate: Bool = false) {
        let classification = PacketClassifier.classify(packet: packet)
        let duplicateStatus: PacketDuplicateStatus = isDuplicate ? .retryDuplicate : .unique
        observePacket(packet, timestamp: timestamp, classification: classification, duplicateStatus: duplicateStatus)
    }

    /// Observe a packet transmission for link quality tracking.
    mutating func observePacket(
        _ packet: Packet,
        timestamp: Date,
        classification: PacketClassification,
        duplicateStatus: PacketDuplicateStatus = .unique
    ) {
        guard let rawFrom = packet.from?.display,
              let rawTo = packet.to?.display else { return }

        let from = CallsignValidator.normalize(rawFrom)
        let to = CallsignValidator.normalize(rawTo)
        guard !from.isEmpty, !to.isEmpty else { return }

        // Filter out service destinations (BEACON, ID, NODES, MAIL, etc.) if
        // configured. Endpoints are validated as routing nodes, not strict
        // callsigns: tactical aliases (DRLNOD, EATON…) are real stations, and
        // refusing them froze alias neighbor quality at the cold-start base
        // because their links never accumulated df/dr evidence.
        if config.excludeServiceDestinations {
            guard CallsignValidator.isValidRoutingNode(from),
                  CallsignValidator.isValidRoutingNode(to) else {
                return
            }
        }

        // Ignore ingestion-level dedup artifacts
        if duplicateStatus == .ingestionDedup { return }

        let decoded = packet.controlFieldDecoded
        let key = "\(from)→\(to)"
        var s = stats[key] ?? DirectionalLinkStats(
            lastUpdated: timestamp,
            observations: RingBuffer(capacity: config.maxObservationsPerLink)
        )

        // A REJ/SREJ from A reports a missed I-frame FROM B: it is loss
        // evidence for the B→A direction, not for its own sender's link
        // (the classifier folds it into .retryOrDuplicate, so exclude it here).
        let isRejectNotice = decoded.sType == .REJ || decoded.sType == .SREJ
        let isRetry = duplicateStatus == .retryDuplicate
            || (classification == .retryOrDuplicate && !isRejectNotice)
        // UA and DM are solicited responses: either one proves the peer HEARD
        // the SABM/DISC that provoked it — direct forward-delivery proof for
        // the frame's original sender (field capture 2026-08-23: a successful
        // SABM/UA handshake left df=0.0 because the UA carried no weight).
        let isConnectionResponse = decoded.uType == .UA || decoded.uType == .DM

        // Forward evidence (data progress / routing broadcast / UI beacon).
        if classification.forwardEvidenceWeight > 0 && !isRetry {
            s.addObservation(
                channel: .forward,
                value: classification.forwardEvidenceWeight,
                timestamp: timestamp,
                isDuplicate: false,
                config: config
            )
        }

        // Retry / duplicate penalty.
        if isRetry {
            s.addObservation(
                channel: .forward,
                value: 0.0,
                timestamp: timestamp,
                isDuplicate: true,
                config: config
            )
        }

        // Reject notices penalize the direction whose I-frame was lost.
        if isRejectNotice && !isRetry {
            applyDirectionalForward(
                from: to, to: from,
                value: 0.0,
                timestamp: timestamp
            )
        }

        // Connection responses credit the handshake initiator's forward channel.
        if isConnectionResponse && !isRetry {
            applyDirectionalForward(
                from: to, to: from,
                value: 0.8,
                timestamp: timestamp
            )
        }

        // Track N(R) for ACK progress and apply reverse evidence to the opposite direction.
        if let nr = decoded.nr, s.recordNrProgress(nr) {
            applyReverseEvidence(
                from: to,
                to: from,
                value: config.ackProgressWeight,
                timestamp: timestamp
            )
        }

        // ACK-only frames provide reverse delivery evidence for the opposite direction.
        if classification.reverseEvidenceWeight > 0 {
            applyReverseEvidence(
                from: to,
                to: from,
                value: classification.reverseEvidenceWeight,
                timestamp: timestamp
            )
        }

        stats[key] = s
    }

    /// Get the current quality estimate for a directional link (0...255).
    func linkQuality(from: String, to: String) -> Int {
        let key = "\(CallsignValidator.normalize(from))→\(CallsignValidator.normalize(to))"
        guard let s = stats[key] else { return 0 }
        return s.quality(using: config)
    }

    /// Get detailed statistics for a directional link.
    func linkStats(from: String, to: String) -> LinkStats {
        let key = "\(CallsignValidator.normalize(from))→\(CallsignValidator.normalize(to))"
        guard let s = stats[key] else { return .empty }
        return s.toLinkStats(using: config)
    }

    /// Get symmetric link quality if both directions have evidence, nil otherwise.
    /// Uses the geometric mean of both directions (ETX combines multiplicatively).
    func symmetricLinkQuality(a: String, b: String) -> Int? {
        let normalizedA = CallsignValidator.normalize(a)
        let normalizedB = CallsignValidator.normalize(b)

        let keyAB = "\(normalizedA)→\(normalizedB)"
        let keyBA = "\(normalizedB)→\(normalizedA)"

        guard let statsAB = stats[keyAB], statsAB.hasEvidence,
              let statsBA = stats[keyBA], statsBA.hasEvidence else {
            return nil
        }

        // Use geometric mean for symmetric quality (ETX combines multiplicatively)
        let qualityAB = Double(statsAB.quality(using: config))
        let qualityBA = Double(statsBA.quality(using: config))
        let symmetric = sqrt(qualityAB * qualityBA)
        return min(255, max(0, Int(symmetric.rounded())))
    }

    /// Compute the effective TTL for a directional link based on its inter-arrival pattern.
    func effectiveTTL(from: String, to: String) -> TimeInterval {
        let key = "\(CallsignValidator.normalize(from))→\(CallsignValidator.normalize(to))"
        guard let s = stats[key] else { return config.slidingWindowSeconds }
        return s.effectiveTTL(using: config)
    }

    /// Purge observations older than the per-link effective TTL.
    /// Uses two-phase tombstone expiry: entries without evidence are tombstoned first,
    /// then removed after the tombstone window elapses.
    mutating func purgeStaleData(currentDate: Date) {
        var keysToRemove: [String] = []

        for (key, var s) in stats {
            let linkTTL = s.effectiveTTL(using: config)
            let cutoff = currentDate.addingTimeInterval(-linkTTL)
            s.pruneOld(cutoff: cutoff)

            if !s.hasEvidence {
                if s.tombstonedAt == nil {
                    // Phase 1: Enter tombstone state
                    s.tombstonedAt = currentDate
                    s.forwardEstimate = nil
                    s.reverseEstimate = nil
                    stats[key] = s
                } else {
                    // Phase 2: Check if tombstone window has elapsed
                    let tombstoneAge = currentDate.timeIntervalSince(s.tombstonedAt!)
                    if tombstoneAge >= linkTTL {
                        keysToRemove.append(key)
                    } else {
                        stats[key] = s
                    }
                }
            } else {
                // Has evidence — ensure not tombstoned
                s.tombstonedAt = nil
                stats[key] = s
            }
        }

        for key in keysToRemove {
            stats.removeValue(forKey: key)
        }
    }

    /// Export current link statistics for persistence.
    func exportLinkStats() -> [LinkStatRecord] {
        let now = clock()
        return stats
            .compactMap { (key, s) -> LinkStatRecord? in
                let parts = key.components(separatedBy: "→")
                guard parts.count == 2 else { return nil }
                let linkStats = s.toLinkStats(using: config)

                // Skip entries with no evidence — these were touched by a packet
                // but never accumulated qualifying observations (e.g., only S-frames
                // or all observations expired from the sliding window).
                guard linkStats.observationCount > 0 || linkStats.dfEstimate != nil else {
                    return nil
                }

                // Never export Date.distantPast - use current time as fallback
                let timestamp = linkStats.lastUpdate ?? now
                let sanitizedTimestamp = Self.sanitizeTimestamp(timestamp, fallback: now)

                return LinkStatRecord(
                    fromCall: parts[0],
                    toCall: parts[1],
                    quality: linkStats.ewmaQuality,
                    lastUpdated: sanitizedTimestamp,
                    dfEstimate: linkStats.dfEstimate,
                    drEstimate: linkStats.drEstimate,
                    duplicateCount: linkStats.duplicateCount,
                    observationCount: linkStats.observationCount
                )
            }
            .sorted { ($0.fromCall, $0.toCall) < ($1.fromCall, $1.toCall) }
    }

    /// Import link statistics from persistence.
    mutating func importLinkStats(_ records: [LinkStatRecord]) {
        let now = clock()

        #if DEBUG
        var sanitizedCount = 0
        var importedCount = 0
        #endif

        for record in records {
            let key = "\(record.fromCall)→\(record.toCall)"
            let sanitizedTimestamp = Self.sanitizeTimestamp(record.lastUpdated, fallback: now)
            let restoredForward = record.dfEstimate ?? (Double(record.quality) / 255.0)

            #if DEBUG
            if record.lastUpdated != sanitizedTimestamp {
                sanitizedCount += 1
            }
            importedCount += 1
            #endif

            stats[key] = DirectionalLinkStats(
                lastUpdated: sanitizedTimestamp,
                observations: RingBuffer(capacity: config.maxObservationsPerLink),
                restoredForwardEstimate: restoredForward,
                restoredReverseEstimate: record.drEstimate,
                restoredObservationCount: record.observationCount,
                restoredDuplicateCount: record.duplicateCount,
                restoredQuality: record.quality
            )
        }

        #if DEBUG
        if sanitizedCount > 0 {
            print("[LINKQUALITY] importLinkStats: sanitized \(sanitizedCount)/\(importedCount) invalid timestamps (Date.distantPast)")
        }
        #endif
    }

    // MARK: - Private Helpers

    /// Add forward-channel evidence to an arbitrary directional link — used
    /// when a frame carries evidence about the OPPOSITE direction (a UA
    /// proving the SABM arrived, a REJ proving an inbound I-frame was lost).
    private mutating func applyDirectionalForward(from: String, to: String, value: Double, timestamp: Date) {
        let key = "\(from)\u{2192}\(to)"
        var s = stats[key] ?? DirectionalLinkStats(
            lastUpdated: timestamp,
            observations: RingBuffer(capacity: config.maxObservationsPerLink)
        )
        s.addObservation(
            channel: .forward,
            value: value,
            timestamp: timestamp,
            isDuplicate: false,
            config: config
        )
        stats[key] = s
    }

    private mutating func applyReverseEvidence(from: String, to: String, value: Double, timestamp: Date) {
        let reverseKey = "\(from)→\(to)"
        var reverseStats = stats[reverseKey] ?? DirectionalLinkStats(
            lastUpdated: timestamp,
            observations: RingBuffer(capacity: config.maxObservationsPerLink)
        )
        reverseStats.addObservation(
            channel: .reverse,
            value: value,
            timestamp: timestamp,
            isDuplicate: false,
            config: config
        )
        stats[reverseKey] = reverseStats
    }

    // MARK: - Timestamp Helpers

    /// Sanitize a timestamp - replace Date.distantPast or dates more than 1 year old with the fallback.
    private static func sanitizeTimestamp(_ date: Date, fallback: Date) -> Date {
        if date == Date.distantPast { return fallback }
        if date.timeIntervalSince1970 <= 0 { return fallback }
        return date
    }
}

// MARK: - Internal Types

/// Ring buffer for bounded observation storage.
nonisolated private struct RingBuffer<T> {
    private var storage: [T] = []
    private var writeIndex: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func append(_ element: T) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[writeIndex] = element
            writeIndex = (writeIndex + 1) % capacity
        }
    }

    /// Get all elements (not necessarily in insertion order after wrap).
    var elements: [T] { storage }

    /// Remove elements matching a predicate.
    mutating func removeAll(where predicate: (T) -> Bool) {
        storage.removeAll(where: predicate)
        writeIndex = storage.count % max(1, capacity)
    }
}

nonisolated private enum EvidenceChannel {
    case forward
    case reverse
}

nonisolated private struct Observation {
    let timestamp: Date
    let channel: EvidenceChannel
    let isDuplicate: Bool
}

/// Statistics for a single directional link (A→B).
nonisolated private struct DirectionalLinkStats {
    /// EWMA-smoothed forward delivery ratio (0.0...1.0).
    var forwardEstimate: Double?

    /// EWMA-smoothed reverse delivery ratio (0.0...1.0).
    var reverseEstimate: Double?

    /// Timestamp of last observation.
    var lastUpdated: Date

    /// Timestamp of last forward observation.
    var lastForwardUpdate: Date?

    /// Timestamp of last reverse observation.
    var lastReverseUpdate: Date?

    /// Last observed N(R) for ACK progress detection.
    var lastNr: Int?

    /// Ring buffer of recent observations.
    var observations: RingBuffer<Observation>

    // Restored values from persistence (used when observations ring buffer is empty after import)
    var restoredForwardEstimate: Double?
    var restoredReverseEstimate: Double?
    var restoredObservationCount: Int
    var restoredDuplicateCount: Int
    /// Lifetime evidence credit transferred from restored state when live
    /// observations resume — restarts must not re-darken minObs gates.
    var carriedObservationCount: Int = 0
    var carriedDuplicateCount: Int = 0
    var restoredQuality: Int?

    /// EWMA sample counts per channel, seeded at 1 for the cold-start prior.
    /// Early samples blend with a count-based alpha (running mean) so a single
    /// packet cannot claim df = 1.0; the time-based alpha takes over as evidence
    /// accumulates.
    var forwardSampleCount: Int = 1
    var reverseSampleCount: Int = 1

    /// Average inter-arrival time for forward observations (EWMA-smoothed, seconds).
    var avgInterArrivalSeconds: Double?

    /// Count of forward arrivals used for adaptive TTL (need ≥3 for reliable estimate).
    var arrivalCount: Int = 0

    /// When set, this link is in tombstone state (no evidence but retained for potential revival).
    var tombstonedAt: Date?

    init(
        lastUpdated: Date,
        observations: RingBuffer<Observation>,
        restoredForwardEstimate: Double? = nil,
        restoredReverseEstimate: Double? = nil,
        restoredObservationCount: Int = 0,
        restoredDuplicateCount: Int = 0,
        restoredQuality: Int? = nil
    ) {
        self.forwardEstimate = nil
        self.reverseEstimate = nil
        self.lastUpdated = lastUpdated
        self.lastForwardUpdate = nil
        self.lastReverseUpdate = nil
        self.lastNr = nil
        self.observations = observations
        self.restoredForwardEstimate = restoredForwardEstimate
        self.restoredReverseEstimate = restoredReverseEstimate
        self.restoredObservationCount = restoredObservationCount
        self.restoredDuplicateCount = restoredDuplicateCount
        self.restoredQuality = restoredQuality
        // Restored evidence counts toward the EWMA warm-up (plus the prior), so an
        // imported link continues where it left off instead of re-warming from
        // scratch — and incremental replay matches a full recompute exactly.
        if restoredForwardEstimate != nil {
            self.forwardSampleCount = restoredObservationCount + 1
        }
        if restoredReverseEstimate != nil {
            self.reverseSampleCount = restoredObservationCount + 1
        }
    }

    var hasEvidence: Bool {
        observations.count > 0 || restoredObservationCount > 0
    }

    /// Add an observation and update EWMA.
    mutating func addObservation(
        channel: EvidenceChannel,
        value: Double,
        timestamp: Date,
        isDuplicate: Bool,
        config: LinkQualityConfig
    ) {
        observations.append(Observation(timestamp: timestamp, channel: channel, isDuplicate: isDuplicate))
        lastUpdated = timestamp

        // Revive from tombstone if new evidence arrives
        tombstonedAt = nil

        // Seed the live EWMA from persisted state before clearing it — otherwise the
        // first observation after an import throws away everything the link had
        // learned and restarts from the cold-start prior.
        if forwardEstimate == nil, let restoredForwardEstimate {
            forwardEstimate = clamp01(restoredForwardEstimate)
        }
        if reverseEstimate == nil, let restoredReverseEstimate {
            reverseEstimate = clamp01(restoredReverseEstimate)
        }

        // Clear restored values once we have real observations — but carry the
        // evidence-count credit forward: the estimates seed the live EWMAs, and
        // the observation count must survive the same way or every restart
        // re-darkens the minObs gates downstream (field capture 2026-08-23:
        // K0NTS-1→N3HYM-15 dropped 7→1 on the first post-restart frame).
        carriedObservationCount += restoredObservationCount
        carriedDuplicateCount += restoredDuplicateCount
        restoredForwardEstimate = nil
        restoredReverseEstimate = nil
        restoredObservationCount = 0
        restoredDuplicateCount = 0
        restoredQuality = nil

        switch channel {
        case .forward:
            let previous = lastForwardUpdate

            // Track inter-arrival time for adaptive TTL
            if let previous, !isDuplicate {
                let gap = timestamp.timeIntervalSince(previous)
                if gap > 0.5 { // Ignore sub-second dupes
                    let alpha = 0.3
                    if let current = avgInterArrivalSeconds {
                        avgInterArrivalSeconds = (1.0 - alpha) * current + alpha * gap
                    } else {
                        avgInterArrivalSeconds = gap
                    }
                }
            }
            // Retries are not fresh arrivals — counting them inflated the
            // adaptive-TTL arrival gate.
            if !isDuplicate {
                arrivalCount += 1
            }

            forwardEstimate = updateEWMA(
                current: forwardEstimate ?? config.initialDeliveryRatio,
                value: clamp01(value),
                previousTimestamp: previous,
                timestamp: timestamp,
                halfLife: config.forwardHalfLifeSeconds,
                sampleCount: forwardSampleCount
            )
            forwardSampleCount += 1
            lastForwardUpdate = timestamp
        case .reverse:
            let previous = lastReverseUpdate
            reverseEstimate = updateEWMA(
                current: reverseEstimate ?? config.initialDeliveryRatio,
                value: clamp01(value),
                previousTimestamp: previous,
                timestamp: timestamp,
                halfLife: config.reverseHalfLifeSeconds,
                sampleCount: reverseSampleCount
            )
            reverseSampleCount += 1
            lastReverseUpdate = timestamp
        }
    }

    /// Track N(R) progress for ACK-based reverse evidence.
    mutating func recordNrProgress(_ nr: Int) -> Bool {
        defer { lastNr = nr }
        guard let lastNr else { return false }
        return nr != lastNr
    }

    /// Compute the effective TTL for this link based on inter-arrival pattern.
    func effectiveTTL(using config: LinkQualityConfig) -> TimeInterval {
        guard arrivalCount >= 3, let avg = avgInterArrivalSeconds else {
            return config.slidingWindowSeconds
        }
        let adaptiveTTL = config.adaptiveTTLMultiplier * avg
        return min(config.maxAdaptiveTTLSeconds, max(config.slidingWindowSeconds, adaptiveTTL))
    }

    /// Remove observations older than cutoff.
    mutating func pruneOld(cutoff: Date) {
        observations.removeAll { $0.timestamp < cutoff }
    }

    /// Convert to public LinkStats.
    func toLinkStats(using config: LinkQualityConfig) -> LinkStats {
        let liveTotal = observations.count
        let liveDups = observations.elements.filter { $0.isDuplicate }.count

        let total: Int
        let dups: Int
        let df: Double?
        let dr: Double?

        if liveTotal > 0 {
            total = liveTotal + carriedObservationCount
            dups = liveDups + carriedDuplicateCount
            df = forwardEstimate
            dr = reverseEstimate
        } else if restoredObservationCount > 0 {
            total = restoredObservationCount
            dups = restoredDuplicateCount
            df = restoredForwardEstimate
            dr = restoredReverseEstimate
        } else {
            total = 0
            dups = 0
            df = nil
            dr = nil
        }

        return LinkStats(
            observationCount: total,
            duplicateCount: dups,
            dfEstimate: df,
            drEstimate: dr,
            ewmaQuality: quality(using: config),
            lastUpdate: lastUpdated
        )
    }

    /// Quality scaled to 0...255 using ETX mapping.
    func quality(using config: LinkQualityConfig) -> Int {
        // If we have no live observations but have restored quality from persistence, use it directly.
        // This preserves imported quality values until new evidence arrives.
        if observations.count == 0, let restoredQuality {
            return min(255, max(0, restoredQuality))
        }

        guard let df = effectiveForwardEstimate(config: config) else { return 0 }
        let dr = effectiveReverseEstimate()
        let etx = Self.etx(df: df, dr: dr, config: config)
        let q = 255.0 / etx
        return min(255, max(0, Int(q.rounded())))
    }

    private func effectiveForwardEstimate(config: LinkQualityConfig) -> Double? {
        if let forwardEstimate { return clamp01(forwardEstimate) }
        if let restoredForwardEstimate { return clamp01(restoredForwardEstimate) }
        return nil
    }

    private func effectiveReverseEstimate() -> Double? {
        if let reverseEstimate { return clamp01(reverseEstimate) }
        if let restoredReverseEstimate { return clamp01(restoredReverseEstimate) }
        return nil
    }

    private static func etx(df: Double, dr: Double?, config: LinkQualityConfig) -> Double {
        if let dr {
            let product = max(config.minDeliveryRatio, df) * max(config.minDeliveryRatio, dr)
            return min(config.maxETX, max(1.0, 1.0 / product))
        }
        // When dr is unknown, apply a small penalty to indicate unconfirmed reverse path.
        // Use 0.99 as a conservative dr estimate - high enough to preserve reasonable quality
        // for good links, but ensures quality is never exactly 255 without reverse evidence.
        let dfClamped = max(config.minDeliveryRatio, df)
        let drConservative = 0.99
        let product = dfClamped * drConservative
        return min(config.maxETX, max(1.0, 1.0 / product))
    }

    /// Time-based EWMA with warm-up correction.
    ///
    /// The effective alpha is `max(timeAlpha, 1/(sampleCount + 1))`. The
    /// count-based term makes the early estimate a running mean seeded by the
    /// `initialDeliveryRatio` prior — one packet yields 0.75, not a hard 1.0 —
    /// while enough samples let the Δt-based term (λ = 1 − exp(−Δt/H)) dominate,
    /// as specified in CLAUDE.md §8.
    private func updateEWMA(
        current: Double,
        value: Double,
        previousTimestamp: Date?,
        timestamp: Date,
        halfLife: TimeInterval,
        sampleCount: Int
    ) -> Double {
        let timeAlpha: Double
        if let previousTimestamp {
            let delta = max(0.0, timestamp.timeIntervalSince(previousTimestamp))
            if halfLife <= 0 {
                timeAlpha = 1.0
            } else {
                timeAlpha = 1.0 - exp(-delta / halfLife)
            }
        } else {
            timeAlpha = 0.0
        }
        let countAlpha = 1.0 / Double(max(1, sampleCount) + 1)
        let alpha = max(timeAlpha, countAlpha)
        let blended = (1.0 - alpha) * current + alpha * value
        return clamp01(blended)
    }

    private func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
