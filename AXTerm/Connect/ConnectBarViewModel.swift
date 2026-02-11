import Foundation
import Combine

nonisolated struct ConnectSuggestionGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let values: [String]
}

nonisolated enum RouteConnectAction {
    case netrom
    case ax25Direct
    case ax25ViaDigi
}

final class ConnectBarViewModel: ObservableObject {
    @Published private(set) var barState: ConnectBarState
    @Published private(set) var adaptiveTelemetry: AdaptiveTelemetry?
    @Published var mode: ConnectBarMode = .ax25
    @Published var toCall: String = ""
    @Published var viaDigipeaters: [String] = []
    @Published var pendingViaTokenInput: String = ""
    @Published var nextHopSelection: String = "__AUTO__"
    @Published private(set) var nextHopOptions: [String] = ["__AUTO__"]
    @Published private(set) var routePreview: String = "No known route"
    @Published private(set) var routeOverrideWarning: String?
    @Published private(set) var inlineNote: String?
    @Published private(set) var validationErrors: [String] = []
    @Published private(set) var warningMessages: [String] = []

    static let autoNextHopID = "__AUTO__"

    private let defaults: UserDefaults
    private let recentAttemptsKey = "connectBar.recentAttempts"
    private let recentDigiPathsKey = "connectBar.recentDigiPaths"
    private let contextModeKey = "connectBar.contextModes"
    private var activeDraftContext: ConnectSourceContext = .terminal

    private var contextModes: [ConnectSourceContext: ConnectBarMode] = [:]
    private var attemptHistory: [ConnectAttemptRecord] = []
    private var recentDigiPaths: [RecentDigiPath] = []

