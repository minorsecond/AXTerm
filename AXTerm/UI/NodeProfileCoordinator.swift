import SwiftUI
import Combine

/// Routes "who is this?" from anywhere in the app to one identity view.
///
/// Terminal lines, the Stations list and map callouts all name callsigns, and
/// each used to answer the question with whatever fragment it held. This is
/// the single door: a view asks for a callsign, the host resolves it against
/// every source once, and the same page appears.
@MainActor
final class NodeProfileCoordinator: ObservableObject {

    /// What is on screen, and how.
    ///
    /// One value drives one sheet. Two `.sheet` modifiers attached to the
    /// same view do not both work — SwiftUI honours the last one — which is
    /// why a peek opened once and then silently stopped after the first time
    /// the full page was shown.
    enum Presentation: Identifiable, Hashable {
        /// A dismissible look, with a way deeper in.
        case peek(String)
        /// The whole thing.
        case page(String)

        var callsign: String {
            switch self {
            case .peek(let call), .page(let call): return call
            }
        }

        var isPage: Bool {
            if case .page = self { return true }
            return false
        }

        /// Distinguishes the two modes for the same callsign, so promoting a
        /// peek to a page is seen as a change rather than a no-op.
        var id: String { (isPage ? "page:" : "peek:") + callsign }
    }

    @Published var presented: Presentation?

    func peek(_ callsign: String) {
        guard let normalized = Self.normalize(callsign) else { return }
        presented = .peek(normalized)
    }

    func openPage(_ callsign: String) {
        guard let normalized = Self.normalize(callsign) else { return }
        presented = .page(normalized)
    }

    /// From the peek's own button.
    func promoteSheetToPage() {
        guard let callsign = presented?.callsign else { return }
        presented = .page(callsign)
    }

    func dismiss() { presented = nil }

