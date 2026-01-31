//
//  NetRomDecay.swift
//  AXTerm
//
//  Time-based TTL/decay model for NET/ROM neighbors, routes, and link stats.
//
//  This replaces the obsolescenceCount tick-based model with proper time-based TTL.
//  Decay is computed as a linear function of time elapsed since last observation.
//
//  Formula: decayFraction = max(0, min(1, (ttl - age) / ttl))
//  Where: age = now - lastSeen
//
//  Apple HIG Tooltips:
//  - Neighbors: "Freshness indicates how recently this neighbor was heard.
//               100% means heard within the TTL window; 0% means aged out."
//  - Routes: "Route freshness is based on the last time this path was reinforced.
//            Older evidence yields lower freshness."
//  - Decay: "Decay is a time-based freshness score computed from last observation
//           relative to TTL. It helps you gauge how stale this entry is."
//

import Foundation

// MARK: - Capture Source Type

/// Capture source type for differentiating KISS vs AGWPE behavior.
enum CaptureSourceType: String, Sendable {
    case kiss
    case agwpe

    /// Human-readable description.
    var description: String {
        switch self {
        case .kiss: return "KISS/Direwolf"
        case .agwpe: return "AGWPE"
        }
    }
}

// MARK: - Decay Configuration

/// Configuration for time-based decay calculations.
struct DecayConfig: Equatable, Sendable {
    /// TTL for neighbors in seconds.
    let neighborTTL: TimeInterval

    /// TTL for routes in seconds.
    let routeTTL: TimeInterval

    /// TTL for link stats in seconds.
    let linkStatTTL: TimeInterval

    /// Ingestion dedup window in seconds.
    /// KISS sources (Direwolf) already dedupe, so this is shorter.
    /// AGWPE sources may need longer dedup windows.
    let ingestionDedupWindow: TimeInterval

    /// Retry duplicate window in seconds (same for all sources by default).
    let retryDuplicateWindow: TimeInterval

    /// Capture source type.
    let sourceType: CaptureSourceType

    /// Default configuration.
    static let `default` = DecayConfig(
        neighborTTL: 15 * 60,      // 15 minutes
        routeTTL: 15 * 60,         // 15 minutes
        linkStatTTL: 15 * 60,      // 15 minutes
        ingestionDedupWindow: 0.25, // 250ms default
        retryDuplicateWindow: 2.0,  // 2 seconds
        sourceType: .kiss
    )

    /// KISS/Direwolf configuration.
    /// KISS sources have built-in deduplication in Direwolf.
    static let kiss = DecayConfig(
        neighborTTL: 15 * 60,
        routeTTL: 15 * 60,
        linkStatTTL: 15 * 60,
        ingestionDedupWindow: 0.25,  // Short window, Direwolf already dedupes
        retryDuplicateWindow: 2.0,
        sourceType: .kiss
    )

    /// AGWPE configuration.
    /// AGWPE sources may deliver duplicate frames, so no ingestion dedup.
    static let agwpe = DecayConfig(
        neighborTTL: 15 * 60,
        routeTTL: 15 * 60,
        linkStatTTL: 15 * 60,
        ingestionDedupWindow: 0.0,   // No ingestion dedup, app handles it
        retryDuplicateWindow: 2.0,
        sourceType: .agwpe
    )

    // TODO: Investigate if AGWPE frames produce duplicate artifacts differently than KISS.
    //       Adjust ingestionDedupWindow accordingly.
}

// MARK: - Decay Calculation Core

/// Core decay calculation functions.
enum DecayCalculator {
    /// Compute decay fraction (0.0 to 1.0) based on time elapsed.
    ///
    /// - Parameters:
    ///   - lastSeen: The timestamp when the entry was last observed.
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration.
    /// - Returns: A value from 0.0 (expired) to 1.0 (just seen).
    static func decayFraction(lastSeen: Date, now: Date, ttl: TimeInterval) -> Double {
        let age = now.timeIntervalSince(lastSeen)

        // Handle future timestamps (lastSeen > now)
        if age < 0 {
            return 1.0
        }

        // Linear decay: (ttl - age) / ttl, clamped to [0, 1]
        let fraction = (ttl - age) / ttl
        return max(0.0, min(1.0, fraction))
    }

    /// Map decay fraction (0.0-1.0) to 0-255 quality scale.
    ///
    /// - Parameter fraction: Decay fraction from 0.0 to 1.0.
    /// - Returns: Integer from 0 to 255.
    static func decay255(fraction: Double) -> Int {
        let clamped = max(0.0, min(1.0, fraction))
        return Int(round(clamped * 255.0))
    }

    /// Format decay fraction as a percentage string.
    ///
    /// - Parameter fraction: Decay fraction from 0.0 to 1.0.
    /// - Returns: Formatted string like "100%", "50%", "0%".
    static func decayDisplayString(fraction: Double) -> String {
        let percentage = Int(round(fraction * 100.0))
        return "\(percentage)%"
    }
}

// MARK: - NeighborInfo Decay Extension

extension NeighborInfo {
    /// Compute decay fraction based on lastSeen timestamp.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for neighbors.
    /// - Returns: A value from 0.0 (expired) to 1.0 (just seen).
    func decayFraction(now: Date, ttl: TimeInterval) -> Double {
        DecayCalculator.decayFraction(lastSeen: lastSeen, now: now, ttl: ttl)
    }

