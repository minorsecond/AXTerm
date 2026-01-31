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
//               100% means seen within TTL; lower values fade toward expired."
//  - Routes: "Route freshness is based on the last time this path was reinforced.
//            Older evidence yields lower freshness."
//  - Decay: "Decay is a time-based freshness score computed from last observation relative to TTL.
//           It helps you gauge how stale this entry is."
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

// MARK: - Freshness Configuration

/// Configuration for time-based freshness calculations.
///
/// Uses a plateau + smoothstep model:
/// - During plateau period: freshness stays near 100% (gentle 5% decline)
/// - After plateau: smoothstep easing to 0% at TTL
struct FreshnessConfig: Equatable, Sendable {
    /// TTL for neighbors in seconds.
    let neighborTTL: TimeInterval

    /// TTL for routes in seconds.
    let routeTTL: TimeInterval

    /// TTL for link stats in seconds.
    let linkStatTTL: TimeInterval

    /// Plateau duration in seconds.
    /// During this period, freshness stays near 100%.
    let plateauDuration: TimeInterval

    /// Ingestion dedup window in seconds.
    /// KISS sources (Direwolf) already dedupe, so this is shorter.
    /// AGWPE sources may need longer dedup windows.
    let ingestionDedupWindow: TimeInterval

    /// Retry duplicate window in seconds (same for all sources by default).
    let retryDuplicateWindow: TimeInterval

    /// Capture source type.
    let sourceType: CaptureSourceType

    /// Default configuration with 30-minute TTL and 5-minute plateau.
    static let `default` = FreshnessConfig(
        neighborTTL: 30 * 60,       // 30 minutes
        routeTTL: 30 * 60,          // 30 minutes
        linkStatTTL: 30 * 60,       // 30 minutes
        plateauDuration: 5 * 60,    // 5 minutes
        ingestionDedupWindow: 0.25, // 250ms default
        retryDuplicateWindow: 2.0,  // 2 seconds
        sourceType: .kiss
    )

    /// KISS/Direwolf configuration.
    /// KISS sources have built-in deduplication in Direwolf.
    static let kiss = FreshnessConfig(
        neighborTTL: 30 * 60,
        routeTTL: 30 * 60,
        linkStatTTL: 30 * 60,
        plateauDuration: 5 * 60,
        ingestionDedupWindow: 0.25,  // Short window, Direwolf already dedupes
        retryDuplicateWindow: 2.0,
        sourceType: .kiss
    )

    /// AGWPE configuration.
    /// AGWPE sources may deliver duplicate frames, so no ingestion dedup.
    static let agwpe = FreshnessConfig(
        neighborTTL: 30 * 60,
        routeTTL: 30 * 60,
        linkStatTTL: 30 * 60,
        plateauDuration: 5 * 60,
        ingestionDedupWindow: 0.0,   // No ingestion dedup, app handles it
        retryDuplicateWindow: 2.0,
        sourceType: .agwpe
    )
}

// MARK: - Legacy Decay Configuration (Deprecated)

/// Configuration for time-based decay calculations.
/// - Note: Deprecated. Use FreshnessConfig instead.
@available(*, deprecated, message: "Use FreshnessConfig instead")
struct DecayConfig: Equatable, Sendable {
    /// TTL for neighbors in seconds.
    let neighborTTL: TimeInterval

    /// TTL for routes in seconds.
    let routeTTL: TimeInterval

    /// TTL for link stats in seconds.
    let linkStatTTL: TimeInterval

    /// Ingestion dedup window in seconds.
    let ingestionDedupWindow: TimeInterval

    /// Retry duplicate window in seconds.
    let retryDuplicateWindow: TimeInterval

    /// Capture source type.
    let sourceType: CaptureSourceType

    /// Default configuration.
    static let `default` = DecayConfig(
        neighborTTL: 15 * 60,
        routeTTL: 15 * 60,
        linkStatTTL: 15 * 60,
        ingestionDedupWindow: 0.25,
        retryDuplicateWindow: 2.0,
        sourceType: .kiss
    )

    /// KISS/Direwolf configuration.
    static let kiss = DecayConfig(
        neighborTTL: 15 * 60,
        routeTTL: 15 * 60,
        linkStatTTL: 15 * 60,
        ingestionDedupWindow: 0.25,
        retryDuplicateWindow: 2.0,
        sourceType: .kiss
    )

