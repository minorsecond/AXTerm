//
//  PathSuggester.swift
//  AXTerm
//
//  Path suggestion engine based on ETX/ETT scoring.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 5.1, 8.1
//
//  Path suggestions are ranked by: ETT + hopPenalty + congestionPenalty + stalePenalty
//  Default mode is "Suggested" - user can override to "Manual" per destination.
//

import Foundation

// MARK: - Path Score

/// Quality metrics for a path to a destination
nonisolated struct PathScore: Sendable {
    /// Expected Transmissions (1.0 = perfect, higher = worse)
    let etx: Double

    /// Expected Transmission Time in seconds
    let ett: Double

    /// Number of hops (0 = direct)
    let hops: Int

    /// Freshness (1.0 = just heard, decays over time)
    let freshness: Double

    /// Composite score for ranking (lower is better)
    var compositeScore: Double {
        // Weights from spec Section 8.1
        let hopPenalty = Double(hops) * 0.5
        let stalePenalty = (1.0 - freshness) * 2.0
        let congestionPenalty = max(0, (etx - 1.0)) * 0.3

        return ett + hopPenalty + congestionPenalty + stalePenalty
    }
}

// MARK: - Path Suggestion

/// Suggested path with scoring and explanation
nonisolated struct PathSuggestion: Sendable {
    /// The suggested digipeater path
    let path: DigiPath

    /// Quality score for this path
    let score: PathScore

    /// Human-readable reason for suggestion
    let reason: String

    /// Category of suggestion
    enum Category {
        case direct
        case bestETT
        case mostReliable
        case shortest
        case recent
    }

    /// Generate a reason string from score and category
    static func generateReason(for score: PathScore, category: Category) -> String {
        let freshPercent = Int(score.freshness * 100)

        switch category {
        case .direct:
            return "Direct (no digis), fresh \(freshPercent)%"
        case .bestETT:
            return "Best ETT (\(String(format: "%.1f", score.ett))s), \(score.hops) hops, fresh \(freshPercent)%"
        case .mostReliable:
            return "Most reliable (ETX \(String(format: "%.1f", score.etx))), \(score.hops) hops"
        case .shortest:
            return "Shortest (\(score.hops) hop\(score.hops == 1 ? "" : "s")), moderate reliability"
        case .recent:
            return "Recently used, fresh \(freshPercent)%"
        }
    }
}

// MARK: - Path Mode

/// Path selection mode per destination
nonisolated enum PathMode: String, Sendable, CaseIterable {
    /// User can edit but path is prefilled from best suggestion
    case suggested

    /// User locks a specific path
    case manual

    /// System picks best path at send time (advanced)
    case auto
}

// MARK: - Destination Path Settings

/// Per-destination path configuration
nonisolated struct DestinationPathSettings: Sendable {
    let destination: String
    var mode: PathMode = .suggested
    var lockedPath: DigiPath?

    init(destination: String) {
        self.destination = destination.uppercased()
    }
}

// MARK: - Path Statistics

/// Statistics for a specific path to a destination
nonisolated private struct PathStats: Sendable {
    var successCount: Int = 0
    var failureCount: Int = 0
    var totalRtt: Double = 0
    var lastUsed: Date = Date()

    var etx: Double {
        let total = successCount + failureCount
        guard total > 0 else { return 1.0 }
        let successRate = Double(successCount) / Double(total)
        guard successRate > 0.05 else { return 20.0 }  // Clamp per spec
        return 1.0 / successRate
    }

    var averageRtt: Double {
        guard successCount > 0 else { return 3.0 }  // Default
        return totalRtt / Double(successCount)
    }

    var freshness: Double {
        let age = Date().timeIntervalSince(lastUsed)
        let halfLife: TimeInterval = 1800  // 30 minutes
        return exp(-age / halfLife)
    }

    mutating func recordSuccess(rtt: Double) {
        successCount += 1
        totalRtt += rtt
        lastUsed = Date()
    }

    mutating func recordFailure() {
        failureCount += 1
        lastUsed = Date()
    }
}

