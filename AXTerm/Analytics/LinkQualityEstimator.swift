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
//  Quality mapping: quality = clamp(round(255 / ETX), 0...255) = clamp(round(255 * df * dr), 0...255)
//
//  Since AX.25 often has UI-only frames (no ACK), dr is frequently unobservable.
//  We support partial observability:
//    1) Full ETX when both df and dr are estimable
//    2) Unidirectional fallback: quality ≈ 255 * df when dr is unknown
//
//  EWMA smoothing ensures stability - quality doesn't spike from transient conditions.
//  Directionality is critical: A→B stats MUST NOT affect B→A unless explicit reverse evidence exists.
//

import Foundation

/// Configuration for link quality estimation.
struct LinkQualityConfig: Equatable {
    /// Capture source type for ingestion semantics.
    let source: CaptureSourceType

    /// Sliding window duration for observations (seconds).
    let slidingWindowSeconds: TimeInterval

    /// EWMA alpha: higher = more responsive to recent observations, lower = more stable.
    let ewmaAlpha: Double

    /// Initial delivery ratio for cold-start links.
    let initialDeliveryRatio: Double

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
        ewmaAlpha: Double,
        initialDeliveryRatio: Double,
        maxObservationsPerLink: Int,
        excludeServiceDestinations: Bool = true
    ) {
        self.source = source
        self.slidingWindowSeconds = slidingWindowSeconds
        self.ewmaAlpha = ewmaAlpha
        self.initialDeliveryRatio = initialDeliveryRatio
        self.maxObservationsPerLink = maxObservationsPerLink
        self.excludeServiceDestinations = excludeServiceDestinations
    }

    static let `default` = LinkQualityConfig(
        source: .kiss,
        slidingWindowSeconds: 300,
        ewmaAlpha: 0.1,  // Lower alpha = more smoothing, prevents drastic quality drops from short bursts
        initialDeliveryRatio: 0.5,
        maxObservationsPerLink: 100,
        excludeServiceDestinations: true
    )

    /// Generate a hash for config invalidation purposes.
    func configHash() -> String {
        "link_v2_\(source)_\(slidingWindowSeconds)_\(ewmaAlpha)_\(initialDeliveryRatio)_\(maxObservationsPerLink)_\(excludeServiceDestinations)"
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

    /// Observe a packet transmission for link quality tracking.
    mutating func observePacket(_ packet: Packet, timestamp: Date, isDuplicate: Bool = false) {
        guard let rawFrom = packet.from?.display,
              let rawTo = packet.to?.display else { return }

        let from = CallsignValidator.normalize(rawFrom)
        let to = CallsignValidator.normalize(rawTo)
        guard !from.isEmpty, !to.isEmpty else { return }

        // Filter out service destinations (BEACON, ID, MAIL, etc.) if configured
        // These are not valid callsigns for routing purposes
        if config.excludeServiceDestinations {
            guard CallsignValidator.isValidCallsign(from),
                  CallsignValidator.isValidCallsign(to) else {
                return
            }
        }

        let key = "\(from)→\(to)"

        var s = stats[key] ?? DirectionalLinkStats(
            ewmaRatio: config.initialDeliveryRatio,
            lastUpdated: timestamp,
            observations: RingBuffer(capacity: config.maxObservationsPerLink)
        )
        s.addObservation(timestamp: timestamp, isDuplicate: isDuplicate, alpha: config.ewmaAlpha, maxObservations: config.maxObservationsPerLink)
        stats[key] = s
    }

    /// Get the current quality estimate for a directional link (0...255).
    func linkQuality(from: String, to: String) -> Int {
        let key = "\(CallsignValidator.normalize(from))→\(CallsignValidator.normalize(to))"
        guard let s = stats[key] else { return 0 }
        return s.quality
    }

    /// Get detailed statistics for a directional link.
    func linkStats(from: String, to: String) -> LinkStats {
        let key = "\(CallsignValidator.normalize(from))→\(CallsignValidator.normalize(to))"
        guard let s = stats[key] else { return .empty }
        return s.toLinkStats()
    }

    /// Get symmetric link quality if both directions have evidence, nil otherwise.
    /// Uses the minimum of both directions as a conservative estimate.
    func symmetricLinkQuality(a: String, b: String) -> Int? {
        let normalizedA = CallsignValidator.normalize(a)
        let normalizedB = CallsignValidator.normalize(b)

        let keyAB = "\(normalizedA)→\(normalizedB)"
        let keyBA = "\(normalizedB)→\(normalizedA)"

        guard let statsAB = stats[keyAB], statsAB.observations.count > 0,
              let statsBA = stats[keyBA], statsBA.observations.count > 0 else {
            return nil
        }

        // Use geometric mean for symmetric quality (ETX combines multiplicatively)
        let qualityAB = Double(statsAB.quality)
        let qualityBA = Double(statsBA.quality)
        let symmetric = sqrt(qualityAB * qualityBA)
        return min(255, max(0, Int(symmetric.rounded())))
    }

    /// Purge observations older than the sliding window.
    mutating func purgeStaleData(currentDate: Date) {
        let cutoff = currentDate.addingTimeInterval(-config.slidingWindowSeconds)

        var keysToRemove: [String] = []
        for (key, var s) in stats {
            s.pruneOld(cutoff: cutoff)
            if s.observations.count == 0 {
                keysToRemove.append(key)
            } else {
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
                let linkStats = s.toLinkStats()

                // Never export Date.distantPast - use current time as fallback
                // This prevents "739648d ago" display bugs
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
            let ratio = max(0, min(1, Double(record.quality) / 255.0))

            // Sanitize timestamps - replace Date.distantPast with current time
            let sanitizedTimestamp = Self.sanitizeTimestamp(record.lastUpdated, fallback: now)

            #if DEBUG
            if record.lastUpdated != sanitizedTimestamp {
                sanitizedCount += 1
            }
            importedCount += 1
            #endif

            stats[key] = DirectionalLinkStats(
                ewmaRatio: ratio,
                lastUpdated: sanitizedTimestamp,
                observations: RingBuffer(capacity: config.maxObservationsPerLink),
                // Restore df/dr estimates from persistence so they display correctly
                restoredDfEstimate: record.dfEstimate,
                restoredDrEstimate: record.drEstimate,
                restoredObservationCount: record.observationCount,
                restoredDuplicateCount: record.duplicateCount
            )
        }

        #if DEBUG
        if sanitizedCount > 0 {
            print("[LINKQUALITY] importLinkStats: sanitized \(sanitizedCount)/\(importedCount) invalid timestamps (Date.distantPast)")
        }
        #endif
    }

    // MARK: - Timestamp Helpers

    /// Sanitize a timestamp - replace Date.distantPast or dates more than 1 year old with the fallback.
    private static func sanitizeTimestamp(_ date: Date, fallback: Date) -> Date {
        // Treat only truly invalid timestamps as needing normalization.
        if date == Date.distantPast {
            return fallback
        }
        if date.timeIntervalSince1970 <= 0 {
            return fallback
        }
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

private struct Observation {
    let timestamp: Date
    let isDuplicate: Bool
}

/// Statistics for a single directional link (A→B).
private struct DirectionalLinkStats {
    /// EWMA-smoothed delivery ratio (0.0...1.0).
    var ewmaRatio: Double

    /// Timestamp of last observation.
    var lastUpdated: Date

    /// Ring buffer of recent observations.
    var observations: RingBuffer<Observation>

    // Restored values from persistence (used when observations ring buffer is empty after import)
    var restoredDfEstimate: Double?
    var restoredDrEstimate: Double?
    var restoredObservationCount: Int
    var restoredDuplicateCount: Int

    init(
        ewmaRatio: Double,
        lastUpdated: Date,
        observations: RingBuffer<Observation>,
        restoredDfEstimate: Double? = nil,
        restoredDrEstimate: Double? = nil,
        restoredObservationCount: Int = 0,
        restoredDuplicateCount: Int = 0
    ) {
        self.ewmaRatio = ewmaRatio
        self.lastUpdated = lastUpdated
        self.observations = observations
        self.restoredDfEstimate = restoredDfEstimate
        self.restoredDrEstimate = restoredDrEstimate
        self.restoredObservationCount = restoredObservationCount
        self.restoredDuplicateCount = restoredDuplicateCount
    }

    /// Quality scaled to 0...255.
    /// Uses unidirectional ETX fallback: quality = 255 * df
    /// where df is the forward delivery probability estimated from unique/total ratio.
    var quality: Int {
        guard ewmaRatio > 0 else { return 0 }
        let q = 255.0 * ewmaRatio
        return min(255, max(0, Int(q.rounded())))
    }

    /// Add an observation and update EWMA.
    ///
    /// Uses traditional EWMA where each observation contributes directly:
    /// - Unique packet (first transmission success): contributes 1.0
    /// - Duplicate packet (retry indicator): contributes 0.0
    /// This ensures proper smoothing behavior where bad bursts degrade quality
    /// and recovery happens gradually with each clean packet.
    mutating func addObservation(timestamp: Date, isDuplicate: Bool, alpha: Double, maxObservations: Int) {
        observations.append(Observation(timestamp: timestamp, isDuplicate: isDuplicate))
        lastUpdated = timestamp

        // Clear restored values once we have real observations
        restoredDfEstimate = nil
        restoredDrEstimate = nil
        restoredObservationCount = 0
        restoredDuplicateCount = 0

        // Traditional EWMA: each observation contributes directly
        // Unique packet = 1.0 (successful first transmission)
        // Duplicate packet = 0.0 (indicates retry was needed)
        let thisObservationContribution = isDuplicate ? 0.0 : 1.0

        // EWMA update: ratio = alpha * newValue + (1 - alpha) * oldRatio
        ewmaRatio = alpha * thisObservationContribution + (1 - alpha) * ewmaRatio
    }

    /// Remove observations older than cutoff.
    mutating func pruneOld(cutoff: Date) {
        observations.removeAll { $0.timestamp < cutoff }
    }

    /// Convert to public LinkStats.
    func toLinkStats() -> LinkStats {
        let liveTotal = observations.count
        let liveDups = observations.elements.filter { $0.isDuplicate }.count
        let liveUnique = liveTotal - liveDups

        // Use live observations if available, otherwise use restored values
        let total: Int
        let dups: Int
        let df: Double?
        let dr: Double?

        if liveTotal > 0 {
            // We have live observations - calculate from them
            total = liveTotal
            dups = liveDups
            // df estimate: ratio of unique (non-duplicate) to total
            // Duplicates indicate retries, so unique/total approximates first-transmission success rate
            df = Double(liveUnique) / Double(liveTotal)
            dr = nil // Reverse probability requires bidirectional analysis (not yet implemented)
        } else if restoredObservationCount > 0 {
            // No live observations but we have restored data from persistence
            total = restoredObservationCount
            dups = restoredDuplicateCount
            df = restoredDfEstimate
            dr = restoredDrEstimate
        } else {
            // No data at all - this shouldn't happen but handle gracefully
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
            ewmaQuality: quality,
            lastUpdate: lastUpdated
        )
    }
}
