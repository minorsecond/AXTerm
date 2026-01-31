//
//  NetRomRoutesViewModel.swift
//  AXTerm
//
//  ViewModel for the NET/ROM Routes page displaying neighbors, routes, and link quality.
//

import Combine
import Foundation
import SwiftUI

/// Tab selection for the Routes page.
enum NetRomRoutesTab: String, CaseIterable, Identifiable {
    case neighbors = "Neighbors"
    case routes = "Routes"
    case linkQuality = "Link Quality"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .neighbors: return "person.2"
        case .routes: return "arrow.triangle.branch"
        case .linkQuality: return "chart.bar"
        }
    }
}

/// Display model for a neighbor row.
struct NeighborDisplayInfo: Identifiable, Hashable {
    let id: String
    let callsign: String
    let quality: Int
    let qualityPercent: Double
    let sourceType: String
    let lastSeen: Date
    let lastSeenRelative: String

    /// Time-based freshness fraction (0.0-1.0).
    let freshness: Double

    /// Freshness as percentage string (e.g., "95%").
    let freshnessDisplayString: String

    /// Freshness mapped to 0-255 scale.
    let freshness255: Int

    /// Freshness status label (Fresh, Recent, Stale, Expired).
    let freshnessStatus: String

    /// Default TTL for neighbor freshness (30 minutes).
    private static let defaultTTL: TimeInterval = FreshnessCalculator.defaultTTL

    /// Default plateau duration (5 minutes).
    private static let defaultPlateau: TimeInterval = FreshnessCalculator.defaultPlateau

    init(from info: NeighborInfo, now: Date, ttl: TimeInterval = NeighborDisplayInfo.defaultTTL, plateau: TimeInterval = NeighborDisplayInfo.defaultPlateau) {
        self.id = info.call
        self.callsign = info.call
        self.quality = info.quality
        self.qualityPercent = Double(info.quality) / 255.0 * 100.0
        self.sourceType = info.sourceType
        self.lastSeen = info.lastSeen
        self.lastSeenRelative = Self.formatRelativeTime(info.lastSeen, now: now)

        // Compute time-based freshness using plateau + smoothstep curve
        self.freshness = info.freshness(now: now, ttl: ttl, plateau: plateau)
        self.freshnessDisplayString = info.freshnessDisplayString(now: now, ttl: ttl, plateau: plateau)
        self.freshness255 = info.freshness255(now: now, ttl: ttl, plateau: plateau)
        self.freshnessStatus = info.freshnessStatus(now: now, ttl: ttl, plateau: plateau)
    }

    private static func formatRelativeTime(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)

        if interval < 0 {
            return "Future"
        } else if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }

    /// Apple HIG tooltip for neighbor freshness column.
    static let freshnessTooltip = FreshnessTooltips.neighbors

    /// Accessibility label for this neighbor's freshness.
    var freshnessAccessibilityLabel: String {
        FreshnessAccessibility.neighbor(freshness, callsign: callsign)
    }

    /// Color for freshness display.
    var freshnessColor: SwiftUI.Color {
        FreshnessColors.color(for: freshness)
    }

    // MARK: Legacy Decay Properties (Deprecated)

    /// Time-based decay fraction (0.0-1.0).
    /// - Note: Deprecated. Use `freshness` instead.
    @available(*, deprecated, message: "Use freshness instead")
    var decayFraction: Double { freshness }

    /// Decay as percentage string (e.g., "75%").
    /// - Note: Deprecated. Use `freshnessDisplayString` instead.
    @available(*, deprecated, message: "Use freshnessDisplayString instead")
    var decayDisplayString: String { freshnessDisplayString }

    /// Decay mapped to 0-255 scale.
    /// - Note: Deprecated. Use `freshness255` instead.
    @available(*, deprecated, message: "Use freshness255 instead")
    var decay255: Int { freshness255 }

    /// Apple HIG tooltip for neighbor decay column.
    /// - Note: Deprecated. Use `freshnessTooltip` instead.
    @available(*, deprecated, message: "Use freshnessTooltip instead")
    static let decayTooltip = FreshnessTooltips.neighbors

    /// Accessibility label for this neighbor's decay.
    /// - Note: Deprecated. Use `freshnessAccessibilityLabel` instead.
    @available(*, deprecated, message: "Use freshnessAccessibilityLabel instead")
    var decayAccessibilityLabel: String { freshnessAccessibilityLabel }
}