    private var stations: [String] = []
    private var neighbors: [String] = []
    private var routeDestinations: [String] = []
    private var routeHintsByDestination: [String: NetRomRouteHint] = [:]
    private var routeFallbackDigisByDestination: [String: [[String]]] = [:]
    private var fallbackPathCursorByDestination: [String: Int] = [:]
    private var observedPaths: [[String]] = []
    private var knownDigis: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.barState = .disconnectedDraft(.empty())
        loadPersistence()
    }

    var toSuggestionGroups: [ConnectSuggestionGroup] {
        let recentByMode = recentCalls(for: mode)
        switch mode {
        case .ax25, .ax25ViaDigi:
            return [
                ConnectSuggestionGroup(id: "recent", title: "Recent Heard", values: dedupe(recentByMode + stations).prefix(10).map { $0 }),
                ConnectSuggestionGroup(id: "favorites", title: "Favorites", values: favoriteCalls().prefix(10).map { $0 }),
                ConnectSuggestionGroup(id: "neighbors", title: "Neighbors", values: neighbors.prefix(10).map { $0 })
            ].filter { !$0.values.isEmpty }
        case .netrom:
            return [
                ConnectSuggestionGroup(id: "routes", title: "Routes", values: dedupe(recentByMode + routeDestinations).prefix(20).map { $0 }),
                ConnectSuggestionGroup(id: "neighbors", title: "Neighbors", values: neighbors.prefix(10).map { $0 })
            ].filter { !$0.values.isEmpty }
        }
    }

    var flatToSuggestions: [String] {
        var seen = Set<String>()
        return toSuggestionGroups
            .flatMap(\.values)
            .filter { seen.insert($0).inserted }
    }

    var canEditDigis: Bool {
        mode == .ax25ViaDigi
    }

    var canEditNetRomRouting: Bool {
        mode == .netrom
    }

    var viaHopCount: Int {
        viaDigipeaters.count
    }

    var knownDigiPresets: [String] {
        knownDigis
    }

    var observedPathPresets: [[String]] {
        observedPaths
    }

    var recentPathPresets: [[String]] {
        recentDigiPaths.map(\.path)
    }

    func applyContext(_ context: ConnectSourceContext) {
        activeDraftContext = context
        let resolved = contextModes[context] ?? ConnectBarMode.defaultMode(for: context)
        mode = resolved
        validate()
        syncStateFromDraftIfEditable()
    }

    func setMode(_ newMode: ConnectBarMode, for context: ConnectSourceContext?) {
        mode = newMode
        if let context {
            activeDraftContext = context
            contextModes[context] = newMode
            persistContextModes()
        }
        if newMode != .netrom {
            nextHopSelection = Self.autoNextHopID
            routeOverrideWarning = nil
        }
        validate()
        syncStateFromDraftIfEditable()
    }

    func updateRuntimeData(stations: [Station], neighbors: [NeighborInfo], routes: [RouteInfo], packets: [Packet], favorites: [String]) {
        self.stations = stations.map { CallsignValidator.normalize($0.call) }
        self.neighbors = neighbors.map { CallsignValidator.normalize($0.call) }
        var bestRoutesByDestination: [String: RouteInfo] = [:]
        var fallbackDigisByDestination: [String: [[String]]] = [:]
        for route in routes {
            let destination = CallsignValidator.normalize(route.destination)
            let hint = hintFor(route: route)
            let via = ConnectPrefillLogic.fallbackDigipeaters(
                destination: destination,
                hint: hint,
                nextHopOverride: nil
            )
            if !via.isEmpty {
                fallbackDigisByDestination[destination, default: []].append(via)
            }

            if let existing = bestRoutesByDestination[destination] {
                if shouldPrefer(route, over: existing) {
                    bestRoutesByDestination[destination] = route
                }
            } else {
                bestRoutesByDestination[destination] = route
            }
        }
        self.routeHintsByDestination = Dictionary(
            uniqueKeysWithValues: bestRoutesByDestination.map { destination, route in
                (destination, hintFor(route: route))
            }
        )
        self.routeDestinations = routeHintsByDestination.keys.sorted()
        self.routeFallbackDigisByDestination = fallbackDigisByDestination.mapValues { paths in
            var seen = Set<String>()
            return paths.filter { path in
                let key = path.joined(separator: ",")
                return seen.insert(key).inserted
            }
        }

        var observedPathCounts: [String: (tokens: [String], count: Int)] = [:]
        var knownDigiSet = Set<String>()
        for packet in packets {
            let via = packet.via.map { CallsignValidator.normalize($0.display) }.filter { !$0.isEmpty }
            guard !via.isEmpty else { continue }
            let key = via.joined(separator: ",")
            observedPathCounts[key, default: (tokens: via, count: 0)].count += 1
            via.forEach { knownDigiSet.insert($0) }
        }

        self.observedPaths = observedPathCounts.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tokens.joined(separator: ",") < rhs.tokens.joined(separator: ",")
            }
            .prefix(8)
            .map { $0.tokens }

        self.knownDigis = Array(knownDigiSet).sorted()

        let persistedFavorites = favorites.map { CallsignValidator.normalize($0) }
        if !persistedFavorites.isEmpty {
            self.stations = dedupe(persistedFavorites + self.stations)
        }

        refreshRoutePreview()
    }

    func applySuggestedTo(_ value: String) {
        toCall = CallsignValidator.normalize(value)
        refreshRoutePreview()
        validate()
        syncStateFromDraftIfEditable()
    }

    func applyInlineNote(_ note: String?) {
        inlineNote = note
    }

    func ingestViaInput() {
        let parsed = DigipeaterListParser.parse(pendingViaTokenInput)
        guard !parsed.isEmpty else { return }
        appendDigipeaters(parsed)
        pendingViaTokenInput = ""
        syncStateFromDraftIfEditable()
    }

    func appendDigipeaters(_ rawValues: [String]) {
        let merged = viaDigipeaters + rawValues.map { CallsignValidator.normalize($0) }
        viaDigipeaters = DigipeaterListParser.capped(merged)
        validate()
        syncStateFromDraftIfEditable()
    }

    func removeDigi(at index: Int) {
        guard viaDigipeaters.indices.contains(index) else { return }
        viaDigipeaters.remove(at: index)
        validate()
        syncStateFromDraftIfEditable()
    }

    func moveDigiLeft(at index: Int) {
        guard index > 0, viaDigipeaters.indices.contains(index) else { return }
        viaDigipeaters.swapAt(index, index - 1)
        validate()
        syncStateFromDraftIfEditable()
    }

    func moveDigiRight(at index: Int) {
        guard viaDigipeaters.indices.contains(index), index < viaDigipeaters.count - 1 else { return }
        viaDigipeaters.swapAt(index, index + 1)
        validate()
        syncStateFromDraftIfEditable()
    }

    func applyPathPreset(_ path: [String]) {
        viaDigipeaters = DigipeaterListParser.capped(path.map { CallsignValidator.normalize($0) })
        validate()
        syncStateFromDraftIfEditable()
    }

    func applyRoutePrefill(route: RouteDisplayInfo, action: RouteConnectAction) {
        let destination = CallsignValidator.normalize(route.destination)
        let heardAs = CallsignValidator.normalize(route.heardPath.first ?? "")
        let suggestedNextHop = CallsignValidator.normalize(route.nextHop)

        switch action {
        case .netrom:
            mode = .netrom
            toCall = destination
            nextHopSelection = Self.autoNextHopID
            inlineNote = nil
            routePreview = "\(route.pathSummary) (\(route.hopCount) hops)"
            nextHopOptions = dedupe([Self.autoNextHopID, suggestedNextHop, heardAs] + neighbors)
        case .ax25Direct:
            mode = .ax25
            let target = ConnectPrefillLogic.ax25DirectTarget(destination: destination, heardAs: heardAs)
            toCall = target.to
            inlineNote = target.note
            viaDigipeaters = []
            nextHopSelection = Self.autoNextHopID
        case .ax25ViaDigi:
            mode = .ax25ViaDigi
            toCall = destination
            viaDigipeaters = DigipeaterListParser.capped(route.heardPath)
            nextHopSelection = Self.autoNextHopID
            inlineNote = nil
        }

        validate()
        syncStateFromDraftIfEditable()
    }

    func applyNeighborPrefill(_ neighbor: NeighborDisplayInfo) {
        mode = .ax25
        toCall = CallsignValidator.normalize(neighbor.callsign)
        viaDigipeaters = []
        inlineNote = nil
        validate()
        syncStateFromDraftIfEditable()
    }

    func applyStationPrefill(_ station: Station) {
        mode = .ax25
        toCall = CallsignValidator.normalize(station.call)
        viaDigipeaters = []
        inlineNote = nil
        validate()
        syncStateFromDraftIfEditable()
    }

    func setAdaptiveTelemetry(_ telemetry: AdaptiveTelemetry?) {
        adaptiveTelemetry = telemetry
    }

    func enterBroadcastComposer() {
        barState = ConnectBarStateReducer.reduce(state: barState, event: .switchedToBroadcast)
    }

    func enterConnectDraftMode() {
        barState = ConnectBarStateReducer.reduce(state: barState, event: .switchedToConnect)
        syncStateFromDraftIfEditable()
    }

    func markConnecting() {
        barState = ConnectBarStateReducer.reduce(state: barState, event: .connectRequested(currentDraft()))
    }

    func markConnected(sourceCall: String?, destination: String, via: [String], transportMode: ConnectBarMode, forcedNextHop: String?) {
        let transport: SessionTransport
        switch transportMode {
        case .netrom:
            transport = .netrom(nextHop: forcedNextHop, forced: forcedNextHop != nil)
        case .ax25, .ax25ViaDigi:
            transport = .ax25(via: via)
        }

        let session = SessionInfo(
            sourceContext: activeDraftContext,
            sourceCall: sourceCall,
            destination: CallsignValidator.normalize(destination),
            transport: transport,
            connectedAt: Date()
        )
        barState = ConnectBarStateReducer.reduce(state: barState, event: .connectSucceeded(session))
    }

    func markDisconnecting() {
        barState = ConnectBarStateReducer.reduce(state: barState, event: .disconnectRequested)
    }

    func markDisconnected() {
        barState = ConnectBarStateReducer.reduce(
            state: barState,
            event: .disconnectCompleted(nextDraft: currentDraft())
        )
    }

    func markFailed(reason: ConnectFailure.Reason, detail: String?) {
        let failure = ConnectFailure(reason: reason, detail: detail)
        barState = ConnectBarStateReducer.reduce(state: barState, event: .connectFailed(failure))
    }

    func applySidebarSelection(_ selection: SidebarStationSelection, action: SidebarConnectAction) {
        barState = ConnectBarStateReducer.reduce(state: barState, event: .sidebarSelection(selection, action))
        guard case let .disconnectedDraft(draft) = barState else { return }
        applyDraft(draft)
    }

    func buildIntent(sourceContext: ConnectSourceContext) -> ConnectIntent {
        validate()

        let normalizedTo = CallsignValidator.normalize(toCall)
        let routeHint = routeHintsByDestination[normalizedTo]
        let preview = mode == .netrom ? routePreview : nil

        let kind: ConnectKind
        switch mode {
        case .ax25:
            kind = .ax25Direct
        case .ax25ViaDigi:
            let digis = viaDigipeaters.compactMap { ConnectCallsign.toCallsign($0) }
            kind = .ax25ViaDigis(digis)
        case .netrom:
            let override: CallsignSSID?
            if nextHopSelection == Self.autoNextHopID {
                override = nil
            } else {
                override = ConnectCallsign.toCallsign(nextHopSelection)
            }
            kind = .netrom(nextHopOverride: override)
        }

        return ConnectIntent(
            kind: kind,
            to: normalizedTo,
            sourceContext: sourceContext,
            suggestedRoutePreview: preview,
            validationErrors: validationErrors,
            routeHint: routeHint,
            note: inlineNote
        )
    }

    func fallbackDigipeaterCandidates(for destination: String, nextHopOverride: CallsignSSID?) -> [[String]] {
        if let override = nextHopOverride {
            return [[override.stringValue]]
        }

        let normalizedDestination = CallsignValidator.normalize(destination)
        let ranked = routeFallbackDigisByDestination[normalizedDestination] ?? []
        if !ranked.isEmpty {
            return ranked
        }

        if let hint = routeHintsByDestination[normalizedDestination] {
            let via = ConnectPrefillLogic.fallbackDigipeaters(
                destination: normalizedDestination,
                hint: hint,
                nextHopOverride: nil
            )
            if !via.isEmpty {
                return [via]
            }
        }

        return [[]]
    }

    func nextFallbackDigipeaterSelection(for destination: String, nextHopOverride: CallsignSSID?) -> (path: [String], alternateCount: Int) {
        let candidates = fallbackDigipeaterCandidates(for: destination, nextHopOverride: nextHopOverride)
        guard !candidates.isEmpty else { return ([], 0) }

        if nextHopOverride != nil {
            return (candidates[0], 0)
        }

        let normalizedDestination = CallsignValidator.normalize(destination)
        let currentIndex = fallbackPathCursorByDestination[normalizedDestination] ?? 0
        let selectedIndex = currentIndex % candidates.count
        fallbackPathCursorByDestination[normalizedDestination] = (selectedIndex + 1) % candidates.count
        return (candidates[selectedIndex], max(0, candidates.count - 1))
    }

    func recordAttempt(intent: ConnectIntent, result: ConnectAttemptResult) {
        let normalized = CallsignValidator.normalize(intent.to)
        guard !normalized.isEmpty else { return }

        attemptHistory.insert(
            ConnectAttemptRecord(to: normalized, mode: mode, timestamp: Date(), result: result),
            at: 0
        )
        attemptHistory = Array(attemptHistory.prefix(200))
        persistAttempts()

        if case let .ax25ViaDigis(digis) = intent.kind, !digis.isEmpty {
            let values = digis.map(\.stringValue)
            recentDigiPaths.removeAll { $0.path == values }
            recentDigiPaths.insert(RecentDigiPath(path: values, timestamp: Date()), at: 0)
            recentDigiPaths = Array(recentDigiPaths.prefix(20))
            persistRecentDigiPaths()
        }
    }

    func refreshRoutePreview() {
        guard mode == .netrom else { return }

        let destination = CallsignValidator.normalize(toCall)
        guard !destination.isEmpty else {
            routePreview = "No destination selected"
            nextHopOptions = dedupe([Self.autoNextHopID] + neighbors)
            routeOverrideWarning = nil
            return
        }

        let hint = routeHintsByDestination[destination]
        if let hint {
            let summary = hint.path.isEmpty ? destination : hint.path.joined(separator: " -> ")
            routePreview = "\(summary) (\(hint.hops) hops)"
            nextHopOptions = dedupe([Self.autoNextHopID, hint.nextHop ?? "", hint.heardAs ?? ""] + neighbors)
        } else {
            routePreview = "No known route"
            nextHopOptions = dedupe([Self.autoNextHopID] + neighbors)
        }

        if nextHopSelection != Self.autoNextHopID && !nextHopSelection.isEmpty {
            if hint == nil || (hint?.nextHop != nextHopSelection && !neighbors.contains(nextHopSelection)) {
                routeOverrideWarning = "No known route via this neighbor"
            } else {
                routeOverrideWarning = nil
            }
        } else {
            routeOverrideWarning = nil
        }
    }

    func validate() {
        var errors: [String] = []
        var warnings: [String] = []

        let normalizedTo = CallsignValidator.normalize(toCall)
        if normalizedTo.isEmpty {
            errors.append("Destination callsign is required")
        } else {
            switch mode {
            case .netrom:
                if !CallsignValidator.isValidRoutingNode(normalizedTo) {
                    errors.append("Destination must be a valid callsign or routing node")
                }
            case .ax25, .ax25ViaDigi:
                if !CallsignValidator.isValidCallsign(normalizedTo) {
                    errors.append("Destination must be a valid AX.25 callsign")
                }
            }
        }

        if mode == .ax25ViaDigi {
            if viaDigipeaters.count > 2 {
                warnings.append("More than 2 digipeaters may reduce reliability")
            }
            if viaDigipeaters.count > DigipeaterListParser.maxDigipeaters {
                errors.append("Digipeater list exceeds \(DigipeaterListParser.maxDigipeaters) entries")
            }
            let invalidDigis = viaDigipeaters.filter { !CallsignValidator.isValidDigipeaterAddress($0) }
            if !invalidDigis.isEmpty {
                errors.append("Invalid digipeater: \(invalidDigis.joined(separator: ", "))")
            }
        }

        validationErrors = errors
        warningMessages = warnings
        refreshRoutePreview()
    }

    private func currentDraft() -> ConnectDraft {
        let transport: ConnectTransportDraft
        switch mode {
        case .ax25:
            transport = .ax25(.direct)
        case .ax25ViaDigi:
            transport = .ax25(.viaDigipeaters(viaDigipeaters))
        case .netrom:
            let forced = nextHopSelection == Self.autoNextHopID ? nil : nextHopSelection
            transport = .netrom(NetRomDraftOptions(forcedNextHop: forced, routePreview: routePreview))
        }

        return ConnectDraft(
            sourceContext: activeDraftContext,
            destination: toCall,
            transport: transport
        )
    }

    private func applyDraft(_ draft: ConnectDraft) {
        activeDraftContext = draft.sourceContext
        toCall = CallsignValidator.normalize(draft.destination)
        switch draft.transport {
        case let .ax25(option):
            switch option {
            case .direct:
                mode = .ax25
                viaDigipeaters = []
            case let .viaDigipeaters(path):
                mode = .ax25ViaDigi
                viaDigipeaters = DigipeaterListParser.capped(path.map { CallsignValidator.normalize($0) })
            }
            nextHopSelection = Self.autoNextHopID
        case let .netrom(option):
            mode = .netrom
            viaDigipeaters = []
            nextHopSelection = option.forcedNextHop ?? Self.autoNextHopID
        }
        validate()
    }

    private func syncStateFromDraftIfEditable() {
        switch barState {
        case .disconnectedDraft, .failed:
            barState = .disconnectedDraft(currentDraft())
        case .connecting, .connectedSession, .disconnecting, .broadcastComposer:
            break
        }
    }

    private func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { CallsignValidator.normalize($0) }
            .filter { !$0.isEmpty || $0 == Self.autoNextHopID }
            .filter { seen.insert($0).inserted }
    }

    private func favoriteCalls() -> [String] {
        let successFirst = attemptHistory
            .filter { $0.result == .success }
            .map(\.to)
        return dedupe(successFirst)
    }

    private func recentCalls(for mode: ConnectBarMode) -> [String] {
        dedupe(attemptHistory.filter { $0.mode == mode }.map(\.to))
    }

    private func hintFor(route: RouteInfo) -> NetRomRouteHint {
        let path = route.path.map { CallsignValidator.normalize($0) }
        let nextHop = path.first ?? CallsignValidator.normalize(route.origin)
        return NetRomRouteHint(
            nextHop: nextHop,
            heardAs: path.first,
            path: path,
            hops: max(1, path.count)
        )
    }

    private func shouldPrefer(_ candidate: RouteInfo, over existing: RouteInfo) -> Bool {
        if candidate.quality != existing.quality {
            return candidate.quality > existing.quality
        }
        if candidate.lastUpdated != existing.lastUpdated {
            return candidate.lastUpdated > existing.lastUpdated
        }
        if candidate.path.count != existing.path.count {
            return candidate.path.count < existing.path.count
        }
        return candidate.origin < existing.origin
    }

    private func loadPersistence() {
        if let data = defaults.data(forKey: contextModeKey),
           let decoded = try? JSONDecoder().decode(ConnectModeContextDefaults.self, from: data) {
            contextModes = decoded.values
        }

        if let data = defaults.data(forKey: recentAttemptsKey),
           let decoded = try? JSONDecoder().decode([ConnectAttemptRecord].self, from: data) {
            attemptHistory = decoded
        }

        if let data = defaults.data(forKey: recentDigiPathsKey),
           let decoded = try? JSONDecoder().decode([RecentDigiPath].self, from: data) {
            recentDigiPaths = decoded
        }
    }

    private func persistContextModes() {
        let envelope = ConnectModeContextDefaults(values: contextModes)
        if let data = try? JSONEncoder().encode(envelope) {
            defaults.set(data, forKey: contextModeKey)
        }
    }

    private func persistAttempts() {
        if let data = try? JSONEncoder().encode(attemptHistory) {
            defaults.set(data, forKey: recentAttemptsKey)
        }
    }

    private func persistRecentDigiPaths() {
        if let data = try? JSONEncoder().encode(recentDigiPaths) {
            defaults.set(data, forKey: recentDigiPathsKey)
        }
    }
}