    /// AGWPE configuration.
    static let agwpe = DecayConfig(
        neighborTTL: 15 * 60,
        routeTTL: 15 * 60,
        linkStatTTL: 15 * 60,
        ingestionDedupWindow: 0.0,
        retryDuplicateWindow: 2.0,
        sourceType: .agwpe
    )
}

// MARK: - Freshness Calculation Core

/// Core freshness calculation functions using plateau + smoothstep model.
///
/// The freshness curve has two phases:
/// 1. **Plateau phase** (0 to plateauDuration): Freshness stays near 100% with gentle 5% decline
/// 2. **Decay phase** (plateauDuration to TTL): Smoothstep easing from 95% to 0%
///
/// This provides intuitive UX where recently-seen nodes look healthy,
/// with a smooth transition to stale/expired status.
enum FreshnessCalculator {
    /// Default plateau duration (5 minutes).
    static let defaultPlateau: TimeInterval = 5 * 60

    /// Default TTL (30 minutes).
    static let defaultTTL: TimeInterval = 30 * 60

    /// Smoothstep easing function: t²(3 - 2t)
    ///
    /// - Parameter t: Input value from 0.0 to 1.0.
    /// - Returns: Smoothed value from 0.0 to 1.0.
    static func smoothstep(_ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }

    /// Compute freshness fraction (0.0 to 1.0) based on time elapsed.
    ///
    /// Uses plateau + smoothstep model:
    /// - If age ≤ 0: freshness = 1.0
    /// - If age ≤ plateau: freshness = 1.0 - 0.05 × (age / plateau)
    /// - If age < TTL: t = (age - plateau) / (TTL - plateau); freshness = 0.95 × (1 - smoothstep(t))
    /// - If age ≥ TTL: freshness = 0.0
    ///
    /// - Parameters:
    ///   - lastSeen: The timestamp when the entry was last observed.
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration.
    ///   - plateau: The plateau duration (defaults to 5 minutes).
    /// - Returns: A value from 0.0 (expired) to 1.0 (just seen).
    static func freshness(lastSeen: Date, now: Date, ttl: TimeInterval, plateau: TimeInterval = defaultPlateau) -> Double {
        let age = now.timeIntervalSince(lastSeen)

        // Handle future timestamps (lastSeen > now)
        if age <= 0 {
            return 1.0
        }

        // Phase 1: Plateau - gentle 5% decline over plateau period
        if age <= plateau {
            return 1.0 - 0.05 * (age / plateau)
        }

        // Phase 2: Smoothstep decay from 95% to 0%
        if age < ttl {
            let t = (age - plateau) / (ttl - plateau)
            return 0.95 * (1.0 - smoothstep(t))
        }

        // Expired
        return 0.0
    }

    /// Map freshness fraction (0.0-1.0) to 0-255 quality scale.
    ///
    /// - Parameter fraction: Freshness fraction from 0.0 to 1.0.
    /// - Returns: Integer from 0 to 255.
    static func freshness255(fraction: Double) -> Int {
        let clamped = max(0.0, min(1.0, fraction))
        return Int(round(clamped * 255.0))
    }

    /// Format freshness fraction as a percentage string.
    ///
    /// - Parameter fraction: Freshness fraction from 0.0 to 1.0.
    /// - Returns: Formatted string like "100%", "50%", "0%".
    static func freshnessDisplayString(fraction: Double) -> String {
        let percentage = Int(round(fraction * 100.0))
        return "\(percentage)%"
    }

    /// Get a human-readable freshness status.
    ///
    /// - Parameter fraction: Freshness fraction from 0.0 to 1.0.
    /// - Returns: Status string like "Fresh", "Recent", "Stale", "Expired".
    static func freshnessStatus(fraction: Double) -> String {
        switch fraction {
        case 0.90...1.0:
            return "Fresh"
        case 0.50..<0.90:
            return "Recent"
        case 0.01..<0.50:
            return "Stale"
        default:
            return "Expired"
        }
    }
}

// MARK: - Legacy Decay Calculator (Deprecated)