/// Display model for a route row.
struct RouteDisplayInfo: Identifiable, Hashable {
    let id: String
    let destination: String
    let nextHop: String
    let quality: Int
    let qualityPercent: Double
    let sourceType: String
    let path: [String]
    let pathSummary: String
    let hopCount: Int
    let lastUpdated: Date
    let lastUpdatedRelative: String

    /// Time-based freshness fraction (0.0-1.0).
    let freshness: Double

    /// Freshness as percentage string (e.g., "95%").
    let freshnessDisplayString: String

    /// Freshness mapped to 0-255 scale.
    let freshness255: Int

    /// Freshness status label (Fresh, Recent, Stale, Expired).
    let freshnessStatus: String

    /// Default TTL for route freshness (30 minutes).
    private static let defaultTTL: TimeInterval = FreshnessCalculator.defaultTTL

    /// Default plateau duration (5 minutes).
    private static let defaultPlateau: TimeInterval = FreshnessCalculator.defaultPlateau

    init(from info: RouteInfo, now: Date, ttl: TimeInterval = RouteDisplayInfo.defaultTTL, plateau: TimeInterval = RouteDisplayInfo.defaultPlateau) {
        self.id = "\(info.destination)→\(info.origin)"
        self.destination = info.destination
        self.nextHop = info.path.first ?? info.origin
        self.quality = info.quality
        self.qualityPercent = Double(info.quality) / 255.0 * 100.0
        self.sourceType = info.sourceType
        self.path = info.path
        self.pathSummary = info.path.isEmpty ? info.origin : info.path.joined(separator: " → ")
        self.hopCount = max(1, info.path.count)
        self.lastUpdated = info.lastUpdated
        self.lastUpdatedRelative = Self.formatRelativeTime(info.lastUpdated, now: now)

        // Compute time-based freshness using plateau + smoothstep curve
        self.freshness = info.freshness(now: now, ttl: ttl, plateau: plateau)
        self.freshnessDisplayString = info.freshnessDisplayString(now: now, ttl: ttl, plateau: plateau)
        self.freshness255 = info.freshness255(now: now, ttl: ttl, plateau: plateau)
        self.freshnessStatus = info.freshnessStatus(now: now, ttl: ttl, plateau: plateau)
    }

    private static func formatRelativeTime(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)

        if interval < 0 {
            return "Future"
        } else if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }

    /// Apple HIG tooltip for route freshness column.
    static let freshnessTooltip = FreshnessTooltips.routes

    /// Accessibility label for this route's freshness.
    var freshnessAccessibilityLabel: String {
        FreshnessAccessibility.route(freshness, destination: destination)
    }

    /// Color for freshness display.
    var freshnessColor: SwiftUI.Color {
        FreshnessColors.color(for: freshness)
    }

    // MARK: Legacy Decay Properties (Deprecated)

    /// Time-based decay fraction (0.0-1.0).
    /// - Note: Deprecated. Use `freshness` instead.
    @available(*, deprecated, message: "Use freshness instead")
    var decayFraction: Double { freshness }

    /// Decay as percentage string (e.g., "75%").
    /// - Note: Deprecated. Use `freshnessDisplayString` instead.
    @available(*, deprecated, message: "Use freshnessDisplayString instead")
    var decayDisplayString: String { freshnessDisplayString }

    /// Decay mapped to 0-255 scale.
    /// - Note: Deprecated. Use `freshness255` instead.
    @available(*, deprecated, message: "Use freshness255 instead")
    var decay255: Int { freshness255 }

    /// Apple HIG tooltip for route decay column.
    /// - Note: Deprecated. Use `freshnessTooltip` instead.
    @available(*, deprecated, message: "Use freshnessTooltip instead")
    static let decayTooltip = FreshnessTooltips.routes

    /// Accessibility label for this route's decay.
    /// - Note: Deprecated. Use `freshnessAccessibilityLabel` instead.
    @available(*, deprecated, message: "Use freshnessAccessibilityLabel instead")
    var decayAccessibilityLabel: String { freshnessAccessibilityLabel }
}

/// Display model for a link stat row.
struct LinkStatDisplayInfo: Identifiable, Hashable {
    let id: String
    let fromCall: String
    let toCall: String
    let quality: Int
    let qualityPercent: Double
    let dfEstimate: Double?
    let drEstimate: Double?
    let etx: Double?
    let duplicateCount: Int
    let lastUpdated: Date
    let lastUpdatedRelative: String