    /// Compute decay mapped to 0-255 scale.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for neighbors.
    /// - Returns: Integer from 0 to 255.
    func decay255(now: Date, ttl: TimeInterval) -> Int {
        DecayCalculator.decay255(fraction: decayFraction(now: now, ttl: ttl))
    }

    /// Get decay as a display percentage string.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for neighbors.
    /// - Returns: Formatted string like "100%", "50%", "0%".
    func decayDisplayString(now: Date, ttl: TimeInterval) -> String {
        DecayCalculator.decayDisplayString(fraction: decayFraction(now: now, ttl: ttl))
    }
}

// MARK: - Route Decay Wrapper

/// Wrapper for RouteInfo that includes lastUpdated timestamp for decay calculation.
/// RouteInfo itself doesn't store lastUpdated, so we need this wrapper.
struct RouteDecayInfo {
    let route: RouteInfo
    let lastUpdated: Date

    /// Compute decay fraction based on lastUpdated timestamp.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for routes.
    /// - Returns: A value from 0.0 (expired) to 1.0 (just seen).
    func decayFraction(now: Date, ttl: TimeInterval) -> Double {
        DecayCalculator.decayFraction(lastSeen: lastUpdated, now: now, ttl: ttl)
    }

    /// Compute decay mapped to 0-255 scale.
    func decay255(now: Date, ttl: TimeInterval) -> Int {
        DecayCalculator.decay255(fraction: decayFraction(now: now, ttl: ttl))
    }

    /// Get decay as a display percentage string.
    func decayDisplayString(now: Date, ttl: TimeInterval) -> String {
        DecayCalculator.decayDisplayString(fraction: decayFraction(now: now, ttl: ttl))
    }
}

// MARK: - LinkStatRecord Decay Extension

extension LinkStatRecord {
    /// Compute decay fraction based on lastUpdated timestamp.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for link stats.
    /// - Returns: A value from 0.0 (expired) to 1.0 (just seen).
    func decayFraction(now: Date, ttl: TimeInterval) -> Double {
        DecayCalculator.decayFraction(lastSeen: lastUpdated, now: now, ttl: ttl)
    }

    /// Compute decay mapped to 0-255 scale.
    func decay255(now: Date, ttl: TimeInterval) -> Int {
        DecayCalculator.decay255(fraction: decayFraction(now: now, ttl: ttl))
    }

    /// Get decay as a display percentage string.
    func decayDisplayString(now: Date, ttl: TimeInterval) -> String {
        DecayCalculator.decayDisplayString(fraction: decayFraction(now: now, ttl: ttl))
    }
}

// MARK: - Apple HIG Tooltip Texts

/// Tooltip texts following Apple HIG guidelines.
/// - Use sentence-style capitalization
/// - Avoid technical acronyms where possible
/// - Provide clear purpose and example
enum DecayTooltips {
    /// Tooltip for the Neighbors decay/freshness column.
    static let neighbors = """
        Freshness indicates how recently this neighbor was heard. \
        100% means seen within the TTL window; lower values fade toward expired.
        """

    /// Tooltip for the Routes decay/freshness column.
    static let routes = """
        Route freshness is based on the last time this path was reinforced. \
        Older evidence yields lower freshness.
        """

    /// Tooltip for the Link Quality decay column.
    static let linkQuality = """
        Decay is a time-based freshness score computed from last observation \
        relative to TTL. It helps you gauge how stale this entry is.
        """

    /// Short tooltip for decay column header.
    static let decayHeader = """
        Time-based freshness: 100% = just seen, 0% = expired.
        """
}

// MARK: - Accessibility Labels

/// Accessibility labels for decay-related UI elements.
enum DecayAccessibility {
    /// Generate accessibility label for a neighbor's decay.
    static func neighborDecay(_ fraction: Double, callsign: String) -> String {
        let percent = Int(round(fraction * 100))
        if percent >= 90 {
            return "Neighbor \(callsign) freshness: \(percent) percent, recently heard"
        } else if percent >= 50 {
            return "Neighbor \(callsign) freshness: \(percent) percent"
        } else if percent > 0 {
            return "Neighbor \(callsign) freshness: \(percent) percent, getting stale"
        } else {
            return "Neighbor \(callsign) freshness: expired"
        }
    }

    /// Generate accessibility label for a route's decay.
    static func routeDecay(_ fraction: Double, destination: String) -> String {
        let percent = Int(round(fraction * 100))
        if percent >= 90 {
            return "Route to \(destination) freshness: \(percent) percent, recently reinforced"
        } else if percent >= 50 {
            return "Route to \(destination) freshness: \(percent) percent"
        } else if percent > 0 {
            return "Route to \(destination) freshness: \(percent) percent, getting stale"
        } else {
            return "Route to \(destination) freshness: expired"
        }
    }

    /// Generate accessibility label for a link stat's decay.
    static func linkStatDecay(_ fraction: Double, from: String, to: String) -> String {
        let percent = Int(round(fraction * 100))
        if percent >= 90 {
            return "Link from \(from) to \(to) freshness: \(percent) percent, recently observed"
        } else if percent >= 50 {
            return "Link from \(from) to \(to) freshness: \(percent) percent"
        } else if percent > 0 {
            return "Link from \(from) to \(to) freshness: \(percent) percent, getting stale"
        } else {
            return "Link from \(from) to \(to) freshness: expired"
        }
    }
}
