//
//  GraphPathDrafting.swift
//  AXTerm
//
//  Draw a connection path on the network graph: click stations in order and
//  turn the drawn chain into a real connect. Every drawn hop is validated
//  against observed evidence — who actually digipeats (H-bit repeats), who has
//  repeated *your* frames, and who is a NET/ROM node rather than a digipeater.
//  Warnings, not blockers: RF is RF, and the operator decides.
//

import Foundation

// MARK: - Hop verdicts

nonisolated enum PathHopVerdict: Equatable, Sendable {
    /// This station has repeated frames from YOUR station — the hop is proven
    /// to work from your QTH.
    case provenDigi(repeats: Int)
    /// Observed repeating other stations' frames; plausible but not proven
    /// from your location.
    case observedDigi(repeats: Int)
    /// A NET/ROM node with no digipeat evidence: nodes route circuits, they do
    /// not repeat frames — connect to it as a destination instead.
    case nodeNotDigi
    /// No evidence this station digipeats at all.
    case unproven

    var isWarning: Bool {
        switch self {
        case .provenDigi, .observedDigi: return false
        case .nodeNotDigi, .unproven: return true
        }
    }

    var badgeText: String {
        switch self {
        case .provenDigi: return "PROVEN"
        case .observedDigi: return "DIGI"
        case .nodeNotDigi: return "NODE"
        case .unproven: return "UNPROVEN"
        }
    }

    var explanation: String {
        switch self {
        case .provenDigi(let repeats):
            return "Has repeated your own frames (\(repeats) observed repeats) — this hop is proven from your station."
        case .observedDigi(let repeats):
            return "Observed digipeating other stations (\(repeats) repeats), but never your frames — plausible, unproven from your QTH."
        case .nodeNotDigi:
            return "This is a NET/ROM node, not a digipeater: nodes route circuits and do not repeat frames. Connect to it as the destination and continue from its prompt."
        case .unproven:
            return "No evidence this station digipeats — frames sent via it will likely be lost."
        }
    }
}

// MARK: - Draft model

nonisolated struct PathDraftHop: Equatable, Sendable, Identifiable {
    let identityKey: String
    /// The concrete over-the-air callsign that will be transmitted.
    let displayCallsign: String
    let verdict: PathHopVerdict
    var id: String { identityKey }
}

/// Evidence needed to validate a drawn path — assembled by the dashboard view
/// model from the same insight data that powers the station directory.
nonisolated struct PathDraftContext: Equatable, Sendable {
    let roles: [String: Set<StationRole>]
    /// Observed H-bit repeats per station (any traffic).
    let digiRepeatCounts: [String: Int]
    /// Stations that have repeated frames sent by MY station.
    let provenDigisForMyStation: Set<String>
    /// Identity key -> most-heard over-the-air callsign (resolves SSID in
    /// station-grouped identity mode).
    let preferredDisplay: [String: String]

    static let empty = PathDraftContext(
        roles: [:], digiRepeatCounts: [:], provenDigisForMyStation: [], preferredDisplay: [:]
    )

    func display(for key: String) -> String {
        preferredDisplay[key] ?? key
    }
}