    /// Time-based freshness fraction (0.0-1.0).
    let freshness: Double

    /// Freshness as percentage string (e.g., "95%").
    let freshnessDisplayString: String

    /// Freshness mapped to 0-255 scale.
    let freshness255: Int

    /// Freshness status label (Fresh, Recent, Stale, Expired).
    let freshnessStatus: String

    /// Default TTL for link stat freshness (30 minutes).
    private static let defaultTTL: TimeInterval = FreshnessCalculator.defaultTTL

    /// Default plateau duration (5 minutes).
    private static let defaultPlateau: TimeInterval = FreshnessCalculator.defaultPlateau

    init(from record: LinkStatRecord, now: Date, ttl: TimeInterval = LinkStatDisplayInfo.defaultTTL, plateau: TimeInterval = LinkStatDisplayInfo.defaultPlateau) {
        self.id = "\(record.fromCall)→\(record.toCall)"
        self.fromCall = record.fromCall
        self.toCall = record.toCall
        self.quality = record.quality
        self.qualityPercent = Double(record.quality) / 255.0 * 100.0
        self.dfEstimate = record.dfEstimate
        self.drEstimate = record.drEstimate

        // Calculate ETX if both df and dr are available
        if let df = record.dfEstimate, let dr = record.drEstimate, df > 0, dr > 0 {
            self.etx = 1.0 / (df * dr)
        } else if let df = record.dfEstimate, df > 0 {
            self.etx = 1.0 / df
        } else {
            self.etx = nil
        }

        self.duplicateCount = record.duplicateCount
        self.lastUpdated = record.lastUpdated
        self.lastUpdatedRelative = Self.formatRelativeTime(record.lastUpdated, now: now)

        // Compute time-based freshness using plateau + smoothstep curve
        self.freshness = record.freshness(now: now, ttl: ttl, plateau: plateau)
        self.freshnessDisplayString = record.freshnessDisplayString(now: now, ttl: ttl, plateau: plateau)
        self.freshness255 = record.freshness255(now: now, ttl: ttl, plateau: plateau)
        self.freshnessStatus = record.freshnessStatus(now: now, ttl: ttl, plateau: plateau)
    }

    private static func formatRelativeTime(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)

        if interval < 0 {
            return "Future"
        } else if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }

    /// Apple HIG tooltip for link stat freshness column.
    static let freshnessTooltip = FreshnessTooltips.linkStats

    /// Accessibility label for this link stat's freshness.
    var freshnessAccessibilityLabel: String {
        FreshnessAccessibility.linkStat(freshness, from: fromCall, to: toCall)
    }

    /// Color for freshness display.
    var freshnessColor: Color {
        FreshnessColors.color(for: freshness)
    }

    // MARK: Legacy Decay Properties (Deprecated)

    /// Time-based decay fraction (0.0-1.0).
    /// - Note: Deprecated. Use `freshness` instead.
    @available(*, deprecated, message: "Use freshness instead")
    var decayFraction: Double { freshness }

    /// Decay as percentage string (e.g., "75%").
    /// - Note: Deprecated. Use `freshnessDisplayString` instead.
    @available(*, deprecated, message: "Use freshnessDisplayString instead")
    var decayDisplayString: String { freshnessDisplayString }

    /// Decay mapped to 0-255 scale.
    /// - Note: Deprecated. Use `freshness255` instead.
    @available(*, deprecated, message: "Use freshness255 instead")
    var decay255: Int { freshness255 }

    /// Apple HIG tooltip for link stat decay column.
    /// - Note: Deprecated. Use `freshnessTooltip` instead.
    @available(*, deprecated, message: "Use freshnessTooltip instead")
    static let decayTooltip = FreshnessTooltips.linkStats

    /// Accessibility label for this link stat's decay.
    /// - Note: Deprecated. Use `freshnessAccessibilityLabel` instead.
    @available(*, deprecated, message: "Use freshnessAccessibilityLabel instead")
    var decayAccessibilityLabel: String { freshnessAccessibilityLabel }
}

/// ViewModel for the NET/ROM Routes page.
@MainActor
final class NetRomRoutesViewModel: ObservableObject {
    @Published var selectedTab: NetRomRoutesTab = .neighbors
    @Published var searchText: String = ""
    @Published var routingMode: NetRomRoutingMode = .hybrid