// MARK: - Path Key

/// Key for path lookup (destination + path signature)
nonisolated private struct PathKey: Hashable, Sendable {
    let destination: String
    let pathSignature: String

    init(destination: String, path: DigiPath) {
        self.destination = destination.uppercased()
        self.pathSignature = path.digis.map { "\($0.call)-\($0.ssid)" }.joined(separator: ",")
    }
}

// MARK: - Path Suggester

/// Suggests optimal paths based on historical performance
nonisolated struct PathSuggester: Sendable {

    /// Statistics per path
    private var stats: [PathKey: PathStats] = [:]

    /// Recent paths per destination (for "Recent" section)
    private var recent: [String: [DigiPath]] = [:]

    /// Maximum recent paths to track
    private let maxRecent = 10

    /// Minimum freshness threshold for suggestions
    private let minFreshness = 0.1

    // MARK: - Recording

    /// Record a successful delivery on a path
    mutating func recordSuccess(destination: String, path: DigiPath, rtt: Double) {
        let key = PathKey(destination: destination, path: path)
        var stat = stats[key] ?? PathStats()
        stat.recordSuccess(rtt: rtt)
        stats[key] = stat

        // Update recent paths
        let dest = destination.uppercased()
        var recentList = recent[dest] ?? []
        // Remove if already present
        recentList.removeAll { $0.signature == path.signature }
        // Add to front
        recentList.insert(path, at: 0)
        // Trim
        if recentList.count > maxRecent {
            recentList = Array(recentList.prefix(maxRecent))
        }
        recent[dest] = recentList
    }

    /// Record a failed delivery attempt on a path
    mutating func recordFailure(destination: String, path: DigiPath) {
        let key = PathKey(destination: destination, path: path)
        var stat = stats[key] ?? PathStats()
        stat.recordFailure()
        stats[key] = stat
    }

    // MARK: - Suggestions

    /// Get path suggestions for a destination
    func suggest(for destination: String, maxSuggestions: Int = 3) -> [PathSuggestion] {
        let dest = destination.uppercased()

        // Find all paths to this destination
        let relevantKeys = stats.keys.filter { $0.destination == dest }

        guard !relevantKeys.isEmpty else { return [] }

        // Build suggestions
        var suggestions: [PathSuggestion] = []

        for key in relevantKeys {
            guard let stat = stats[key] else { continue }
            guard stat.freshness >= minFreshness else { continue }

            let path = parsePath(key.pathSignature)
            let score = PathScore(
                etx: stat.etx,
                ett: stat.averageRtt * stat.etx,
                hops: path.count,
                freshness: stat.freshness
            )

            let category: PathSuggestion.Category
            if path.count == 0 {
                category = .direct
            } else if stat.etx <= 1.5 {
                category = .mostReliable
            } else {
                category = .bestETT
            }

            let reason = PathSuggestion.generateReason(for: score, category: category)
            suggestions.append(PathSuggestion(path: path, score: score, reason: reason))
        }

        // Sort by composite score (lower is better)
        suggestions.sort { $0.score.compositeScore < $1.score.compositeScore }

        return Array(suggestions.prefix(maxSuggestions))
    }

    /// Get recent paths for a destination
    func recentPaths(for destination: String, limit: Int = 5) -> [DigiPath] {
        let dest = destination.uppercased()
        guard let paths = recent[dest] else { return [] }
        return Array(paths.prefix(limit))
    }

    // MARK: - Helpers

    private func parsePath(_ signature: String) -> DigiPath {
        guard !signature.isEmpty else { return DigiPath() }
        let calls = signature.split(separator: ",").map(String.init)
        return DigiPath.from(calls)
    }
}

// MARK: - DigiPath Extension

extension DigiPath {
    /// Unique signature for this path
    var signature: String {
        digis.map { "\($0.call)-\($0.ssid)" }.joined(separator: ",")
    }
}
