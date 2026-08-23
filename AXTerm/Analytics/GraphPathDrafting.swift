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
    /// A NET/ROM node/BBS with no observed digipeat evidence. Many nodes have
    /// digipeating disabled (though stacks like BPQ can enable it) — the proven
    /// route is connecting to the node and continuing from its prompt.
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
            return "NET/ROM node with no observed digipeat evidence. Many nodes have digipeating disabled \u{2014} it may still work, but connecting to the node and continuing from its prompt is the proven route."
        case .unproven:
            return "No evidence this station digipeats — frames sent via it will likely be lost."
        }
    }
}

/// Evidence that MY station's RF can reach the first drawn station at all —
/// the one leg of the path my own transmitter must cover.
nonisolated enum PathHopReachability: Equatable, Sendable {
    /// A direct session between my station and this one has been observed
    /// (UA exchanged with no digipeat in the path) — a connect worked before.
    case provenConnect
    /// Heard direct off-air (frames with no repeated hop), but no session
    /// between us has been observed.
    case heardDirect(frames: Int)
    /// Never heard direct from this QTH — my RF may simply not reach it.
    case notHeardDirect

    var isWarning: Bool {
        if case .notHeardDirect = self { return true }
        return false
    }

    var badgeText: String {
        switch self {
        case .provenConnect: return "CONNECTED BEFORE"
        case .heardDirect: return "HEARD DIRECT"
        case .notHeardDirect: return "NOT HEARD DIRECT"
        }
    }

    var explanation: String {
        switch self {
        case .provenConnect:
            return "A direct session with this station has worked from your QTH before."
        case .heardDirect(let frames):
            return "Heard direct (\(frames) frame\(frames == 1 ? "" : "s")) but no direct session observed yet."
        case .notHeardDirect:
            return "Never heard direct from your station \u{2014} your RF may not reach it."
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
    /// Frames heard from each station with no repeated (H-bit) hop — proof the
    /// station is audible direct at my QTH.
    var directHeardCounts: [String: Int] = [:]
    /// Stations that have exchanged a direct UA with MY station — a completed
    /// direct connect (either direction) has been observed.
    var provenDirectConnects: Set<String> = []

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
    /// Whether my own RF has been shown to reach the FIRST drawn station —
    /// the only leg my transmitter must cover. Nil while the chain is empty.
    let firstHopReachability: PathHopReachability?
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

        let firstHopReachability: PathHopReachability? = chain.first.map { key in
            reachability(for: key, context: context)
        }

        var warnings: [String] = []
        if let firstKey = chain.first, firstHopReachability == .notHeardDirect {
            warnings.append("\(context.display(for: firstKey)): never heard direct from your station \u{2014} the first hop must be reachable by your own RF or nothing else in the path matters.")
        }
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
            firstHopReachability: firstHopReachability,
            warnings: warnings
        )
    }

    static func reachability(for key: String, context: PathDraftContext) -> PathHopReachability {
        if context.provenDirectConnects.contains(key) {
            return .provenConnect
        }
        let heard = context.directHeardCounts[key] ?? 0
        if heard > 0 {
            return .heardDirect(frames: heard)
        }
        return .notHeardDirect
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