    @Published private(set) var neighbors: [NeighborDisplayInfo] = []
    @Published private(set) var routes: [RouteDisplayInfo] = []
    @Published private(set) var linkStats: [LinkStatDisplayInfo] = []

    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?

    #if DEBUG
    @Published private(set) var isRebuilding = false
    @Published private(set) var rebuildProgress: Double = 0
    @Published private(set) var lastRebuildResult: String?
    #endif

    private weak var integration: NetRomIntegration?
    private weak var packetEngine: PacketEngine?
    private weak var settings: AppSettingsStore?
    private let clock: ClockProviding
    private var refreshTimer: Timer?

    /// Cached origin intervals for adaptive TTL calculation
    private var originIntervals: [String: OriginIntervalInfo] = [:]

    /// Computed global TTL based on settings (in seconds)
    private var globalStaleTTLSeconds: TimeInterval {
        TimeInterval((settings?.globalStaleTTLHours ?? AppSettingsStore.defaultGlobalStaleTTLHours) * 3600)
    }

    /// Whether adaptive stale policy is enabled
    private var isAdaptiveMode: Bool {
        (settings?.stalePolicyMode ?? AppSettingsStore.defaultStalePolicyMode) == "adaptive"
    }

    /// Number of missed broadcasts before considering stale (for adaptive mode)
    private var missedBroadcastsThreshold: Int {
        settings?.adaptiveStaleMissedBroadcasts ?? AppSettingsStore.defaultAdaptiveStaleMissedBroadcasts
    }

    /// Whether to filter out expired entries based on settings
    private var shouldHideExpired: Bool {
        settings?.hideExpiredRoutes ?? AppSettingsStore.defaultHideExpiredRoutes
    }

    /// Get adaptive TTL for a specific origin, or fall back to global TTL.
    ///
    /// - Parameter origin: The origin callsign.
    /// - Returns: TTL in seconds based on the origin's broadcast interval, or global TTL if unavailable.
    private func adaptiveTTL(for origin: String) -> TimeInterval {
        guard isAdaptiveMode else {
            return globalStaleTTLSeconds
        }

        let normalizedOrigin = CallsignValidator.normalize(origin)
        if let intervalInfo = originIntervals[normalizedOrigin],
           intervalInfo.estimatedIntervalSeconds > 0 {
            // TTL = interval * missed broadcasts threshold
            return intervalInfo.estimatedIntervalSeconds * Double(missedBroadcastsThreshold)
        }

        // Fall back to global TTL if no interval data
        return globalStaleTTLSeconds
    }