nonisolated struct PathDraft: Equatable, Sendable {
    let originKey: String
    let originDisplay: String
    /// Intermediate hops (validated as digipeaters).
    let viaHops: [PathDraftHop]
    /// Where the connect terminates; nil while only the origin exists.
    let destinationKey: String?
    let destinationDisplay: String?
    /// True when the destination is an inferred NET/ROM node or BBS — the
    /// terminal prompt will offer onward connects.
    let destinationIsInfrastructure: Bool
    let warnings: [String]

    /// The full drawn chain (origin + vias + destination) for canvas rendering.
    var chainKeys: [String] {
        var keys = [originKey] + viaHops.map(\.identityKey)
        if let destinationKey { keys.append(destinationKey) }
        return keys
    }

    var isConnectable: Bool { destinationKey != nil }

    var previewText: String {
        var parts = [originDisplay] + viaHops.map(\.displayCallsign)
        if let destinationDisplay { parts.append(destinationDisplay) }
        return parts.joined(separator: " \u{2192} ")
    }

    /// The connect this drawing means, ready for the ConnectCoordinator.
    func connectIntent() -> ConnectIntent? {
        guard let destinationDisplay else { return nil }
        let vias = viaHops.compactMap { Callsign($0.displayCallsign) }
        guard vias.count == viaHops.count else { return nil }
        let kind: ConnectKind = vias.isEmpty ? .ax25Direct : .ax25ViaDigis(vias)
        return ConnectIntent(
            kind: kind,
            to: destinationDisplay,
            sourceContext: .stations,
            suggestedRoutePreview: previewText,
            validationErrors: [],
            routeHint: nil,
            note: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
    }

    var connectMode: ConnectBarMode {
        viaHops.isEmpty ? .ax25 : .ax25ViaDigi
    }
}

// MARK: - Drafter

nonisolated enum GraphPathDrafter {
    /// Practical digi limit on 1200-baud channels: throughput roughly halves
    /// per hop and every retry re-traverses the full path.
    static let recommendedMaxVias = 2
    /// AX.25 protocol maximum.
    static let protocolMaxVias = 8

    /// Applies a node click to the drawn chain (origin excluded):
    /// - clicking the last station removes it (undo)
    /// - clicking an earlier station prunes back to it (it becomes destination)
    /// - clicking the origin clears the chain
    /// - clicking a new station appends it
    static func chain(after click: String, current: [String], originKey: String) -> [String] {
        if click == originKey { return [] }
        if let index = current.firstIndex(of: click) {
            if index == current.count - 1 {
                return Array(current.dropLast())
            }
            return Array(current.prefix(index + 1))
        }
        guard current.count < protocolMaxVias + 1 else { return current }
        return current + [click]
    }

    static func makeDraft(
        originKey: String,
        chain: [String],
        context: PathDraftContext
    ) -> PathDraft {
        let destinationKey = chain.last
        let viaKeys = chain.count > 1 ? Array(chain.dropLast()) : []

        let viaHops = viaKeys.map { key -> PathDraftHop in
            PathDraftHop(
                identityKey: key,
                displayCallsign: context.display(for: key),
                verdict: verdict(for: key, context: context)
            )
        }

        var warnings: [String] = []
        if viaHops.count > recommendedMaxVias {
            warnings.append("\(viaHops.count) digi hops: throughput roughly halves per hop and every retry re-traverses the whole path — 2 or fewer is strongly recommended.")
        }
        for hop in viaHops where hop.verdict.isWarning {
            warnings.append("\(hop.displayCallsign): \(hop.verdict.explanation)")
        }

        let destinationRoles = destinationKey.flatMap { context.roles[$0] } ?? []
        let destinationIsInfrastructure = destinationRoles.contains(.node) || destinationRoles.contains(.bbs)

        return PathDraft(
            originKey: originKey,
            originDisplay: context.display(for: originKey),
            viaHops: viaHops,
            destinationKey: destinationKey,
            destinationDisplay: destinationKey.map { context.display(for: $0) },
            destinationIsInfrastructure: destinationIsInfrastructure,
            warnings: warnings
        )
    }

    private static func verdict(for key: String, context: PathDraftContext) -> PathHopVerdict {
        let repeats = context.digiRepeatCounts[key] ?? 0
        if context.provenDigisForMyStation.contains(key) {
            return .provenDigi(repeats: repeats)
        }
        if repeats > 0 {
            return .observedDigi(repeats: repeats)
        }
        let roles = context.roles[key] ?? []
        if roles.contains(.node) || roles.contains(.bbs) {
            return .nodeNotDigi
        }
        return .unproven
    }
}
