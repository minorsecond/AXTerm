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

nonisolated struct ConnectDigiPathSection: Identifiable, Hashable {
    let id: String
    let title: String
    let paths: [ConnectSuggestions.DigiPath]
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
    @Published private(set) var suggestions: ConnectSuggestions = .empty
    @Published private(set) var isAutoAttemptInProgress = false
    @Published private(set) var autoAttemptStatus: String?

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
    private var routeHintsByDestinationAndNextHop: [String: [String: NetRomRouteHint]] = [:]
    private var routeFallbackDigisByDestination: [String: [[String]]] = [:]
    private var fallbackPathCursorByDestination: [String: Int] = [:]
    private var observedPaths: [[String]] = []
    private var knownDigis: [String] = []

    private var routeRows: [RouteInfo] = []
    private var neighborRows: [NeighborInfo] = []
    private var observedPathStore: [ObservedPathKey: ObservedPath] = [:]

    private var suggestionsWorkItem: DispatchWorkItem?
    private let suggestionsDebounce: TimeInterval = 0.2

    private struct ObservedPathKey: Hashable {
        let peer: String
        let digisSignature: String
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.barState = .disconnectedDraft(.empty())
        loadPersistence()
        scheduleSuggestionsRefresh()
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

    var connectSuggestions: ConnectSuggestions {
        suggestions
    }

    var recommendedDigiPaths: [ConnectSuggestions.DigiPath] {
        suggestions.recommendedDigiPaths
    }

    var fallbackDigiPaths: [ConnectSuggestions.DigiPath] {
        suggestions.fallbackDigiPaths
    }

    var recommendedNextHopSuggestions: [ConnectSuggestions.NetRomNextHop] {
        suggestions.recommendedNextHops
    }

    var fallbackNextHopSuggestions: [ConnectSuggestions.NetRomNextHop] {
        suggestions.fallbackNextHops
    }

    var knownDigiPresets: [String] {
        knownDigis
    }

    var observedPathPresets: [[String]] {
        observedPaths
    }

    var recentPathPresets: [[String]] {
        let scoped = recentDigiPaths.filter { item in
            item.mode == mode && (item.context == nil || item.context == activeDraftContext)
        }
        if !scoped.isEmpty {
            return scoped.map(\.path)
        }
        return recentDigiPaths.filter { $0.mode == mode }.map(\.path)
    }

    var moreDigiPathSections: [ConnectDigiPathSection] {
        let sectionOrder: [ConnectSuggestions.DigiPath.Source] = [
            .observedForDestination,
            .historicalSuccess,
            .neighborStrong,
            .routeDerived
        ]
        let titleForSource: [ConnectSuggestions.DigiPath.Source: String] = [
            .observedForDestination: "Observed for destination",
            .historicalSuccess: "Recent successful for destination",
            .neighborStrong: "Strong neighbors",
            .routeDerived: "Route-derived"
        ]

        return sectionOrder.compactMap { source in
            let items = fallbackDigiPaths.filter { $0.source == source }
            guard !items.isEmpty else { return nil }
            return ConnectDigiPathSection(
                id: "source-\(source.rawValue)",
                title: titleForSource[source] ?? "Other",
                paths: Array(items.prefix(10))
            )
        }
    }

    var recommendedNextHopOptions: [String] {
        recommendedNextHopSuggestions.map(\.callsign)
    }

    var fallbackNextHopOptions: [String] {
        fallbackNextHopSuggestions.map(\.callsign)
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
        self.stations = stations
            .map { CallsignValidator.normalize($0.call) }
            .filter { !$0.isEmpty }
        self.neighbors = neighbors
            .map { canonicalCallsign($0.call) }
            .filter { !$0.isEmpty }
        self.routeRows = routes
        self.neighborRows = neighbors

        var bestRoutesByDestination: [String: RouteInfo] = [:]
        var bestRoutesByDestinationAndNextHop: [String: [String: RouteInfo]] = [:]
        var fallbackDigisByDestination: [String: [[String]]] = [:]

        for route in routes {
            let destination = canonicalCallsign(route.destination)
            guard !destination.isEmpty else { continue }
            let hint = hintFor(route: route)

            if let hop = hint.nextHop, !hop.isEmpty {
                var perHop = bestRoutesByDestinationAndNextHop[destination] ?? [:]
                if let existing = perHop[hop] {
                    if shouldPrefer(route, over: existing) {
                        perHop[hop] = route
                    }
                } else {
                    perHop[hop] = route
                }
                bestRoutesByDestinationAndNextHop[destination] = perHop
            }

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

        routeHintsByDestination = Dictionary(
            uniqueKeysWithValues: bestRoutesByDestination.map { destination, route in
                (destination, hintFor(route: route))
            }
        )
        routeHintsByDestinationAndNextHop = bestRoutesByDestinationAndNextHop.mapValues { perHop in
            Dictionary(uniqueKeysWithValues: perHop.map { hop, route in
                (hop, hintFor(route: route))
            })
        }
        routeDestinations = routeHintsByDestination.keys.sorted()
        routeFallbackDigisByDestination = fallbackDigisByDestination.mapValues { paths in
            var seen = Set<String>()
            return paths.filter { path in
                let key = path.joined(separator: ",")
                return seen.insert(key).inserted
            }
        }

        rebuildObservedPaths(from: packets)

        let persistedFavorites = favorites.map { CallsignValidator.normalize($0) }
        if !persistedFavorites.isEmpty {
            self.stations = dedupe(persistedFavorites + self.stations)
        }

        refreshRoutePreview()
        scheduleSuggestionsRefresh()
    }

    func applySuggestedTo(_ value: String) {
        toCall = canonicalCallsign(value)
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
        let merged = viaDigipeaters + rawValues.map { canonicalCallsign($0) }
        viaDigipeaters = DigipeaterListParser.capped(merged.filter { !$0.isEmpty })
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
        viaDigipeaters = DigipeaterListParser.capped(path.map { canonicalCallsign($0) }.filter { !$0.isEmpty })
        validate()
        syncStateFromDraftIfEditable()
    }

    func applyRoutePrefill(route: RouteDisplayInfo, action: RouteConnectAction) {
        let destination = canonicalCallsign(route.destination)
        let heardAs = canonicalCallsign(route.heardPath.first ?? "")

        switch action {
        case .netrom:
            mode = .netrom
            toCall = destination
            nextHopSelection = Self.autoNextHopID
            inlineNote = nil
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
            viaDigipeaters = DigipeaterListParser.capped(route.heardPath.map { canonicalCallsign($0) }.filter { !$0.isEmpty })
            nextHopSelection = Self.autoNextHopID
            inlineNote = nil
        }

        validate()
        syncStateFromDraftIfEditable()
    }

    func applyNetRomPrefill(
        destination: String,
        routeHint: NetRomRouteHint?,
        suggestedPreview: String?,
        nextHopOverride: String?
    ) {
        mode = .netrom
        toCall = canonicalCallsign(destination)
        if let routeHint {
            routeHintsByDestination[toCall] = routeHint
            if let hop = routeHint.nextHop, !hop.isEmpty {
                routeHintsByDestinationAndNextHop[toCall, default: [:]][hop] = routeHint
            }
        }
        if let suggestedPreview, !suggestedPreview.isEmpty {
            routePreview = suggestedPreview
        }
        let normalizedOverride = canonicalCallsign(nextHopOverride ?? "")
        nextHopSelection = normalizedOverride.isEmpty ? Self.autoNextHopID : normalizedOverride
        validate()
        syncStateFromDraftIfEditable()
    }

    func applyNeighborPrefill(_ neighbor: NeighborDisplayInfo) {
        mode = .ax25
        toCall = canonicalCallsign(neighbor.callsign)
        viaDigipeaters = []
        inlineNote = nil
        validate()
        syncStateFromDraftIfEditable()
    }

    func applyStationPrefill(_ station: Station) {
        mode = .ax25
        toCall = canonicalCallsign(station.call)
        viaDigipeaters = []
        inlineNote = nil
        validate()
        syncStateFromDraftIfEditable()
    }

    func setAdaptiveTelemetry(_ telemetry: AdaptiveTelemetry?) {
        adaptiveTelemetry = telemetry
    }

    func beginAutoAttempting() {
        isAutoAttemptInProgress = true
        autoAttemptStatus = nil
    }

    func updateAutoAttemptStatus(_ status: String?) {
        autoAttemptStatus = status
    }

    func endAutoAttempting() {
        isAutoAttemptInProgress = false
        autoAttemptStatus = nil
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
            destination: canonicalCallsign(destination),
            transport: transport,
            connectedAt: Date()
        )
        barState = ConnectBarStateReducer.reduce(state: barState, event: .connectSucceeded(session))
        endAutoAttempting()
    }

    func markDisconnecting() {
        barState = ConnectBarStateReducer.reduce(state: barState, event: .disconnectRequested)
    }

    func markDisconnected() {
        barState = ConnectBarStateReducer.reduce(
            state: barState,
            event: .disconnectCompleted(nextDraft: currentDraft())
        )
        endAutoAttempting()
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

        let normalizedTo = canonicalCallsign(toCall)
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

        let normalizedDestination = canonicalCallsign(destination)
        if canonicalCallsign(toCall) == normalizedDestination {
            let ranked = (suggestions.recommendedDigiPaths + suggestions.fallbackDigiPaths).map(\.digis)
            if !ranked.isEmpty {
                return ranked
            }
        }

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

        return []
    }

    func nextFallbackDigipeaterSelection(for destination: String, nextHopOverride: CallsignSSID?) -> (path: [String], alternateCount: Int) {
        let candidates = fallbackDigipeaterCandidates(for: destination, nextHopOverride: nextHopOverride)
        guard !candidates.isEmpty else { return ([], 0) }

        if nextHopOverride != nil {
            return (candidates[0], 0)
        }

        let normalizedDestination = canonicalCallsign(destination)
        let currentIndex = fallbackPathCursorByDestination[normalizedDestination] ?? 0
        let selectedIndex = currentIndex % candidates.count
        fallbackPathCursorByDestination[normalizedDestination] = (selectedIndex + 1) % candidates.count
        return (candidates[selectedIndex], max(0, candidates.count - 1))
    }

    func recordAttempt(intent: ConnectIntent, result: ConnectAttemptResult) {
        let normalized = canonicalCallsign(intent.to)
        guard !normalized.isEmpty else { return }

        let timestamp = Date()
        let success = result == .success
        let modeForAttempt: ConnectBarMode
        let digis: [String]
        let override: String?

        switch intent.kind {
        case .ax25Direct:
            modeForAttempt = .ax25
            digis = []
            override = nil
        case let .ax25ViaDigis(path):
            modeForAttempt = .ax25ViaDigi
            digis = path.map(\.stringValue)
            override = nil
        case let .netrom(nextHopOverride):
            modeForAttempt = .netrom
            digis = []
            override = nextHopOverride?.stringValue
        }

        attemptHistory.insert(
            ConnectAttemptRecord(
                to: normalized,
                mode: modeForAttempt,
                timestamp: timestamp,
                success: success,
                digis: digis,
                nextHopOverride: override
            ),
            at: 0
        )
        attemptHistory = Array(attemptHistory.prefix(200))
        persistAttempts()

        if modeForAttempt == .ax25ViaDigi && success && !digis.isEmpty {
            recentDigiPaths.removeAll { $0.path == digis && $0.mode == .ax25ViaDigi && $0.context == activeDraftContext }
            recentDigiPaths.insert(
                RecentDigiPath(path: digis, mode: .ax25ViaDigi, context: activeDraftContext, timestamp: timestamp),
                at: 0
            )
            recentDigiPaths = Array(recentDigiPaths.prefix(20))
            persistRecentDigiPaths()
        }

        scheduleSuggestionsRefresh()
    }

    func refreshRoutePreview() {
        guard mode == .netrom else { return }

        let destination = canonicalCallsign(toCall)
        guard !destination.isEmpty else {
            routePreview = "No destination selected"
            nextHopOptions = dedupe([Self.autoNextHopID] + neighbors)
            routeOverrideWarning = nil
            return
        }

        var hint = routeHintsByDestination[destination]
        if nextHopSelection != Self.autoNextHopID && !nextHopSelection.isEmpty,
           let overrideHint = routeHintsByDestinationAndNextHop[destination]?[nextHopSelection] {
            hint = overrideHint
        }

        if let hint {
            let summary = hint.path.isEmpty ? destination : hint.path.joined(separator: " → ")
            routePreview = "Best route: \(summary) (\(hint.hops) hops)"
        } else {
            routePreview = "No known route"
        }

        let recommendationOptions = suggestions.recommendedNextHops.map(\.callsign)
        let fallbackOptions = suggestions.fallbackNextHops.map(\.callsign)
        var options = [Self.autoNextHopID] + recommendationOptions + fallbackOptions
        if nextHopSelection != Self.autoNextHopID && !nextHopSelection.isEmpty && !options.contains(nextHopSelection) {
            options.append(nextHopSelection)
        }
        nextHopOptions = dedupe(options)

        if nextHopSelection != Self.autoNextHopID && !nextHopSelection.isEmpty {
            let hasKnownOverride = routeHintsByDestinationAndNextHop[destination]?[nextHopSelection] != nil
            if !hasKnownOverride {
                routeOverrideWarning = "No known route via \(nextHopSelection) — attempt may fail."
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

        let normalizedTo = canonicalCallsign(toCall)
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
        scheduleSuggestionsRefresh()
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
        toCall = canonicalCallsign(draft.destination)
        switch draft.transport {
        case let .ax25(option):
            switch option {
            case .direct:
                mode = .ax25
                viaDigipeaters = []
            case let .viaDigipeaters(path):
                mode = .ax25ViaDigi
                viaDigipeaters = DigipeaterListParser.capped(path.map { canonicalCallsign($0) }.filter { !$0.isEmpty })
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
            .map { value in
                if value == Self.autoNextHopID { return value }
                return canonicalCallsign(value)
            }
            .filter { !$0.isEmpty || $0 == Self.autoNextHopID }
            .filter { seen.insert($0).inserted }
    }

    private func favoriteCalls() -> [String] {
        let successFirst = attemptHistory
            .filter { $0.success }
            .map(\.to)
        return dedupe(successFirst)
    }

    private func recentCalls(for mode: ConnectBarMode) -> [String] {
        dedupe(attemptHistory.filter { $0.mode == mode }.map(\.to))
    }

    private func hintFor(route: RouteInfo) -> NetRomRouteHint {
        let path = route.path.map { canonicalCallsign($0) }.filter { !$0.isEmpty }
        let nextHop = path.first ?? canonicalCallsign(route.origin)
        return NetRomRouteHint(
            nextHop: nextHop.isEmpty ? nil : nextHop,
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

    private func rebuildObservedPaths(from packets: [Packet]) {
        var map: [ObservedPathKey: ObservedPath] = [:]
        var knownDigiSet = Set<String>()

        for packet in packets {
            let via = packet.via
                .map { canonicalCallsign($0.display) }
                .filter { !$0.isEmpty && CallsignValidator.isValidDigipeaterAddress($0) }
            guard !via.isEmpty else { continue }

            for digi in via {
                knownDigiSet.insert(digi)
            }

            let peers = [
                packet.to.map { canonicalCallsign($0.display) } ?? "",
                packet.from.map { canonicalCallsign($0.display) } ?? ""
            ]
            .filter { !$0.isEmpty }

            for peer in peers {
                let key = ObservedPathKey(peer: peer, digisSignature: via.joined(separator: ","))
                if var existing = map[key] {
                    existing.count += 1
                    if packet.timestamp > existing.lastSeen {
                        existing.lastSeen = packet.timestamp
                    }
                    map[key] = existing
                } else {
                    map[key] = ObservedPath(
                        peer: peer,
                        digis: via,
                        lastSeen: packet.timestamp,
                        count: 1
                    )
                }
            }
        }

        observedPathStore = map
        observedPaths = map.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.digis.joined(separator: ",") < rhs.digis.joined(separator: ",")
            }
            .prefix(10)
            .map(\.digis)

        knownDigis = Array(knownDigiSet).sorted()
    }

    private func scheduleSuggestionsRefresh() {
        suggestionsWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildSuggestions()
        }
        suggestionsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + suggestionsDebounce, execute: work)
    }

    private func rebuildSuggestions() {
        suggestions = ConnectSuggestionEngine.build(
            to: toCall,
            mode: mode,
            routes: routeRows,
            neighbors: neighborRows,
            observedPaths: Array(observedPathStore.values),
            attemptHistory: attemptHistory
        )
        refreshRoutePreview()
    }

    private func canonicalCallsign(_ raw: String) -> String {
        let normalized = CallsignValidator.normalize(raw)
        guard !normalized.isEmpty else { return "" }
        let parsed = CallsignNormalizer.parse(normalized)
        guard !parsed.call.isEmpty else { return "" }
        return CallsignNormalizer.display(call: parsed.call, ssid: parsed.ssid)
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