    init(integration: NetRomIntegration?, packetEngine: PacketEngine? = nil, settings: AppSettingsStore? = nil, clock: ClockProviding = SystemClock()) {
        self.integration = integration
        self.packetEngine = packetEngine
        self.settings = settings
        self.clock = clock
        startAutoRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Filtered Data

    var filteredNeighbors: [NeighborDisplayInfo] {
        var result = neighbors

        // Filter by expiration if enabled
        if shouldHideExpired {
            result = result.filter { $0.freshness > 0 }
        }

        // Filter by search text
        if !searchText.isEmpty {
            let query = searchText.uppercased()
            result = result.filter { $0.callsign.uppercased().contains(query) }
        }

        return result
    }

    var filteredRoutes: [RouteDisplayInfo] {
        var result = routes

        // Filter by expiration if enabled
        if shouldHideExpired {
            result = result.filter { $0.freshness > 0 }
        }

        // Filter by search text
        if !searchText.isEmpty {
            let query = searchText.uppercased()
            result = result.filter {
                $0.destination.uppercased().contains(query) ||
                $0.nextHop.uppercased().contains(query) ||
                $0.pathSummary.uppercased().contains(query)
            }
        }

        return result
    }

    var filteredLinkStats: [LinkStatDisplayInfo] {
        var result = linkStats

        // Filter by expiration if enabled
        if shouldHideExpired {
            result = result.filter { $0.freshness > 0 }
        }

        // Filter by search text
        if !searchText.isEmpty {
            let query = searchText.uppercased()
            result = result.filter {
                $0.fromCall.uppercased().contains(query) ||
                $0.toCall.uppercased().contains(query)
            }
        }

        return result
    }

    // MARK: - Actions

    private var hasLoggedFirstRefresh = false

    func refresh() {
        guard let integration else {
            #if DEBUG
            if !hasLoggedFirstRefresh {
                print("[NETROM:VIEWMODEL] ❌ refresh() called but integration is nil")
                hasLoggedFirstRefresh = true
            }
            #endif
            return
        }

        isLoading = true
        let now = clock.now

        // Update mode if changed
        if integration.currentMode != routingMode {
            integration.setMode(routingMode)
        }

        // Load origin intervals for adaptive TTL calculation
        let intervals = integration.getAllOriginIntervals()
        originIntervals = Dictionary(uniqueKeysWithValues: intervals.map { ($0.origin, $0) })

        // Fetch current data filtered by mode
        let rawNeighbors = integration.currentNeighbors(forMode: routingMode)
        let rawRoutes = integration.currentRoutes(forMode: routingMode)
        let rawLinkStats = integration.exportLinkStats(forMode: routingMode)

        #if DEBUG
        if !hasLoggedFirstRefresh {
            print("[NETROM:VIEWMODEL] ========== First Refresh ==========")
            print("[NETROM:VIEWMODEL] Mode: \(routingMode)")
            print("[NETROM:VIEWMODEL] Raw data from integration:")
            print("[NETROM:VIEWMODEL]   - Neighbors: \(rawNeighbors.count)")
            for (i, n) in rawNeighbors.prefix(3).enumerated() {
                print("[NETROM:VIEWMODEL]     [\(i)] \(n.call) quality=\(n.quality) source=\(n.sourceType)")
            }
            if rawNeighbors.count > 3 { print("[NETROM:VIEWMODEL]     ... and \(rawNeighbors.count - 3) more") }

            print("[NETROM:VIEWMODEL]   - Routes: \(rawRoutes.count)")
            for (i, r) in rawRoutes.prefix(3).enumerated() {
                print("[NETROM:VIEWMODEL]     [\(i)] \(r.destination) via \(r.origin) quality=\(r.quality)")
            }
            if rawRoutes.count > 3 { print("[NETROM:VIEWMODEL]     ... and \(rawRoutes.count - 3) more") }

            print("[NETROM:VIEWMODEL]   - LinkStats: \(rawLinkStats.count)")
            for (i, s) in rawLinkStats.prefix(3).enumerated() {
                let dfStr = s.dfEstimate.map { String(format: "%.2f", $0) } ?? "nil"
                let drStr = s.drEstimate.map { String(format: "%.2f", $0) } ?? "nil"
                print("[NETROM:VIEWMODEL]     [\(i)] \(s.fromCall)→\(s.toCall) quality=\(s.quality) df=\(dfStr) dr=\(drStr) obs=\(s.observationCount)")
            }
            if rawLinkStats.count > 3 { print("[NETROM:VIEWMODEL]     ... and \(rawLinkStats.count - 3) more") }

            // Diagnose link stats data quality
            let statsWithNilDf = rawLinkStats.filter { $0.dfEstimate == nil }.count
            let statsWithNilDr = rawLinkStats.filter { $0.drEstimate == nil }.count
            let statsWithZeroObs = rawLinkStats.filter { $0.observationCount == 0 }.count
            let statsWithBadTimestamp = rawLinkStats.filter { now.timeIntervalSince($0.lastUpdated) > 365 * 24 * 60 * 60 }.count

            if statsWithNilDf > 0 || statsWithNilDr > 0 || statsWithBadTimestamp > 0 {
                print("[NETROM:VIEWMODEL] ========== Link Quality Diagnostics ==========")

                if statsWithNilDf > 0 {
                    print("[NETROM:VIEWMODEL] ℹ️ \(statsWithNilDf)/\(rawLinkStats.count) links have nil df (forward delivery ratio)")
                    print("[NETROM:VIEWMODEL]    WHY: df requires observationCount > 0")
                    print("[NETROM:VIEWMODEL]    FIX: Links will populate df as new packets are observed")
                }

                if statsWithNilDr > 0 {
                    print("[NETROM:VIEWMODEL] ℹ️ \(statsWithNilDr)/\(rawLinkStats.count) links have nil dr (reverse delivery ratio)")
                    print("[NETROM:VIEWMODEL]    WHY: dr requires bidirectional ACK analysis (not yet implemented)")
                    print("[NETROM:VIEWMODEL]    NOTE: This is normal - AX.25 UI frames have no ACKs")
                }

                if statsWithZeroObs > 0 {
                    print("[NETROM:VIEWMODEL] ⚠️ \(statsWithZeroObs)/\(rawLinkStats.count) links have 0 observations")
                    print("[NETROM:VIEWMODEL]    WHY: Loaded from persistence but no new packets received")
                    print("[NETROM:VIEWMODEL]    FIX: Observations will accumulate as new packets arrive")
                }

                if statsWithBadTimestamp > 0 {
                    print("[NETROM:VIEWMODEL] ❌ \(statsWithBadTimestamp)/\(rawLinkStats.count) links have invalid timestamps (>1 year old)")
                    print("[NETROM:VIEWMODEL]    WHY: Date.distantPast was used as fallback in old persistence")
                    print("[NETROM:VIEWMODEL]    FIX: These will be sanitized on next observation or re-export")
                }

                print("[NETROM:VIEWMODEL] ========== End Diagnostics ==========")
            }

            if rawNeighbors.isEmpty {
                print("[NETROM:VIEWMODEL] ⚠️ Neighbors is EMPTY - this means:")
                print("[NETROM:VIEWMODEL]    - No direct packets (via.isEmpty) have been observed")
                print("[NETROM:VIEWMODEL]    - OR neighbors were not imported from persistence")
            }

            if rawRoutes.isEmpty {
                print("[NETROM:VIEWMODEL] ⚠️ Routes is EMPTY - this means:")
                print("[NETROM:VIEWMODEL]    - No NET/ROM broadcasts received")
                print("[NETROM:VIEWMODEL]    - OR routes were not imported from persistence")
            }

            print("[NETROM:VIEWMODEL] ========== End First Refresh ==========")
            hasLoggedFirstRefresh = true
        }
        #endif

        // Convert to display models using configured TTL
        // For neighbors and link stats, use global TTL
        // For routes, use adaptive TTL based on origin broadcast interval if enabled
        let globalTTL = globalStaleTTLSeconds
        neighbors = rawNeighbors.map { NeighborDisplayInfo(from: $0, now: now, ttl: globalTTL) }

        // Routes use adaptive TTL per-origin when adaptive mode is enabled
        routes = rawRoutes.map { route in
            let ttl = adaptiveTTL(for: route.origin)
            return RouteDisplayInfo(from: route, now: now, ttl: ttl)
        }

        linkStats = rawLinkStats.map { LinkStatDisplayInfo(from: $0, now: now, ttl: globalTTL) }

        lastRefresh = now
        isLoading = false
    }

    func setMode(_ mode: NetRomRoutingMode) {
        routingMode = mode
        integration?.setMode(mode)
        refresh()
    }

    // MARK: - Export

    func copyNeighborsAsJSON() -> String {
        let data = filteredNeighbors.map { neighbor -> [String: Any] in
            [
                "callsign": neighbor.callsign,
                "quality": neighbor.quality,
                "qualityPercent": String(format: "%.1f", neighbor.qualityPercent),
                "sourceType": neighbor.sourceType,
                "lastSeen": ISO8601DateFormatter().string(from: neighbor.lastSeen),
                "freshnessPercent": neighbor.freshnessDisplayString,
                "freshness255": neighbor.freshness255,
                "freshnessStatus": neighbor.freshnessStatus
            ]
        }
        return formatJSON(data)
    }

    func copyNeighborsAsCSV() -> String {
        var lines = ["Callsign,Quality,Quality %,Source,Last Seen,Freshness %,Freshness 0-255,Status"]
        for n in filteredNeighbors {
            lines.append("\(n.callsign),\(n.quality),\(String(format: "%.1f", n.qualityPercent)),\(n.sourceType),\(ISO8601DateFormatter().string(from: n.lastSeen)),\(n.freshnessDisplayString),\(n.freshness255),\(n.freshnessStatus)")
        }
        return lines.joined(separator: "\n")
    }

    func copyRoutesAsJSON() -> String {
        let data = filteredRoutes.map { route -> [String: Any] in
            [
                "destination": route.destination,
                "nextHop": route.nextHop,
                "quality": route.quality,
                "qualityPercent": String(format: "%.1f", route.qualityPercent),
                "sourceType": route.sourceType,
                "path": route.path,
                "hopCount": route.hopCount,
                "lastUpdated": ISO8601DateFormatter().string(from: route.lastUpdated),
                "freshnessPercent": route.freshnessDisplayString,
                "freshness255": route.freshness255,
                "freshnessStatus": route.freshnessStatus
            ]
        }
        return formatJSON(data)
    }

    func copyRoutesAsCSV() -> String {
        var lines = ["Destination,Next Hop,Quality,Quality %,Source,Path,Hops,Last Updated,Freshness %,Freshness 0-255,Status"]
        for r in filteredRoutes {
            let pathStr = r.path.joined(separator: " > ")
            lines.append("\(r.destination),\(r.nextHop),\(r.quality),\(String(format: "%.1f", r.qualityPercent)),\(r.sourceType),\"\(pathStr)\",\(r.hopCount),\(ISO8601DateFormatter().string(from: r.lastUpdated)),\(r.freshnessDisplayString),\(r.freshness255),\(r.freshnessStatus)")
        }
        return lines.joined(separator: "\n")
    }

    func copyLinkStatsAsJSON() -> String {
        let data = filteredLinkStats.map { stat -> [String: Any] in
            var dict: [String: Any] = [
                "from": stat.fromCall,
                "to": stat.toCall,
                "quality": stat.quality,
                "qualityPercent": String(format: "%.1f", stat.qualityPercent),
                "duplicateCount": stat.duplicateCount,
                "lastUpdated": ISO8601DateFormatter().string(from: stat.lastUpdated),
                "freshnessPercent": stat.freshnessDisplayString,
                "freshness255": stat.freshness255,
                "freshnessStatus": stat.freshnessStatus
            ]
            if let df = stat.dfEstimate { dict["dfEstimate"] = String(format: "%.3f", df) }
            if let dr = stat.drEstimate { dict["drEstimate"] = String(format: "%.3f", dr) }
            if let etx = stat.etx { dict["etx"] = String(format: "%.2f", etx) }
            return dict
        }
        return formatJSON(data)
    }

    func copyLinkStatsAsCSV() -> String {
        var lines = ["From,To,Quality,Quality %,df,dr,ETX,Duplicates,Last Updated,Freshness %,Freshness 0-255,Status"]
        for s in filteredLinkStats {
            let df = s.dfEstimate.map { String(format: "%.3f", $0) } ?? ""
            let dr = s.drEstimate.map { String(format: "%.3f", $0) } ?? ""
            let etx = s.etx.map { String(format: "%.2f", $0) } ?? ""
            lines.append("\(s.fromCall),\(s.toCall),\(s.quality),\(String(format: "%.1f", s.qualityPercent)),\(df),\(dr),\(etx),\(s.duplicateCount),\(ISO8601DateFormatter().string(from: s.lastUpdated)),\(s.freshnessDisplayString),\(s.freshness255),\(s.freshnessStatus)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Debug Rebuild

    #if DEBUG
    /// Rebuild all NET/ROM data from scratch by replaying all packets in the database.
    func debugRebuildFromPackets() {
        guard let engine = packetEngine else {
            lastRebuildResult = "Error: PacketEngine not available"
            return
        }

        isRebuilding = true
        rebuildProgress = 0
        lastRebuildResult = nil

        Task {
            let result = await engine.debugRebuildNetRomFromPackets { [weak self] progress in
                Task { @MainActor in
                    self?.rebuildProgress = progress
                }
            }

            await MainActor.run {
                isRebuilding = false

                if result.success {
                    lastRebuildResult = """
                    Rebuild complete!
                    • Packets processed: \(result.packetsProcessed)
                    • Neighbors: \(result.neighborsFound)
                    • Routes: \(result.routesFound)
                    • Link Stats: \(result.linkStatsFound)
                    """
                } else {
                    lastRebuildResult = "Rebuild failed: \(result.errorMessage ?? "Unknown error")"
                }

                // Refresh the view
                refresh()
            }
        }
    }

    /// Whether debug rebuild is available.
    var canRebuild: Bool {
        packetEngine != nil && !isRebuilding
    }
    #endif

    // MARK: - Private

    private func startAutoRefresh() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func formatJSON(_ data: [[String: Any]]) -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) else {
            return "[]"
        }
        return String(data: jsonData, encoding: .utf8) ?? "[]"
    }
}
