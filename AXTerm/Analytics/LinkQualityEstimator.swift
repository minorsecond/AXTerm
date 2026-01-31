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
    /// Sliding window duration for observations (seconds).
    let slidingWindowSeconds: TimeInterval

    /// EWMA alpha: higher = more responsive to recent observations, lower = more stable.
    let ewmaAlpha: Double

    /// Initial delivery ratio for cold-start links.
    let initialDeliveryRatio: Double

    /// Maximum observations to retain per directional link (ring buffer bound).
    let maxObservationsPerLink: Int

    static let `default` = LinkQualityConfig(
        slidingWindowSeconds: 300,
        ewmaAlpha: 0.1,  // Lower alpha = more smoothing, prevents drastic quality drops from short bursts
        initialDeliveryRatio: 0.5,
        maxObservationsPerLink: 100
    )

    /// Generate a hash for config invalidation purposes.
    func configHash() -> String {
        "link_v1_\(slidingWindowSeconds)_\(ewmaAlpha)_\(initialDeliveryRatio)_\(maxObservationsPerLink)"
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
        stats
            .compactMap { (key, s) -> LinkStatRecord? in
                let parts = key.components(separatedBy: "→")
                guard parts.count == 2 else { return nil }
                let linkStats = s.toLinkStats()
                return LinkStatRecord(
                    fromCall: parts[0],
                    toCall: parts[1],
                    quality: linkStats.ewmaQuality,
                    lastUpdated: linkStats.lastUpdate ?? Date.distantPast,
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
        for record in records {
            let key = "\(record.fromCall)→\(record.toCall)"
            let ratio = Double(record.quality) / 255.0
            stats[key] = DirectionalLinkStats(
                ewmaRatio: ratio,
                lastUpdated: record.lastUpdated,
                observations: RingBuffer(capacity: config.maxObservationsPerLink)
            )
        }
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
        let total = observations.count
        let dups = observations.elements.filter { $0.isDuplicate }.count
        let unique = total - dups

        // df estimate: ratio of unique (non-duplicate) to total
        // Duplicates indicate retries, so unique/total approximates first-transmission success rate
        let df: Double? = total > 0 ? Double(unique) / Double(total) : nil

        return LinkStats(
            observationCount: total,
            duplicateCount: dups,
            dfEstimate: df,
            drEstimate: nil, // Reverse probability requires bidirectional analysis
            ewmaQuality: quality,
            lastUpdate: lastUpdated
        )
    }
}
