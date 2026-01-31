//
//  LinkQualityEstimator.swift
//  AXTerm
//
//  Created by Codex on 1/30/26.
//

import Foundation

/// Configuration for link quality estimation.
struct LinkQualityConfig {
    let slidingWindowSeconds: TimeInterval
    let ewmaAlpha: Double
    let initialDeliveryRatio: Double

    static let `default` = LinkQualityConfig(
        slidingWindowSeconds: 300,
        ewmaAlpha: 0.25,
        initialDeliveryRatio: 0.5
    )
}

/// Record for persisting link statistics.
struct LinkStatRecord: Equatable {
    let fromCall: String
    let toCall: String
    let quality: Int
    let lastUpdated: Date
}

/// ETX-style link quality estimator with directional tracking and EWMA smoothing.
/// Using a struct to avoid class initialization issues.
struct LinkQualityEstimator {
    let config: LinkQualityConfig

    // Internal storage keyed by "FROM→TO"
    private var stats: [String: QualityStats] = [:]

    init(config: LinkQualityConfig = .default) {
        self.config = config
    }

    /// Observe a packet transmission for link quality tracking.
    mutating func observePacket(_ packet: Packet, timestamp: Date, isDuplicate: Bool = false) {
        guard let rawFrom = packet.from?.display,
              let rawTo = packet.to?.display else { return }

        let from = CallsignValidator.normalize(rawFrom)
        let to = CallsignValidator.normalize(rawTo)
        guard !from.isEmpty, !to.isEmpty else { return }

        let key = "\(from)→\(to)"

        var s = stats[key] ?? QualityStats(
            ratio: config.initialDeliveryRatio,
            lastUpdated: timestamp,
            observations: []
        )
        s.addObservation(timestamp: timestamp, isDuplicate: isDuplicate, alpha: config.ewmaAlpha)
        stats[key] = s
    }

    /// Get the current quality estimate for a directional link.
    func linkQuality(from: String, to: String) -> Int {
        let key = "\(CallsignValidator.normalize(from))→\(CallsignValidator.normalize(to))"
        guard let s = stats[key] else { return 0 }
        return s.quality
    }

    /// Purge observations older than the sliding window.
    mutating func purgeStaleData(currentDate: Date) {
        let cutoff = currentDate.addingTimeInterval(-config.slidingWindowSeconds)

        var keysToRemove: [String] = []
        for (key, var s) in stats {
            s.pruneOld(cutoff: cutoff)
            if s.observations.isEmpty {
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
                return LinkStatRecord(
                    fromCall: parts[0],
                    toCall: parts[1],
                    quality: s.quality,
                    lastUpdated: s.lastUpdated
                )
            }
            .sorted { ($0.fromCall, $0.toCall) < ($1.fromCall, $1.toCall) }
    }

    /// Import link statistics from persistence.
    mutating func importLinkStats(_ records: [LinkStatRecord]) {
        for record in records {
            let key = "\(record.fromCall)→\(record.toCall)"
            let ratio = Double(record.quality) / 255.0
            stats[key] = QualityStats(
                ratio: ratio,
                lastUpdated: record.lastUpdated,
                observations: []
            )
        }
    }
}

// MARK: - Internal Stats

private struct Observation {
    let timestamp: Date
    let isDuplicate: Bool
}

private struct QualityStats {
    var ratio: Double
    var lastUpdated: Date
    var observations: [Observation]

    var quality: Int {
        guard ratio > 0 else { return 0 }
        let q = 255.0 * ratio
        return min(255, max(0, Int(q.rounded())))
    }

    mutating func addObservation(timestamp: Date, isDuplicate: Bool, alpha: Double) {
        observations.append(Observation(timestamp: timestamp, isDuplicate: isDuplicate))
        lastUpdated = timestamp

        let recentCount = min(observations.count, 20)
        let recent = observations.suffix(recentCount)
        let uniqueCount = recent.filter { !$0.isDuplicate }.count
        let instantRatio = Double(uniqueCount) / Double(recentCount)

        ratio = alpha * instantRatio + (1 - alpha) * ratio
    }

    mutating func pruneOld(cutoff: Date) {
        observations.removeAll { $0.timestamp < cutoff }
    }
}