    private static func normalize(_ callsign: String) -> String? {
        let trimmed = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Gathers the scattered sources into a profile.
///
/// Kept apart from the coordinator so the assembly is testable and so the
/// view layer never learns where any of this comes from.
@MainActor
struct NodeProfileResolver {

    var localCallsign: String = ""
    var aliases: NodeAliasDirectory = NodeAliasDirectory()
    var heardEntries: [HeardStationMap.Entry] = []
    var directory: [String: CallsignRecord] = [:]
    var linkQuality: [String: WinlinkLinkQuality] = [:]
    var observer: GreatCircle.Point?
    /// Neighbour quality by callsign, straight from the NET/ROM table.
    var neighbourQuality: [String: Int] = [:]
    /// Destination → next hop, with whether the hop *told* us about it.
    ///
    /// `isBroadcast` marks a route learned from a NET/ROM routing broadcast
    /// the origin sent, as opposed to one inferred from watching traffic.
    var routes: [(destination: String, via: String, isBroadcast: Bool)] = []
    /// Every callsign seen acting as a digipeater in a via path.
    var digipeaters: Set<String> = []
    /// Directed link measurements from the NET/ROM estimator.
    var linkStats: [LinkStatRecord] = []
    /// What stations announced they run, heard in ID and beacon frames.
    var declaredServices: [StationServiceParser.Declaration] = []
    /// The observed network, for the questions only the graph can answer:
    /// what breaks without this station, and who it clusters with.
    var networkPaths: [NetworkPath] = []
    /// The durable directory, so a station identified last week is still
    /// known today.
    var serviceStore: StationServiceStore?
    /// The time series behind them. Nil where no database is open.
    var historyStore: LinkQualityHistoryStore?
    /// How far back the profile charts. A fortnight matches retention.
    var historyWindow: TimeInterval = 14 * 24 * 3600

    func profile(for callsign: String) -> NodeProfile {
        let key = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        // The alias may resolve to a different callsign, so look the heard
        // entry up under both names.
        let resolved = aliases.callsign(for: key)?.uppercased() ?? key

        let heard = heardEntries.first { $0.callsign.uppercased() == key }
            ?? heardEntries.first { $0.callsign.uppercased() == resolved }

        return NodeProfile.make(
            callsign: key,
            localCallsign: localCallsign,
            aliasDirectory: aliases,
            heard: heard,
            directory: directory[resolved] ?? directory[key],
            neighbourQuality: neighbourQuality[resolved] ?? neighbourQuality[key],
            routesVia: routes.filter { $0.via.uppercased() == resolved }
                .map(\.destination).sorted(),
            reachedVia: routes.first { $0.destination.uppercased() == resolved }?.via,
            netRomDeclaration: netRomDeclaration(for: resolved),
            digipeaterCallsigns: digipeaters,
            declaredServices: declaredServices + storedDeclarations(for: resolved),
            winlink: linkQuality[resolved] ?? linkQuality[key],
            links: directedLinks(for: resolved),
            linkHistory: history(for: resolved),
            siblings: siblings(of: resolved),
            topology: topology(for: resolved),
            observer: observer)
    }

    /// This station's place in the graph of observed paths.
    ///
    /// Recomputed per profile rather than cached: the graph is a few dozen
    /// vertices, both analyses are linear in its size, and a stale answer
    /// about which station the network depends on is worse than no answer.
    private func topology(for callsign: String) -> NodeProfile.Topology? {
        guard !networkPaths.isEmpty else { return nil }
        let graph = NetworkTopology.adjacency(networkPaths)
        guard let neighbours = graph[callsign] else { return nil }

        var topology = NodeProfile.Topology(neighbourCount: neighbours.count)

        if NetworkTopology.articulationPoints(in: graph).contains(callsign) {
            topology.partitionsWithoutIt = NetworkTopology
                .partitionsWithout(callsign, in: graph)
                .map(\.count).sorted(by: >)
        }

        let labels = NetworkTopology.communities(in: graph)
        if let mine = labels[callsign] {
            topology.communityMembers = labels
                .filter { $0.value == mine && $0.key != callsign }
                .keys.sorted()
        }
        return topology
    }

    /// Declarations kept from previous sessions.
    ///
    /// The in-memory set only holds what this launch has heard, which on a
    /// quiet morning is nothing. A directory that forgets itself every launch
    /// is not a directory.
    private func storedDeclarations(for callsign: String) -> [StationServiceParser.Declaration] {
        guard let serviceStore,
              let entries = try? serviceStore.services(for: callsign) else { return [] }
        return entries.map {
            StationServiceParser.Declaration(
                callsign: $0.callsign, service: $0.service, alias: $0.alias,
                sourceText: $0.sourceText)
        }
    }

    /// Whether this station has told us it is a NET/ROM node.
    ///
    /// Membership of the neighbour table does not count — that table is built
    /// by watching traffic, so it fills up with ordinary stations that merely
    /// transmitted nearby. Only two things are the station's own word: a
    /// routing broadcast it originated, and a node alias it announced.
    private func netRomDeclaration(for callsign: String) -> NodeProfile.NetRomDeclaration? {
        if routes.contains(where: {
            $0.via.uppercased() == callsign && $0.isBroadcast
        }) {
            return .nodesBroadcast
        }
        if let entry = aliases.allEntries.first(where: {
            $0.callsign.uppercased() == callsign
                && $0.service.uppercased().hasPrefix("N")
        }) {
            return .aliasAnnouncement(entry.alias)
        }
        return nil
    }

    /// Samples for both directions between us and this station.
    private func history(for callsign: String) -> [LinkQualityHistorySample] {
        guard let historyStore else { return [] }
        let me = localCallsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !me.isEmpty else { return [] }
        return (try? historyStore.history(
            between: me, and: callsign,
            since: Date().addingTimeInterval(-historyWindow))) ?? []
    }

    /// Both directions of every measured link touching this station.
    private func directedLinks(for callsign: String) -> [NodeProfile.DirectedLink] {
        let me = localCallsign.trimmingCharacters(in: .whitespaces).uppercased()
        return linkStats.compactMap { stat in
            let from = stat.fromCall.uppercased()
            let to = stat.toCall.uppercased()
            // Only links this station is one end of. A measurement between two
            // other stations is their business, and showing it here would
            // imply we measured it.
            guard (from == callsign && to == me) || (to == callsign && from == me) else {
                return nil
            }
            return NodeProfile.DirectedLink(
                from: from, to: to, quality: stat.quality,
                df: stat.dfEstimate, dr: stat.drEstimate,
                duplicates: stat.duplicateCount,
                lastUpdated: stat.lastUpdated,
                isFromUs: from == me)
        }
    }

    /// Other SSIDs under the same base callsign.
    private func siblings(of callsign: String) -> [NodeProfile.Sibling] {
        let (base, _) = CallsignNormalizer.parse(callsign)
        let wanted = base.uppercased()
        guard !wanted.isEmpty else { return [] }

        return heardEntries.compactMap { entry in
            let (entryBase, entrySSID) = CallsignNormalizer.parse(entry.callsign)
            guard entryBase.uppercased() == wanted else { return nil }
            let upper = entry.callsign.uppercased()
            return NodeProfile.Sibling(
                callsign: upper,
                ssid: entrySSID == 0 && !upper.contains("-") ? nil : entrySSID,
                heardCount: entry.heardCount,
                lastHeard: entry.lastHeard,
                roles: NodeProfile.inferRoles(
                    callsign: upper,
                    localCallsign: localCallsign,
                    heard: entry,
                    isAlias: false,
                    netRomDeclaration: netRomDeclaration(for: upper),
                    digipeaterCallsigns: digipeaters,
                    declaredServices: declaredServices.filter {
                        $0.callsign.uppercased() == upper
                    },
                    winlink: linkQuality[upper]))
        }
    }
}
