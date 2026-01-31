//
//  StationIdentity.swift
//  AXTerm
//
//  Station identity abstraction for SSID grouping in the network graph.
//  See Docs/NetworkGraphSemantics.md for full documentation.
//

import Foundation

/// Mode for grouping stations in the network graph.
///
/// - **station**: Group all SSIDs under a single base callsign (e.g., ANH, ANH-1, ANH-15 => "ANH")
/// - **ssid**: Show each SSID as a separate node (e.g., ANH and ANH-15 are distinct)
enum StationIdentityMode: String, CaseIterable, Codable, Sendable {
    case station = "station"    // Group by base callsign (default)
    case ssid = "ssid"          // Split by full callsign with SSID

    /// Human-readable label for UI
    var displayName: String {
        switch self {
        case .station: return "Group by Station"
        case .ssid: return "Split by SSID"
        }
    }

    /// Short label for compact UI
    var shortName: String {
        switch self {
        case .station: return "Station"
        case .ssid: return "SSID"
        }
    }

    /// Tooltip description
    var tooltip: String {
        switch self {
        case .station:
            return "Group all SSIDs under one station node. ANH, ANH-1, and ANH-15 appear as a single \"ANH\" node."
        case .ssid:
            return "Show each SSID as a separate node. ANH and ANH-15 appear as distinct nodes."
        }
    }
}

/// Parsed callsign components.
struct ParsedCallsign: Hashable, Sendable {
    /// Base callsign (uppercase, no SSID suffix)
    let base: String

    /// SSID value (0-15), nil if not present or 0
    let ssid: Int?

    /// Full callsign string (base + optional SSID suffix)
    var full: String {
        if let ssid, ssid > 0 {
            return "\(base)-\(ssid)"
        }
        return base
    }

    /// Returns the identity key based on the mode.
    func identityKey(for mode: StationIdentityMode) -> String {
        switch mode {
        case .station: return base
        case .ssid: return full
        }
    }
}

/// Key for identifying a station node in the graph.
///
/// The key's string representation depends on the identity mode:
/// - `.station`: Uses base callsign only (e.g., "ANH")
/// - `.ssid`: Uses full callsign with SSID (e.g., "ANH-15")
struct StationKey: Hashable, Sendable {
    /// Base callsign (uppercase)
    let base: String

    /// SSID value (nil if not present or 0)
    let ssid: Int?

    /// Identity mode used to generate the key
    let mode: StationIdentityMode

    /// The string ID used as the node identifier
    var id: String {
        switch mode {
        case .station:
            return base
        case .ssid:
            if let ssid, ssid > 0 {
                return "\(base)-\(ssid)"
            }
            return base
        }
    }

    /// Full callsign (base + SSID if present)
    var fullCallsign: String {
        if let ssid, ssid > 0 {
            return "\(base)-\(ssid)"
        }
        return base
    }

    /// Creates a station key from a parsed callsign.
    init(parsed: ParsedCallsign, mode: StationIdentityMode) {
        self.base = parsed.base
        self.ssid = parsed.ssid
        self.mode = mode
    }

    /// Creates a station key from base and SSID components.
    init(base: String, ssid: Int?, mode: StationIdentityMode) {
        self.base = base.uppercased()
        self.ssid = ssid
        self.mode = mode
    }

    /// Creates a station key from a full callsign string.
    init(callsign: String, mode: StationIdentityMode) {
        let parsed = CallsignParser.parse(callsign)
        self.base = parsed.base
        self.ssid = parsed.ssid
        self.mode = mode
    }
}

/// Utilities for parsing callsigns and extracting SSID components.
enum CallsignParser {
    /// Parse a callsign string into base and SSID components.
    ///
    /// Examples:
    /// - "ANH-15" => (base: "ANH", ssid: 15)
    /// - "ANH" => (base: "ANH", ssid: nil)
    /// - "W5ABC-0" => (base: "W5ABC", ssid: nil) // SSID 0 is treated as nil
    /// - "n0call" => (base: "N0CALL", ssid: nil)
    static func parse(_ callsign: String) -> ParsedCallsign {
        let normalized = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard !normalized.isEmpty else {
            return ParsedCallsign(base: "", ssid: nil)
        }

        // Find the last dash that might indicate an SSID
        if let dashIndex = normalized.lastIndex(of: "-") {
            let basePart = String(normalized[..<dashIndex])
            let ssidPart = String(normalized[normalized.index(after: dashIndex)...])

            // Try to parse SSID as integer (0-15)
            if let ssidValue = Int(ssidPart), ssidValue >= 0, ssidValue <= 15 {
                // SSID 0 is equivalent to no SSID
                let effectiveSSID = ssidValue > 0 ? ssidValue : nil
                return ParsedCallsign(base: basePart, ssid: effectiveSSID)
            }
        }

        // No valid SSID suffix found
        return ParsedCallsign(base: normalized, ssid: nil)
    }

