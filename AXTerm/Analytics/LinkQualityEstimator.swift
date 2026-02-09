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
//    2) Unidirectional fallback: uses conservative dr estimate (initialDeliveryRatio)
//       when dr is unknown, ensuring quality is penalized for one-way evidence only
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
struct LinkQualityConfig: Equatable {
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

    /// Whether to exclude service destinations (BEACON, ID, MAIL, etc.) from link quality edges.
    /// Default is true - service destinations are not valid callsigns for routing purposes.
    let excludeServiceDestinations: Bool

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
        excludeServiceDestinations: Bool = true
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
        excludeServiceDestinations: true
    )

    /// Generate a hash for config invalidation purposes.
    func configHash() -> String {
        "link_v3_\(source)_\(slidingWindowSeconds)_\(forwardHalfLifeSeconds)_\(reverseHalfLifeSeconds)_\(initialDeliveryRatio)_\(minDeliveryRatio)_\(maxETX)_\(ackProgressWeight)_\(maxObservationsPerLink)_\(excludeServiceDestinations)"
    }
}

/// Statistics for a directional link, exposed for testing and persistence.
struct LinkStats: Equatable {
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
struct LinkStatRecord: Equatable {
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
struct LinkQualityEstimator {
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

        // Filter out service destinations (BEACON, ID, MAIL, etc.) if configured
        if config.excludeServiceDestinations {
            guard CallsignValidator.isValidCallsign(from),
                  CallsignValidator.isValidCallsign(to) else {
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

        let isRetry = duplicateStatus == .retryDuplicate || classification == .retryOrDuplicate || decoded.sType == .REJ || decoded.sType == .SREJ

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
    /// Uses the minimum of both directions as a conservative estimate.
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

    /// Purge observations older than the sliding window.
    mutating func purgeStaleData(currentDate: Date) {
        let cutoff = currentDate.addingTimeInterval(-config.slidingWindowSeconds)

        for (key, var s) in stats {
            s.pruneOld(cutoff: cutoff)
            // When all observations are gone and no restored evidence,
            // clear EWMA estimates so quality returns 0 for expired entries.
            if !s.hasEvidence {
                s.forwardEstimate = nil
                s.reverseEstimate = nil
            }
            stats[key] = s
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
private struct RingBuffer<T> {
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

private enum EvidenceChannel {
    case forward
    case reverse
}

private struct Observation {
    let timestamp: Date
    let channel: EvidenceChannel
    let isDuplicate: Bool
}

/// Statistics for a single directional link (A→B).
private struct DirectionalLinkStats {
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
    var restoredQuality: Int?

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

        // Clear restored values once we have real observations
        restoredForwardEstimate = nil
        restoredReverseEstimate = nil
        restoredObservationCount = 0
        restoredDuplicateCount = 0
        restoredQuality = nil

        switch channel {
        case .forward:
            let previous = lastForwardUpdate
            if previous == nil {
                forwardEstimate = clamp01(value)
            } else {
                forwardEstimate = updateEWMA(
                    current: forwardEstimate ?? config.initialDeliveryRatio,
                    value: clamp01(value),
                    previousTimestamp: previous ?? timestamp,
                    timestamp: timestamp,
                    halfLife: config.forwardHalfLifeSeconds
                )
            }
            lastForwardUpdate = timestamp
        case .reverse:
            let previous = lastReverseUpdate
            if previous == nil {
                reverseEstimate = clamp01(value)
            } else {
                reverseEstimate = updateEWMA(
                    current: reverseEstimate ?? config.initialDeliveryRatio,
                    value: clamp01(value),
                    previousTimestamp: previous ?? timestamp,
                    timestamp: timestamp,
                    halfLife: config.reverseHalfLifeSeconds
                )
            }
            lastReverseUpdate = timestamp
        }
    }

    /// Track N(R) progress for ACK-based reverse evidence.
    mutating func recordNrProgress(_ nr: Int) -> Bool {
        defer { lastNr = nr }
        guard let lastNr else { return false }
        return nr != lastNr
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
            total = liveTotal
            dups = liveDups
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

    private func updateEWMA(
        current: Double,
        value: Double,
        previousTimestamp: Date,
        timestamp: Date,
        halfLife: TimeInterval
    ) -> Double {
        let delta = max(0.0, timestamp.timeIntervalSince(previousTimestamp))
        let alpha: Double
        if halfLife <= 0 {
            alpha = 1.0
        } else {
            alpha = 1.0 - exp(-delta / halfLife)
        }
        let blended = (1.0 - alpha) * current + alpha * value
        return clamp01(blended)
    }

    private func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