/// Core decay calculation functions.
/// - Note: Deprecated. Use FreshnessCalculator instead.
@available(*, deprecated, message: "Use FreshnessCalculator instead")
enum DecayCalculator {
    /// Compute decay fraction (0.0 to 1.0) based on time elapsed.
    static func decayFraction(lastSeen: Date, now: Date, ttl: TimeInterval) -> Double {
        let age = now.timeIntervalSince(lastSeen)
        if age < 0 { return 1.0 }
        let fraction = (ttl - age) / ttl
        return max(0.0, min(1.0, fraction))
    }

    /// Map decay fraction (0.0-1.0) to 0-255 quality scale.
    static func decay255(fraction: Double) -> Int {
        let clamped = max(0.0, min(1.0, fraction))
        return Int(round(clamped * 255.0))
    }

    /// Format decay fraction as a percentage string.
    static func decayDisplayString(fraction: Double) -> String {
        let percentage = Int(round(fraction * 100.0))
        return "\(percentage)%"
    }
}

// MARK: - NeighborInfo Freshness Extension

extension NeighborInfo {
    /// Compute freshness fraction based on lastSeen timestamp.
    ///
    /// Uses plateau + smoothstep model for intuitive UX.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for neighbors.
    ///   - plateau: The plateau duration (defaults to 5 minutes).
    /// - Returns: A value from 0.0 (expired) to 1.0 (just seen).
    func freshness(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> Double {
        FreshnessCalculator.freshness(lastSeen: lastSeen, now: now, ttl: ttl, plateau: plateau)
    }

    /// Compute freshness mapped to 0-255 scale.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for neighbors.
    ///   - plateau: The plateau duration (defaults to 5 minutes).
    /// - Returns: Integer from 0 to 255.
    func freshness255(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> Int {
        FreshnessCalculator.freshness255(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    /// Get freshness as a display percentage string.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for neighbors.
    ///   - plateau: The plateau duration (defaults to 5 minutes).
    /// - Returns: Formatted string like "100%", "50%", "0%".
    func freshnessDisplayString(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> String {
        FreshnessCalculator.freshnessDisplayString(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    /// Get freshness status label.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for neighbors.
    ///   - plateau: The plateau duration (defaults to 5 minutes).
    /// - Returns: Status string like "Fresh", "Recent", "Stale", "Expired".
    func freshnessStatus(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> String {
        FreshnessCalculator.freshnessStatus(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    // MARK: Legacy Decay Methods (Deprecated)

    /// Compute decay fraction based on lastSeen timestamp.
    /// - Note: Deprecated. Use `freshness(now:ttl:plateau:)` instead.
    @available(*, deprecated, message: "Use freshness(now:ttl:plateau:) instead")
    func decayFraction(now: Date, ttl: TimeInterval) -> Double {
        // Use linear decay for backwards compatibility
        let age = now.timeIntervalSince(lastSeen)
        if age < 0 { return 1.0 }
        let fraction = (ttl - age) / ttl
        return max(0.0, min(1.0, fraction))
    }

    /// Compute decay mapped to 0-255 scale.
    /// - Note: Deprecated. Use `freshness255(now:ttl:plateau:)` instead.
    @available(*, deprecated, message: "Use freshness255(now:ttl:plateau:) instead")
    func decay255(now: Date, ttl: TimeInterval) -> Int {
        let clamped = max(0.0, min(1.0, decayFraction(now: now, ttl: ttl)))
        return Int(round(clamped * 255.0))
    }

    /// Get decay as a display percentage string.
    /// - Note: Deprecated. Use `freshnessDisplayString(now:ttl:plateau:)` instead.
    @available(*, deprecated, message: "Use freshnessDisplayString(now:ttl:plateau:) instead")
    func decayDisplayString(now: Date, ttl: TimeInterval) -> String {
        let percentage = Int(round(decayFraction(now: now, ttl: ttl) * 100.0))
        return "\(percentage)%"
    }
}

// MARK: - RouteInfo Freshness Extension

extension RouteInfo {
    /// Compute freshness fraction based on lastUpdated timestamp.
    ///
    /// Uses plateau + smoothstep model for intuitive UX.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for routes.
    ///   - plateau: The plateau duration (defaults to 5 minutes).
    /// - Returns: A value from 0.0 (expired) to 1.0 (just seen).
    func freshness(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> Double {
        FreshnessCalculator.freshness(lastSeen: lastUpdated, now: now, ttl: ttl, plateau: plateau)
    }

    /// Compute freshness mapped to 0-255 scale.
    func freshness255(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> Int {
        FreshnessCalculator.freshness255(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    /// Get freshness as a display percentage string.
    func freshnessDisplayString(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> String {
        FreshnessCalculator.freshnessDisplayString(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    /// Get freshness status label.
    func freshnessStatus(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> String {
        FreshnessCalculator.freshnessStatus(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    // MARK: Legacy Decay Methods (Deprecated)

    /// Compute decay fraction based on lastUpdated timestamp.
    /// - Note: Deprecated. Use `freshness(now:ttl:plateau:)` instead.
    @available(*, deprecated, message: "Use freshness(now:ttl:plateau:) instead")
    func decayFraction(now: Date, ttl: TimeInterval) -> Double {
        let age = now.timeIntervalSince(lastUpdated)
        if age < 0 { return 1.0 }
        let fraction = (ttl - age) / ttl
        return max(0.0, min(1.0, fraction))
    }

    /// Compute decay mapped to 0-255 scale.
    /// - Note: Deprecated. Use `freshness255(now:ttl:plateau:)` instead.
    @available(*, deprecated, message: "Use freshness255(now:ttl:plateau:) instead")
    func decay255(now: Date, ttl: TimeInterval) -> Int {
        let clamped = max(0.0, min(1.0, decayFraction(now: now, ttl: ttl)))
        return Int(round(clamped * 255.0))
    }

    /// Get decay as a display percentage string.
    /// - Note: Deprecated. Use `freshnessDisplayString(now:ttl:plateau:)` instead.
    @available(*, deprecated, message: "Use freshnessDisplayString(now:ttl:plateau:) instead")
    func decayDisplayString(now: Date, ttl: TimeInterval) -> String {
        let percentage = Int(round(decayFraction(now: now, ttl: ttl) * 100.0))
        return "\(percentage)%"
    }
}

// MARK: - Route Freshness Wrapper

/// Wrapper for RouteInfo that includes lastUpdated timestamp for freshness calculation.
/// RouteInfo itself doesn't store lastUpdated, so we need this wrapper.
struct RouteFreshnessInfo {
    let route: RouteInfo
    let lastUpdated: Date

    /// Compute freshness fraction based on lastUpdated timestamp.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for routes.
    ///   - plateau: The plateau duration (defaults to 5 minutes).
    /// - Returns: A value from 0.0 (expired) to 1.0 (just seen).
    func freshness(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> Double {
        FreshnessCalculator.freshness(lastSeen: lastUpdated, now: now, ttl: ttl, plateau: plateau)
    }

    /// Compute freshness mapped to 0-255 scale.
    func freshness255(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> Int {
        FreshnessCalculator.freshness255(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    /// Get freshness as a display percentage string.
    func freshnessDisplayString(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> String {
        FreshnessCalculator.freshnessDisplayString(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    /// Get freshness status label.
    func freshnessStatus(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> String {
        FreshnessCalculator.freshnessStatus(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }
}

/// Wrapper for RouteInfo that includes lastUpdated timestamp for decay calculation.
/// - Note: Deprecated. Use RouteFreshnessInfo instead.
@available(*, deprecated, message: "Use RouteFreshnessInfo instead")
struct RouteDecayInfo {
    let route: RouteInfo
    let lastUpdated: Date

    func decayFraction(now: Date, ttl: TimeInterval) -> Double {
        let age = now.timeIntervalSince(lastUpdated)
        if age < 0 { return 1.0 }
        let fraction = (ttl - age) / ttl
        return max(0.0, min(1.0, fraction))
    }

    func decay255(now: Date, ttl: TimeInterval) -> Int {
        let clamped = max(0.0, min(1.0, decayFraction(now: now, ttl: ttl)))
        return Int(round(clamped * 255.0))
    }

    func decayDisplayString(now: Date, ttl: TimeInterval) -> String {
        let percentage = Int(round(decayFraction(now: now, ttl: ttl) * 100.0))
        return "\(percentage)%"
    }
}

// MARK: - LinkStatRecord Freshness Extension

extension LinkStatRecord {
    /// Compute freshness fraction based on lastUpdated timestamp.
    ///
    /// Uses plateau + smoothstep model for intuitive UX.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - ttl: The time-to-live duration for link stats.
    ///   - plateau: The plateau duration (defaults to 5 minutes).
    /// - Returns: A value from 0.0 (expired) to 1.0 (just seen).
    func freshness(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> Double {
        FreshnessCalculator.freshness(lastSeen: lastUpdated, now: now, ttl: ttl, plateau: plateau)
    }

    /// Compute freshness mapped to 0-255 scale.
    func freshness255(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> Int {
        FreshnessCalculator.freshness255(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    /// Get freshness as a display percentage string.
    func freshnessDisplayString(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> String {
        FreshnessCalculator.freshnessDisplayString(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    /// Get freshness status label.
    func freshnessStatus(now: Date, ttl: TimeInterval, plateau: TimeInterval = FreshnessCalculator.defaultPlateau) -> String {
        FreshnessCalculator.freshnessStatus(fraction: freshness(now: now, ttl: ttl, plateau: plateau))
    }

    // MARK: Legacy Decay Methods (Deprecated)

    /// Compute decay fraction based on lastUpdated timestamp.
    /// - Note: Deprecated. Use `freshness(now:ttl:plateau:)` instead.
    @available(*, deprecated, message: "Use freshness(now:ttl:plateau:) instead")
    func decayFraction(now: Date, ttl: TimeInterval) -> Double {
        let age = now.timeIntervalSince(lastUpdated)
        if age < 0 { return 1.0 }
        let fraction = (ttl - age) / ttl
        return max(0.0, min(1.0, fraction))
    }

    /// Compute decay mapped to 0-255 scale.
    /// - Note: Deprecated. Use `freshness255(now:ttl:plateau:)` instead.
    @available(*, deprecated, message: "Use freshness255(now:ttl:plateau:) instead")
    func decay255(now: Date, ttl: TimeInterval) -> Int {
        let clamped = max(0.0, min(1.0, decayFraction(now: now, ttl: ttl)))
        return Int(round(clamped * 255.0))
    }

    /// Get decay as a display percentage string.
    /// - Note: Deprecated. Use `freshnessDisplayString(now:ttl:plateau:)` instead.
    @available(*, deprecated, message: "Use freshnessDisplayString(now:ttl:plateau:) instead")
    func decayDisplayString(now: Date, ttl: TimeInterval) -> String {
        let percentage = Int(round(decayFraction(now: now, ttl: ttl) * 100.0))
        return "\(percentage)%"
    }
}

// MARK: - Apple HIG Tooltip Texts

/// Tooltip texts following Apple HIG guidelines for Freshness display.
/// - Use sentence-style capitalization
/// - Avoid technical acronyms where possible
/// - Provide clear purpose and example
enum FreshnessTooltips {
    /// Tooltip for the Neighbors freshness column.
    static let neighbors = """
        Freshness indicates how recently this neighbor was heard.
        100% = just seen; drops to 0% after 30 minutes of silence.
        """

    /// Tooltip for the Routes freshness column.
    static let routes = """
        Route freshness shows how recently this path was reinforced.
        Newer routes appear fresher; stale routes fade toward 0%.
        """

    /// Tooltip for the Link Stats freshness column.
    static let linkStats = """
        Link freshness reflects how recently traffic was observed on this link.
        Fresher stats are more reliable for routing decisions.
        """

    /// Short tooltip for freshness column header.
    static let header = "Time-based freshness: 100% = just seen, 0% = expired."

    /// Detailed tooltip explaining the freshness curve.
    static let detailed = """
        Freshness uses a gentle curve that stays near 100% for the first 5 minutes,
        then smoothly declines to 0% at 30 minutes. This reflects typical packet radio
        activity patterns where periodic beacons keep links fresh.
        """
}

/// Legacy tooltip texts.
/// - Note: Deprecated. Use FreshnessTooltips instead.
@available(*, deprecated, message: "Use FreshnessTooltips instead")
enum DecayTooltips {
    static let neighbors = FreshnessTooltips.neighbors
    static let routes = FreshnessTooltips.routes
    static let decay = FreshnessTooltips.detailed
    static let linkQuality = FreshnessTooltips.linkStats
    static let decayHeader = FreshnessTooltips.header
}

// MARK: - Freshness Color Scheme

import SwiftUI

/// Color scheme for freshness display following Apple HIG.
enum FreshnessColors {
    /// Get the color for a freshness fraction.
    ///
    /// Uses a green-to-gray gradient:
    /// - 100%: Bright green (fresh)
    /// - 50%: Yellow-orange (stale)
    /// - 0%: Gray (expired)
    ///
    /// - Parameter fraction: Freshness fraction from 0.0 to 1.0.
    /// - Returns: Color for display.
    static func color(for fraction: Double) -> Color {
        switch fraction {
        case 0.90...1.0:
            return .green
        case 0.70..<0.90:
            return Color(red: 0.4, green: 0.8, blue: 0.2) // Yellow-green
        case 0.50..<0.70:
            return .yellow
        case 0.25..<0.50:
            return .orange
        case 0.01..<0.25:
            return Color(red: 0.8, green: 0.4, blue: 0.2) // Orange-red
        default:
            return .gray
        }
    }

    /// Get semantic color name for accessibility.
    ///
    /// - Parameter fraction: Freshness fraction from 0.0 to 1.0.
    /// - Returns: Color name string.
    static func colorName(for fraction: Double) -> String {
        switch fraction {
        case 0.90...1.0:
            return "green"
        case 0.70..<0.90:
            return "yellow-green"
        case 0.50..<0.70:
            return "yellow"
        case 0.25..<0.50:
            return "orange"
        case 0.01..<0.25:
            return "red-orange"
        default:
            return "gray"
        }
    }

    /// Get opacity for freshness fraction.
    ///
    /// Higher freshness = more opaque.
    ///
    /// - Parameter fraction: Freshness fraction from 0.0 to 1.0.
    /// - Returns: Opacity value from 0.3 to 1.0.
    static func opacity(for fraction: Double) -> Double {
        // Minimum opacity of 0.3 to keep expired items visible
        return 0.3 + 0.7 * max(0, min(1, fraction))
    }
}

// MARK: - Accessibility Labels

/// Accessibility labels for freshness-related UI elements.
enum FreshnessAccessibility {
    /// Generate accessibility label for a neighbor's freshness.
    static func neighbor(_ fraction: Double, callsign: String) -> String {
        let percent = Int(round(fraction * 100))
        let status = FreshnessCalculator.freshnessStatus(fraction: fraction)
        let colorName = FreshnessColors.colorName(for: fraction)
        if percent > 0 {
            return "Neighbor \(callsign) is \(status.lowercased()), \(percent) percent fresh, shown in \(colorName)."
        }
        return "Neighbor \(callsign) has expired, shown in \(colorName)."
    }

    /// Generate accessibility label for a route's freshness.
    static func route(_ fraction: Double, destination: String) -> String {
        let percent = Int(round(fraction * 100))
        let status = FreshnessCalculator.freshnessStatus(fraction: fraction)
        let colorName = FreshnessColors.colorName(for: fraction)
        if percent > 0 {
            return "Route to \(destination) is \(status.lowercased()), \(percent) percent fresh, shown in \(colorName)."
        }
        return "Route to \(destination) has expired, shown in \(colorName)."
    }

    /// Generate accessibility label for a link stat's freshness.
    static func linkStat(_ fraction: Double, from: String, to: String) -> String {
        let percent = Int(round(fraction * 100))
        let status = FreshnessCalculator.freshnessStatus(fraction: fraction)
        let colorName = FreshnessColors.colorName(for: fraction)
        if percent > 0 {
            return "Link from \(from) to \(to) is \(status.lowercased()), \(percent) percent fresh, shown in \(colorName)."
        }
        return "Link from \(from) to \(to) has expired, shown in \(colorName)."
    }
}

/// Legacy accessibility labels.
/// - Note: Deprecated. Use FreshnessAccessibility instead.
@available(*, deprecated, message: "Use FreshnessAccessibility instead")
enum DecayAccessibility {
    static func neighborDecay(_ fraction: Double, callsign: String) -> String {
        FreshnessAccessibility.neighbor(fraction, callsign: callsign)
    }

    static func routeDecay(_ fraction: Double, destination: String) -> String {
        FreshnessAccessibility.route(fraction, destination: destination)
    }

    static func linkStatDecay(_ fraction: Double, from: String, to: String) -> String {
        FreshnessAccessibility.linkStat(fraction, from: from, to: to)
    }
}