    /// Parse a callsign and return its identity key for the given mode.
    static func identityKey(for callsign: String, mode: StationIdentityMode) -> String {
        let parsed = parse(callsign)
        return parsed.identityKey(for: mode)
    }

    /// Normalize a base callsign (uppercase, trimmed).
    static func normalizeBase(_ base: String) -> String {
        base.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

// MARK: - Grouped Station Info

/// Information about a grouped station node.
struct GroupedStationInfo: Hashable, Sendable {
    /// The identity key (base callsign in station mode, full callsign in ssid mode)
    let identityKey: String

    /// All SSIDs that belong to this group
    let members: [SSIDMember]

    /// Total packet count across all members
    var totalPackets: Int {
        members.reduce(0) { $0 + $1.packetCount }
    }

    /// Most recent last heard time across all members
    var lastHeard: Date? {
        members.compactMap { $0.lastHeard }.max()
    }

    /// Display string showing grouped identities (e.g., "ANH, ANH-1, ANH-15")
    var membersDisplayShort: String {
        let sorted = members.sorted { ($0.ssid ?? 0) < ($1.ssid ?? 0) }
        let names = sorted.prefix(4).map { $0.fullCallsign }
        if members.count > 4 {
            return names.joined(separator: ", ") + " +\(members.count - 4) more"
        }
        return names.joined(separator: ", ")
    }

    /// Whether this represents multiple SSIDs grouped together
    var isGrouped: Bool {
        members.count > 1
    }
}

/// Member of a grouped station (individual SSID).
struct SSIDMember: Hashable, Sendable, Identifiable {
    var id: String { fullCallsign }

    /// Base callsign
    let base: String

    /// SSID value (nil if not present)
    let ssid: Int?

    /// Packet count for this specific SSID
    let packetCount: Int

    /// Last heard time for this specific SSID
    let lastHeard: Date?

    /// Full callsign string
    var fullCallsign: String {
        if let ssid, ssid > 0 {
            return "\(base)-\(ssid)"
        }
        return base
    }
}

// MARK: - Station Aggregator

/// Aggregates packet data by station identity.
struct StationAggregator {
    private var memberData: [String: [String: SSIDMemberAggregate]] = [:] // identityKey -> fullCallsign -> data

    /// Record a callsign sighting.
    mutating func record(callsign: String, mode: StationIdentityMode, timestamp: Date, packetCount: Int = 1) {
        let parsed = CallsignParser.parse(callsign)
        let identityKey = parsed.identityKey(for: mode)
        let fullCallsign = parsed.full

        var keyData = memberData[identityKey, default: [:]]
        var memberAgg = keyData[fullCallsign, default: SSIDMemberAggregate(
            base: parsed.base,
            ssid: parsed.ssid
        )]
        memberAgg.packetCount += packetCount
        memberAgg.lastHeard = max(memberAgg.lastHeard ?? .distantPast, timestamp)
        keyData[fullCallsign] = memberAgg
        memberData[identityKey] = keyData
    }

    /// Get grouped station info for an identity key.
    func groupedInfo(for identityKey: String) -> GroupedStationInfo? {
        guard let keyData = memberData[identityKey] else { return nil }

        let members = keyData.values.map { agg in
            SSIDMember(
                base: agg.base,
                ssid: agg.ssid,
                packetCount: agg.packetCount,
                lastHeard: agg.lastHeard
            )
        }

        return GroupedStationInfo(identityKey: identityKey, members: members)
    }

    /// Get all identity keys.
    var allIdentityKeys: [String] {
        Array(memberData.keys)
    }
}

private struct SSIDMemberAggregate {
    let base: String
    let ssid: Int?
    var packetCount: Int = 0
    var lastHeard: Date?
}
