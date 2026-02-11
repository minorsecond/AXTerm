//
//  AnalyticsDashboardViewModel.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-21.
//

import Combine
import CoreGraphics
import Foundation
import os

@MainActor
final class AnalyticsDashboardViewModel: ObservableObject {
    typealias DatabaseAggregationProvider = @Sendable (
        DateInterval,
        TimeBucket,
        Calendar,
        Bool,
        Int,
        Int
    ) async -> AnalyticsAggregationResult?
    typealias TimeframePacketsProvider = @Sendable (DateInterval) async -> [Packet]?

    private let logger = Logger(subsystem: "AXTerm", category: "Analytics")

    /// Reference to settings store for persistence (optional for backward compat)
    private weak var settingsStore: AppSettingsStore?

    /// Reference to NET/ROM routing system for real-time routing graphs
    private let netRomIntegration: NetRomIntegration?

    @Published var timeframe: AnalyticsTimeframe {
        didSet {
            guard timeframe != oldValue else { return }
            trackFilterChange(reason: "timeframe")
            updateResolvedBucket(reason: "timeframe")
            scheduleAggregation(reason: "timeframe")
            scheduleGraphBuild(reason: "timeframe")
            persistTimeframe()
        }
    }
    @Published var bucketSelection: AnalyticsBucketSelection {
        didSet {
            guard bucketSelection != oldValue else { return }
            trackFilterChange(reason: "bucket")
            updateResolvedBucket(reason: "bucket")
            scheduleAggregation(reason: "bucket")
            persistBucket()
        }
    }
    @Published private(set) var resolvedBucket: TimeBucket
    @Published var customRangeStart: Date {
        didSet {
            guard customRangeStart != oldValue else { return }
            guard timeframe == .custom else { return }
            trackFilterChange(reason: "customRangeStart")
            updateResolvedBucket(reason: "customRangeStart")
            scheduleAggregation(reason: "customRangeStart")
            scheduleGraphBuild(reason: "customRangeStart")
        }
    }
    @Published var customRangeEnd: Date {
        didSet {
            guard customRangeEnd != oldValue else { return }
            guard timeframe == .custom else { return }
            trackFilterChange(reason: "customRangeEnd")
            updateResolvedBucket(reason: "customRangeEnd")
            scheduleAggregation(reason: "customRangeEnd")
            scheduleGraphBuild(reason: "customRangeEnd")
        }
    }
    @Published var includeViaDigipeaters: Bool {
        didSet {
            guard includeViaDigipeaters != oldValue else { return }
            trackFilterChange(reason: "includeVia")
            scheduleAggregation(reason: "includeVia")
            scheduleGraphBuild(reason: "includeVia")
            persistIncludeVia()
        }
    }
    @Published var minEdgeCount: Int {
        didSet {
            let normalized = AnalyticsInputNormalizer.minEdgeCount(minEdgeCount)
            if normalized != minEdgeCount {
                minEdgeCount = normalized
                return
            }
            guard minEdgeCount != oldValue else { return }
            trackFilterChange(reason: "minEdgeCount")
            scheduleGraphBuild(reason: "minEdgeCount")
            persistMinEdgeCount()
        }
    }
    @Published var maxNodes: Int {
        didSet {
            let normalized = AnalyticsInputNormalizer.maxNodes(maxNodes)
            if normalized != maxNodes {
                maxNodes = normalized
                return
            }
            guard maxNodes != oldValue else { return }
            trackFilterChange(reason: "maxNodes")
            scheduleGraphBuild(reason: "maxNodes")
            persistMaxNodes()
        }
    }

    /// Station identity mode for SSID grouping in the network graph.
    /// When `.station`, ANH, ANH-1, ANH-15 all map to a single "ANH" node.
    /// When `.ssid`, each SSID gets its own node.
    @Published var stationIdentityMode: StationIdentityMode {
        didSet {
            guard stationIdentityMode != oldValue else { return }
            trackFilterChange(reason: "stationIdentityMode")
            // Identity mode affects node identity, so we need to rebuild the graph
            // and invalidate layout cache (node IDs change)
            layoutKey = nil
            layoutCache.removeAll()
            scheduleGraphBuild(reason: "stationIdentityMode")
            persistStationIdentityMode()
        }
    }

    @Published var autoUpdateEnabled: Bool {
        didSet {
            guard autoUpdateEnabled != oldValue else { return }
            persistAutoUpdateEnabled()
            if autoUpdateEnabled && isActive {
                scheduleAggregation(reason: "autoUpdateEnabled")
                scheduleGraphBuild(reason: "autoUpdateEnabled")
            }
        }
    }

    /// Graph view mode controls which edge types are visible.
    /// - `.connectivity`: Shows DirectPeer and HeardDirect edges (who can you reach directly?)
    /// - `.routing`: Shows DirectPeer and SeenVia edges (how do packets flow?)
    /// - `.all`: Shows all edge types
    @Published var graphViewMode: GraphViewMode = .connectivity {
        didSet {
            guard graphViewMode != oldValue else { return }
            trackFilterChange(reason: "graphViewMode")

            let oldNetRomMode = oldValue.netRomRoutingMode
            let newNetRomMode = graphViewMode.netRomRoutingMode

            if oldNetRomMode == newNetRomMode {
                // Same data source: only edge-type filtering changed.
                // Avoid expensive full graph rebuild.
                applyViewModeFilter()
                return
            }

            if graphViewMode.isNetRomMode {
                // Entering NET/ROM mode or switching NET/ROM routing source
                scheduleGraphBuild(reason: "graphViewMode (NET/ROM source)")
            } else if oldValue.isNetRomMode {
                // Returning from NET/ROM to packet-derived graph
                scheduleGraphBuild(reason: "graphViewMode (Return to Packet)")
            } else {
                // Packet mode to packet mode: filter only
                applyViewModeFilter()
            }
        }
    }

    @Published private(set) var viewState: AnalyticsViewState = .empty
    @Published private(set) var isAggregationLoading = false
    @Published private(set) var isGraphLoading = false
    @Published private(set) var hasLoadedAggregation = false
    @Published private(set) var hasLoadedGraph = false

    // MARK: - Focus Mode State

    /// Focus mode state for k-hop filtering
    @Published var focusState = GraphFocusState()

    /// Cached filtered graph result (recomputed when selection or focus settings change)
    @Published private(set) var filteredGraph: FilteredGraphResult = .empty

    /// Request for camera to fit to selection (consumed by view)
    @Published var fitToSelectionRequest: UUID?

    /// Optional explicit node IDs to fit when a fit request is issued.
    /// Empty set means "fit to current visible graph" behavior.
    @Published var fitTargetNodeIDs: Set<String> = []

    /// Request for camera to reset (consumed by view)
    @Published var resetCameraRequest: UUID?

    private let calendar: Calendar
    nonisolated private let databaseAggregationProvider: DatabaseAggregationProvider?
    nonisolated private let timeframePacketsProvider: TimeframePacketsProvider?
    private let packetSubject = CurrentValueSubject<[Packet], Never>([])
    private var cancellables: Set<AnyCancellable> = []
    private var packets: [Packet] = []
    private var netRomUpdateCount: Int = 0
    private var chartWidth: CGFloat = 640
    private var graphLayoutSeed: Int = 1
    private var selectionState = GraphSelectionState()
    private var layoutState: ForceLayoutState?
    private var layoutTask: Task<Void, Never>?
    private var layoutTickCount: Int = 0
    private var layoutKey: GraphLayoutKey?
    private var layoutCache: [GraphLayoutKey: [NodePosition]] = [:]
    private var myCallsignForLayout: String = ""
    private var aggregationCache: [AggregationCacheKey: AnalyticsAggregationResult] = [:]
    private var graphCache: [GraphCacheKey: GraphModel] = [:]
    private var classifiedGraphCache: [GraphCacheKey: ClassifiedGraphModel] = [:]
    nonisolated private let aggregationScheduler: CoalescingScheduler
    nonisolated private let graphScheduler: CoalescingScheduler
    private var aggregationTask: Task<Void, Never>?
    private var graphTask: Task<Void, Never>?
    private let telemetryLimiter = TelemetryRateLimiter(minimumInterval: 1.0)
    private var loopDetection = RecomputeLoopDetector()
    private var isActive = false
    private var latestTimeframePackets: [Packet] = []
    private var hasPrewarmed = false
    private var lastPinnedRefitTimestamp: Date = .distantPast
    private var lastPinnedRefitNodeIDs: Set<String> = []
    private var lastPinnedRefitBounds: RefitBounds?

    /// Gate constants for automatic viewport maintenance.
    /// Tuned to avoid jarring camera movement while still correcting meaningful drift.
    private let pinnedRefitCooldown: TimeInterval = 0.45
    private let pinnedRefitCenterThreshold: Double = 0.02
    private let pinnedRefitSpanThreshold: Double = 0.03

    /// Creates the view model, optionally loading persisted settings.
    ///
    /// - Parameters:
    ///   - settingsStore: If provided, settings are loaded from and persisted to this store.
    ///   - calendar: Calendar for date calculations.
    ///   - packetDebounce: Debounce interval for packet aggregation.
    ///   - graphDebounce: Debounce interval for graph building.
    ///   - packetScheduler: RunLoop for packet processing.
    init(
        settingsStore: AppSettingsStore? = nil,
        netRomIntegration: NetRomIntegration? = nil,
        databaseAggregationProvider: DatabaseAggregationProvider? = nil,
        timeframePacketsProvider: TimeframePacketsProvider? = nil,
        calendar: Calendar = .current,
        packetDebounce: TimeInterval = 0.25,
        graphDebounce: TimeInterval = 0.4,
        packetScheduler: RunLoop = .main
    ) {
        self.settingsStore = settingsStore
        self.netRomIntegration = netRomIntegration
        self.databaseAggregationProvider = databaseAggregationProvider
        self.timeframePacketsProvider = timeframePacketsProvider
        self.calendar = calendar

        // Load from settings store or use defaults
        let loadedTimeframe = Self.loadTimeframe(from: settingsStore)
        let loadedBucket = Self.loadBucketSelection(from: settingsStore)
        let loadedIncludeVia = settingsStore?.analyticsIncludeVia ?? AppSettingsStore.defaultAnalyticsIncludeVia
        let loadedMinEdgeCount = settingsStore?.analyticsMinEdgeCount ?? AppSettingsStore.defaultAnalyticsMinEdgeCount
        let loadedMaxNodes = settingsStore?.analyticsMaxNodes ?? AppSettingsStore.defaultAnalyticsMaxNodes
        let loadedHubMetric = Self.loadHubMetric(from: settingsStore)
        let loadedStationIdentityMode = Self.loadStationIdentityMode(from: settingsStore)
        let loadedAutoUpdateEnabled = settingsStore?.analyticsAutoUpdateEnabled ?? AppSettingsStore.defaultAnalyticsAutoUpdateEnabled

        // Compute default range for bucket resolution
        let defaultRange = loadedTimeframe.dateInterval(
            now: Date(),
            customStart: Date().addingTimeInterval(-3600),
            customEnd: Date()
        )
        let initialChartWidth: CGFloat = 640

        // Initialize all stored properties first (required before accessing self)
        self.timeframe = loadedTimeframe
        self.bucketSelection = loadedBucket
        self.includeViaDigipeaters = loadedIncludeVia
        self.minEdgeCount = AnalyticsInputNormalizer.minEdgeCount(loadedMinEdgeCount)
        self.maxNodes = AnalyticsInputNormalizer.maxNodes(loadedMaxNodes)
        self.stationIdentityMode = loadedStationIdentityMode
        self.autoUpdateEnabled = loadedAutoUpdateEnabled
        self.customRangeStart = defaultRange.start
        self.customRangeEnd = defaultRange.end
        self.resolvedBucket = loadedBucket.resolvedBucket(
            for: loadedTimeframe,
            chartWidth: initialChartWidth,
            customRange: defaultRange
        )
        self.aggregationScheduler = CoalescingScheduler(delay: .milliseconds(Int(packetDebounce * 1000)))
        self.graphScheduler = CoalescingScheduler(delay: .milliseconds(Int(graphDebounce * 1000)))

        // Now that all stored properties are initialized, we can access self
        self.focusState.hubMetric = loadedHubMetric

        bindPackets(packetScheduler: packetScheduler)
        bindNetRomUpdates()
        bindFocusState()
    }

    // MARK: - Settings Persistence Helpers

    private static func loadTimeframe(from store: AppSettingsStore?) -> AnalyticsTimeframe {
        guard let store else { return .twentyFourHours }
        return AnalyticsTimeframe(rawValue: store.analyticsTimeframe) ?? .twentyFourHours
    }

    private static func loadBucketSelection(from store: AppSettingsStore?) -> AnalyticsBucketSelection {
        guard let store else { return .auto }
        return AnalyticsBucketSelection(rawValue: store.analyticsBucket) ?? .auto
    }

    private static func loadHubMetric(from store: AppSettingsStore?) -> HubMetric {
        guard let store else { return .degree }
        // HubMetric raw values are capitalized ("Degree", "Traffic", "Bridges")
        return HubMetric(rawValue: store.analyticsHubMetric) ?? .degree
    }

    private static func loadStationIdentityMode(from store: AppSettingsStore?) -> StationIdentityMode {
        guard let store else { return .station }
        return StationIdentityMode(rawValue: store.analyticsStationIdentityMode) ?? .station
    }

    private func persistTimeframe() {
        settingsStore?.analyticsTimeframe = timeframe.rawValue
    }

    private func persistBucket() {
        settingsStore?.analyticsBucket = bucketSelection.rawValue
    }

    private func persistIncludeVia() {
        settingsStore?.analyticsIncludeVia = includeViaDigipeaters
    }

    private func persistMinEdgeCount() {
        settingsStore?.analyticsMinEdgeCount = minEdgeCount
    }

    private func persistMaxNodes() {
        settingsStore?.analyticsMaxNodes = maxNodes
    }

    private func persistStationIdentityMode() {
        settingsStore?.analyticsStationIdentityMode = stationIdentityMode.rawValue
    }

    private func persistAutoUpdateEnabled() {
        settingsStore?.analyticsAutoUpdateEnabled = autoUpdateEnabled
    }

    private func persistHubMetric() {
        settingsStore?.analyticsHubMetric = focusState.hubMetric.rawValue
    }

    func updatePackets(_ packets: [Packet]) {
        self.packets = packets
        guard isActive else { return }
        packetSubject.send(packets)
    }

    /// Precomputes analytics caches while the dashboard is not visible, so first open is fast.
    /// Safe to call repeatedly; only the first invocation performs work.
    func prewarmIfNeeded(with packets: [Packet]) {
        self.packets = packets
        guard !isActive, !hasPrewarmed else { return }
        hasPrewarmed = true
        Task(priority: .utility) { [weak self] in
            await self?.recomputeAggregation(reason: "prewarm", applyToViewState: false, showLoadingState: false)
        }
        Task(priority: .utility) { [weak self] in
            await self?.rebuildGraph(reason: "prewarm", applyToViewState: false, showLoadingState: false)
        }
    }

    func updateChartWidth(_ width: CGFloat) {
        guard width > 0, abs(width - chartWidth) > 4 else { return }
        chartWidth = width
        let bucketChanged = updateResolvedBucket(reason: "chartWidth")
        if bucketSelection == .auto, bucketChanged {
            scheduleAggregation(reason: "chartWidth")
        }
    }

    func resetGraphView() {
        graphLayoutSeed += 1
        layoutKey = nil
        layoutCache.removeAll()
        prepareLayout(reason: "graphReset")
    }

    /// Set once so radial layout can center on "my" node; call when graph section is shown or settings change.
    func setMyCallsignForLayout(_ value: String) {
        guard value != myCallsignForLayout else { return }
        myCallsignForLayout = value
        if !viewState.graphModel.nodes.isEmpty {
            prepareLayout(reason: "myCallsign")
        }
    }

    func trackDashboardOpened() {
        Telemetry.breadcrumb(
            category: "analytics.dashboard.opened",
            message: "Analytics dashboard opened",
            data: nil
        )
    }

    func handleNodeClick(_ nodeID: String, isShift: Bool) {
        let effect = GraphSelectionReducer.reduce(
            state: &selectionState,
            action: .clickNode(id: nodeID, isShift: isShift)
        )
        updateSelectionState()

        if let node = viewState.graphModel.nodes.first(where: { $0.id == nodeID }) {
            Telemetry.breadcrumb(
                category: "graph.selectNode",
                message: "Graph node selected",
                data: [
                    "nodeID": nodeID,
                    "callsign": node.callsign
                ]
            )
        }

        handleSelectionEffect(effect)
    }

    func handleSelectionRect(_ nodeIDs: Set<String>, isShift: Bool) {
        let effect = GraphSelectionReducer.reduce(
            state: &selectionState,
            action: .selectMany(ids: nodeIDs, isShift: isShift)
        )
        updateSelectionState()
        handleSelectionEffect(effect)
    }

    func handleBackgroundClick() {
        _ = GraphSelectionReducer.reduce(state: &selectionState, action: .clickBackground)
        updateSelectionState()
    }

    /// Clears selection entirely and fits view to all visible nodes.
    /// Called from toolbar "Clear" button and sidebar "Clear Selection" button.
    func clearSelectionAndFit() {
        _ = GraphSelectionReducer.reduce(state: &selectionState, action: .clickBackground)
        updateSelectionState()
        // Fit to visible nodes after clearing
        fitTargetNodeIDs = []
        fitToSelectionRequest = UUID()

        Telemetry.breadcrumb(
            category: "graph.clearSelection",
            message: "Selection cleared and fit to view requested"
        )
    }

    func updateHover(for nodeID: String?) {
        viewState.hoveredNodeID = nodeID
    }

    func manualRefresh() {
        guard isActive else { return }
        isAggregationLoading = true
        isGraphLoading = true
        scheduleAggregation(reason: "manualRefresh")
        scheduleGraphBuild(reason: "manualRefresh")
    }

    func handleEscape() {
        handleBackgroundClick()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            logger.debug("Analytics dashboard activated")
            if !hasLoadedAggregation {
                isAggregationLoading = true
            }
            if !hasLoadedGraph {
                isGraphLoading = true
            }
            Task { [weak self] in
                await self?.recomputeAggregation(reason: "activate", applyToViewState: true, showLoadingState: true)
            }
            Task { [weak self] in
                await self?.rebuildGraph(reason: "activate", applyToViewState: true, showLoadingState: true)
            }
        } else {
            logger.debug("Analytics dashboard deactivated")
            cancelWork()
        }
    }

    func selectedNodeDetails() -> GraphInspectorDetails? {
        guard let selectedNodeID = viewState.selectedNodeID,
              let node = viewState.graphModel.nodes.first(where: { $0.id == selectedNodeID }) else {
            return nil
        }
        let neighbors = viewState.graphModel.adjacency[selectedNodeID] ?? []

        // Get classified relationships from the classified graph model
        let relationships = viewState.classifiedGraphModel.relationships(for: selectedNodeID)
        let directPeers = relationships.filter { $0.linkType == .directPeer }
        let heardDirect = relationships.filter { $0.linkType == .heardDirect }
        let seenVia = relationships.filter { $0.linkType == .heardVia }

        return GraphInspectorDetails(
            node: node,
            neighbors: neighbors,
            directPeers: directPeers,
            heardDirect: heardDirect,
            seenVia: seenVia
        )
    }

    func selectedMultiNodeDetails() -> GraphMultiInspectorDetails? {
        let selectedIDs = viewState.selectedNodeIDs
        guard selectedIDs.count >= 2 else { return nil }

        let nodeByID = Dictionary(uniqueKeysWithValues: viewState.graphModel.nodes.map { ($0.id, $0) })
        let selectedNodes = selectedIDs.compactMap { nodeByID[$0] }.sorted { $0.callsign < $1.callsign }
        guard selectedNodes.count >= 2 else { return nil }

        let selectedIDSet = Set(selectedNodes.map(\.id))
        let selectedCount = selectedNodes.count
        let possibleInternalLinks = selectedCount * (selectedCount - 1) / 2

        let internalLinks = viewState.graphModel.edges
            .filter { selectedIDSet.contains($0.sourceID) && selectedIDSet.contains($0.targetID) }
            .map { edge in
                GraphMultiInspectorDetails.InternalLink(
                    sourceID: edge.sourceID,
                    sourceCallsign: nodeByID[edge.sourceID]?.callsign ?? edge.sourceID,
                    targetID: edge.targetID,
                    targetCallsign: nodeByID[edge.targetID]?.callsign ?? edge.targetID,
                    packetCount: edge.weight,
                    bytes: edge.bytes
                )
            }
            .sorted {
                if $0.packetCount != $1.packetCount { return $0.packetCount > $1.packetCount }
                return $0.sortKey < $1.sortKey
            }

        let internalPacketCount = internalLinks.reduce(0) { $0 + $1.packetCount }
        let internalByteCount = internalLinks.reduce(0) { $0 + $1.bytes }
        let selectedNodeTotalBytes = selectedNodes.reduce(0) { $0 + $1.inBytes + $1.outBytes }
        let touchingByteCount = max(0, selectedNodeTotalBytes - internalByteCount)

        var externalAggregate: [String: GraphMultiInspectorDetails.SharedExternalConnection] = [:]
        for selectedID in selectedIDSet {
            guard let relationships = viewState.graphModel.adjacency[selectedID] else { continue }
            for rel in relationships where !selectedIDSet.contains(rel.id) {
                let callsign = nodeByID[rel.id]?.callsign ?? rel.id
                var entry = externalAggregate[rel.id] ?? GraphMultiInspectorDetails.SharedExternalConnection(
                    id: rel.id,
                    callsign: callsign,
                    connectedSelectedIDs: [],
                    totalPackets: 0
                )
                entry.connectedSelectedIDs.insert(selectedID)
                entry.totalPackets += rel.weight
                externalAggregate[rel.id] = entry
            }
        }

        let sharedExternalConnections = externalAggregate.values
            .filter { $0.connectedSelectedIDs.count >= 2 }
            .sorted {
                if $0.connectedSelectedIDs.count != $1.connectedSelectedIDs.count {
                    return $0.connectedSelectedIDs.count > $1.connectedSelectedIDs.count
                }
                if $0.totalPackets != $1.totalPackets {
                    return $0.totalPackets > $1.totalPackets
                }
                return $0.callsign < $1.callsign
            }

        // Relationship breakdown uses classified edges so the inspector can explain interaction type.
        let relationshipBreakdown = Dictionary(
            grouping: viewState.classifiedGraphModel.edges.filter {
                selectedIDSet.contains($0.sourceID) && selectedIDSet.contains($0.targetID)
            },
            by: \.linkType
        ).mapValues { edges in
            edges.reduce(0) { $0 + $1.weight }
        }

        return GraphMultiInspectorDetails(
            selectedNodes: selectedNodes,
            internalLinks: internalLinks,
            sharedExternalConnections: sharedExternalConnections,
            relationshipBreakdown: relationshipBreakdown,
            possibleInternalLinks: possibleInternalLinks,
            internalPacketCount: internalPacketCount,
            internalByteCount: internalByteCount,
            touchingByteCount: touchingByteCount
        )
    }

    deinit {
        aggregationTask?.cancel()
        graphTask?.cancel()
        layoutTask?.cancel()
        aggregationScheduler.cancel()
        graphScheduler.cancel()
    }

    private func bindPackets(packetScheduler: RunLoop) {
        packetSubject
            .sink { [weak self] packets in
                self?.packets = packets
                guard self?.autoUpdateEnabled == true else { return }
                self?.scheduleAggregation(reason: "packets")
                // NET/ROM graph modes are built from routing snapshots, not packet edge classification.
                // Skip packet-driven graph rebuilds in those modes to reduce churn and UI heaviness.
                if self?.graphViewMode.isNetRomMode == false {
                    self?.scheduleGraphBuild(reason: "packets")
                }
            }
            .store(in: &cancellables)
    }

    private func bindNetRomUpdates() {
        guard let netRomIntegration else { return }
        
        netRomIntegration.didUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard self?.autoUpdateEnabled == true else { return }
                self?.netRomUpdateCount += 1
                self?.scheduleGraphBuild(reason: "NET/ROM update")
            }
            .store(in: &cancellables)
    }

    /// Observes focusState changes (from UI bindings) and recomputes filtered graph
    private func bindFocusState() {
        $focusState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recomputeFilteredGraph()
            }
            .store(in: &cancellables)
    }

    private func trackFilterChange(reason: String) {
        Telemetry.breadcrumb(
            category: "analytics.filter.changed",
            message: "Analytics filter changed",
            data: [
                "reason": reason,
                "timeframe": timeframe.displayName,
                "bucket": resolvedBucket.displayName,
                "includeVia": includeViaDigipeaters,
                "minEdgeCount": minEdgeCount,
                "maxNodes": maxNodes
            ]
        )
    }

    private func scheduleAggregation(reason: String) {
        guard isActive else { return }
        #if DEBUG
        debugLog("Scheduling aggregation: \(reason)")
        #endif
        aggregationScheduler.schedule { [weak self] in
            await self?.recomputeAggregation(reason: reason)
        }
    }

    private func scheduleGraphBuild(reason: String) {
        guard isActive else { return }
        isGraphLoading = true
        #if DEBUG
        debugLog("Scheduling graph build: \(reason)")
        #endif
        graphScheduler.schedule { [weak self] in
            await self?.rebuildGraph(reason: reason)
        }
    }

    private func recomputeAggregation(reason: String, applyToViewState: Bool = true, showLoadingState: Bool = true) async {
        let now = Date()
        let packetSnapshot = filteredPackets(now: now)
        let timeframeInterval = currentDateRange(now: now)
        let bucketSnapshot = resolvedBucket
        let includeViaSnapshot = includeViaDigipeaters
        let key = AggregationCacheKey(
            timeframe: timeframe,
            bucket: bucketSnapshot,
            includeVia: includeViaSnapshot,
            packetCount: packetSnapshot.count,
            lastTimestamp: packetSnapshot.map { $0.timestamp }.max(),
            customStart: customRangeStart,
            customEnd: customRangeEnd
        )

        if loopDetection.record(reason: reason) {
            telemetryLimiter.breadcrumb(
                category: "analytics.stateLoop.detected",
                message: "Repeated analytics recompute detected",
                data: [
                    "reason": reason,
                    "packetCount": packetSnapshot.count
                ]
            )
        }

        let inputsHash = AnalyticsInputHasher.hash(
            timeframe: timeframe,
            bucket: bucketSnapshot,
            includeVia: includeViaSnapshot,
            packetCount: packetSnapshot.count,
            lastTimestamp: packetSnapshot.last?.timestamp,
            customStart: customRangeStart,
            customEnd: customRangeEnd
        )
        telemetryLimiter.breadcrumb(
            category: "analytics.recompute.requested",
            message: "Analytics recompute requested",
            data: [
                "reason": reason,
                "inputsHash": inputsHash
            ]
        )

        if let cached = aggregationCache[key] {
            if applyToViewState {
                applyAggregationResult(cached)
                hasLoadedAggregation = true
            }
            if showLoadingState {
                isAggregationLoading = false
            }
            return
        }

        telemetryLimiter.breadcrumb(
            category: "analytics.recompute.started",
            message: "Analytics recompute started",
            data: [
                TelemetryContext.packetCount: packetSnapshot.count,
                "timeframe": timeframe.displayName,
                "bucket": bucketSnapshot.displayName,
                "includeVia": includeViaSnapshot,
                "reason": reason
            ]
        )

        let histogramBinCount = AnalyticsStyle.Histogram.binCount
        let topLimit = AnalyticsStyle.Tables.topLimit
        let provider = databaseAggregationProvider
        if showLoadingState {
            isAggregationLoading = true
        }

        aggregationTask?.cancel()
        aggregationTask = Task.detached(priority: .userInitiated) { [calendar] in
            let start = Date()
            let result: AnalyticsAggregationResult
            if let providerResult = await provider?(
                timeframeInterval,
                bucketSnapshot,
                calendar,
                includeViaSnapshot,
                histogramBinCount,
                topLimit
            ) {
                result = providerResult
            } else {
                result = AnalyticsAggregator.aggregate(
                    packets: packetSnapshot,
                    bucket: bucketSnapshot,
                    calendar: calendar,
                    options: AnalyticsAggregator.Options(
                        includeViaDigipeaters: includeViaSnapshot,
                        histogramBinCount: histogramBinCount,
                        topLimit: topLimit
                    ),
                    timeframeInterval: timeframeInterval
                )
            }
            let duration = Date().timeIntervalSince(start) * 1000
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.aggregationCache[key] = result
                if applyToViewState {
                    self.applyAggregationResult(result)
                    self.hasLoadedAggregation = true
                }
                if showLoadingState {
                    self.isAggregationLoading = false
                }
                self.telemetryLimiter.breadcrumb(
                    category: "analytics.recompute.finished",
                    message: "Analytics recompute finished",
                    data: [
                        "durationMs": duration,
                        "packetSeries": result.series.packetsPerBucket.count,
                        "byteSeries": result.series.bytesPerBucket.count,
                        "uniqueSeries": result.series.uniqueStationsPerBucket.count
                    ]
                )

                let heatmapTotal = result.heatmap.matrix.flatMap { $0 }.reduce(0, +)
                if heatmapTotal != result.summary.totalPackets {
                    Telemetry.capture(
                        message: "analytics.heatmap.total.mismatch",
                        data: [
                            "heatmapTotal": heatmapTotal,
                            "packetTotal": result.summary.totalPackets
                        ]
                    )
                }
            }
        }
    }

    private func applyAggregationResult(_ result: AnalyticsAggregationResult) {
        viewState.summary = result.summary
        viewState.series = result.series
        viewState.heatmap = result.heatmap
        viewState.histogram = result.histogram
        viewState.topTalkers = result.topTalkers
        viewState.topDestinations = result.topDestinations
        viewState.topDigipeaters = result.topDigipeaters
    }

    @discardableResult
    private func updateResolvedBucket(reason: String) -> Bool {
        let range = currentDateRange(now: Date())
        let nextBucket = bucketSelection.resolvedBucket(
            for: timeframe,
            chartWidth: chartWidth,
            customRange: range
        )
        guard nextBucket != resolvedBucket else { return false }
        resolvedBucket = nextBucket
        return true
    }

    private func currentDateRange(now: Date) -> DateInterval {
        timeframe.dateInterval(now: now, customStart: customRangeStart, customEnd: customRangeEnd)
    }

    private func filteredPackets(now: Date) -> [Packet] {
        let range = currentDateRange(now: now)
        return packets.filter { range.contains($0.timestamp) }
    }

    private func timeframePacketSnapshot(now: Date) async -> [Packet] {
        let range = currentDateRange(now: now)
        if let providerPackets = await timeframePacketsProvider?(range) {
            return providerPackets
        }
        return filteredPackets(now: now)
    }

    private func rebuildGraph(reason: String, applyToViewState: Bool = true, showLoadingState: Bool = true) async {
        let now = Date()
        let packetSnapshot = await timeframePacketSnapshot(now: now)
        latestTimeframePackets = packetSnapshot
        let includeViaSnapshot = includeViaDigipeaters
        let minEdgeSnapshot = minEdgeCount
        let maxNodesSnapshot = maxNodes
        let identityModeSnapshot = stationIdentityMode
        let hideStaleSnapshot = settingsStore?.hideExpiredRoutes ?? AppSettingsStore.defaultHideExpiredRoutes
        let neighborStaleTTLSnapshot = TimeInterval((settingsStore?.neighborStaleTTLHours ?? AppSettingsStore.defaultNeighborStaleTTLHours) * 3600)
        let routeStaleTTLSnapshot = TimeInterval((settingsStore?.globalStaleTTLHours ?? AppSettingsStore.defaultGlobalStaleTTLHours) * 3600)
        let key = GraphCacheKey(
            timeframe: timeframe,
            includeVia: includeViaSnapshot,
            minEdgeCount: minEdgeSnapshot,
            maxNodes: maxNodesSnapshot,
            stationIdentityMode: identityModeSnapshot,
            viewMode: graphViewMode, // Added to differentiate NET/ROM vs Packet modes
            packetCount: packetSnapshot.count,
            lastTimestamp: packetSnapshot.map { $0.timestamp }.max(),
            netRomUpdateCount: netRomUpdateCount,
            customStart: customRangeStart,
            customEnd: customRangeEnd
        )

        // Check cache for classified graph
        if let cachedClassified = classifiedGraphCache[key] {
            if applyToViewState {
                applyClassifiedGraphModel(cachedClassified)
                prepareLayout(reason: "graphCache")
                hasLoadedGraph = true
            }
            if showLoadingState {
                isGraphLoading = false
            }
            return
        }

        // Fallback to legacy cache for backwards compatibility
        if let cached = graphCache[key] {
            if applyToViewState {
                applyGraphModel(cached)
                prepareLayout(reason: "graphCache")
                hasLoadedGraph = true
            }
            if showLoadingState {
                isGraphLoading = false
            }
            return
        }
        if showLoadingState {
            isGraphLoading = true
        }

        telemetryLimiter.breadcrumb(
            category: "graph.build.started",
            message: "Graph build started",
            data: [
                TelemetryContext.packetCount: packetSnapshot.count,
                "timeframe": timeframe.displayName,
                "includeVia": includeViaSnapshot,
                "minEdgeCount": minEdgeSnapshot,
                "maxNodes": maxNodesSnapshot,
                "reason": reason
            ]
        )

        let routingModeSnapshot = graphViewMode.netRomRoutingMode
        // Snapshot NET/ROM data on the main actor before detaching,
        // since NetRomIntegration is @MainActor-isolated.
        let neighborsSnapshot: [NeighborInfo]?
        let routesSnapshot: [RouteInfo]?
        let netRomLocalCallsign: String?
        if let mode = routingModeSnapshot, let integration = netRomIntegration {
            neighborsSnapshot = integration.currentNeighbors(forMode: mode)
            routesSnapshot = integration.currentRoutes(forMode: mode)
            netRomLocalCallsign = integration.localCallsign
        } else {
            neighborsSnapshot = nil
            routesSnapshot = nil
            netRomLocalCallsign = nil
        }

        graphTask?.cancel()
        graphTask = Task.detached(priority: .userInitiated) {
            let start = Date()

            let classifiedModel: ClassifiedGraphModel
            if let neighbors = neighborsSnapshot, let routes = routesSnapshot, let localCall = netRomLocalCallsign {
                // Build from pre-snapshotted NET/ROM routing tables
                classifiedModel = NetworkGraphBuilder.buildFromNetRom(
                    neighbors: neighbors,
                    routes: routes,
                    localCallsign: localCall,
                    options: NetworkGraphBuilder.Options(
                        includeViaDigipeaters: includeViaSnapshot,
                        minimumEdgeCount: minEdgeSnapshot,
                        maxNodes: maxNodesSnapshot,
                        stationIdentityMode: identityModeSnapshot,
                        hideStaleEntries: hideStaleSnapshot,
                        neighborStaleTTL: neighborStaleTTLSnapshot,
                        routeStaleTTL: routeStaleTTLSnapshot
                    ),
                    now: now
                )
            } else {
                // Build the classified graph with typed edges from packets
                classifiedModel = NetworkGraphBuilder.buildClassified(
                    packets: packetSnapshot,
                    options: NetworkGraphBuilder.Options(
                        includeViaDigipeaters: includeViaSnapshot,
                        minimumEdgeCount: minEdgeSnapshot,
                        maxNodes: maxNodesSnapshot,
                        stationIdentityMode: identityModeSnapshot
                    ),
                    now: now
                )
            }
            
            let duration = Date().timeIntervalSince(start) * 1000
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.classifiedGraphCache[key] = classifiedModel
                if applyToViewState {
                    self.applyClassifiedGraphModel(classifiedModel)
                    self.hasLoadedGraph = true
                }
                if showLoadingState {
                    self.isGraphLoading = false
                }
                self.telemetryLimiter.breadcrumb(
                    category: "graph.build.finished",
                    message: "Graph build finished",
                    data: [
                        "durationMs": duration,
                        "nodeCount": classifiedModel.nodes.count,
                        "edgeCount": classifiedModel.edges.count
                    ]
                )

                if packetSnapshot.isEmpty == false && classifiedModel.nodes.isEmpty {
                    Telemetry.capture(
                        message: "graph.build.empty",
                        data: [
                            "packetCount": packetSnapshot.count,
                            "includeVia": includeViaSnapshot,
                            "minEdgeCount": minEdgeSnapshot
                        ]
                    )
                }

                if applyToViewState {
                    self.prepareLayout(reason: "graphBuild")
                }
            }
        }
    }

    /// Applies a classified graph model, filtering edges based on the current view mode.
    private func applyClassifiedGraphModel(_ classifiedModel: ClassifiedGraphModel) {
        // Store the full classified model for inspector use
        viewState.classifiedGraphModel = classifiedModel

        // Filter edges based on view mode and convert to GraphModel for rendering
        let viewModel = deriveViewGraph(from: classifiedModel)
        viewState.graphModel = viewModel
        viewState.graphNote = classifiedModel.droppedNodesCount > 0 ? "Showing top \(maxNodes) nodes" : nil
        updateNetworkHealth()
        // Keep explicit fit targets valid as the graph content changes.
        fitTargetNodeIDs.formIntersection(Set(viewModel.nodes.map(\.id)))
        // Recompute filtered graph when underlying model changes
        recomputeFilteredGraph()
    }

    /// Derives a GraphModel from a ClassifiedGraphModel by filtering edges based on view mode.
    private func deriveViewGraph(from classifiedModel: ClassifiedGraphModel) -> GraphModel {
        let visibleTypes = graphViewMode.visibleLinkTypes
        let filteredEdges = classifiedModel.edges
            .filter { visibleTypes.contains($0.linkType) }
            .map { edge in
                NetworkGraphEdge(
                    sourceID: edge.sourceID,
                    targetID: edge.targetID,
                    weight: edge.weight,
                    bytes: Int(edge.bytes),
                    linkType: edge.linkType,
                    isStale: edge.isStale
                )
            }

        // Build adjacency from filtered edges
        var adjacency: [String: [GraphNeighborStat]] = [:]
        for edge in filteredEdges {
            adjacency[edge.sourceID, default: []].append(
                GraphNeighborStat(id: edge.targetID, weight: edge.weight, bytes: edge.bytes, isStale: edge.isStale)
            )
            adjacency[edge.targetID, default: []].append(
                GraphNeighborStat(id: edge.sourceID, weight: edge.weight, bytes: edge.bytes, isStale: edge.isStale)
            )
        }

        // Recalculate degrees based on filtered edges
        let updatedNodes = classifiedModel.nodes.map { node in
            let neighbors = adjacency[node.id] ?? []
            return NetworkGraphNode(
                id: node.id,
                callsign: node.callsign,
                weight: node.weight,
                inCount: node.inCount,
                outCount: node.outCount,
                inBytes: node.inBytes,
                outBytes: node.outBytes,
                degree: neighbors.count,
                groupedSSIDs: node.groupedSSIDs,
                isNetRomOfficial: node.isNetRomOfficial
            )
        }

        // Sort adjacency by weight
        let sortedAdjacency = adjacency.mapValues { neighbors in
            neighbors.sorted { lhs, rhs in
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.id < rhs.id
            }
        }

        return GraphModel(
            nodes: updatedNodes,
            edges: filteredEdges.sorted { lhs, rhs in
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.sourceID < rhs.sourceID
            },
            adjacency: sortedAdjacency,
            droppedNodesCount: classifiedModel.droppedNodesCount
        )
    }

    /// Reapplies the view mode filter to the current classified graph.
    /// Called when graphViewMode changes without rebuilding the underlying graph.
    private func applyViewModeFilter() {
        guard !viewState.classifiedGraphModel.nodes.isEmpty else { return }
        let viewModel = deriveViewGraph(from: viewState.classifiedGraphModel)
        viewState.graphModel = viewModel
        // Keep explicit fit targets valid as the graph content changes.
        fitTargetNodeIDs.formIntersection(Set(viewModel.nodes.map(\.id)))
        recomputeFilteredGraph()
    }

    private func applyGraphModel(_ model: GraphModel) {
        viewState.graphModel = model
        viewState.graphNote = model.droppedNodesCount > 0 ? "Showing top \(maxNodes) nodes" : nil
        updateNetworkHealth()
        // Recompute filtered graph when underlying model changes
        recomputeFilteredGraph()
    }

    private func updateNetworkHealth() {
        let now = Date()
        let timeframePackets = latestTimeframePackets

        // Network Health uses a CANONICAL graph (minEdge=2, no max nodes) that ignores view filters.
        // This ensures the health score is stable under Min Edge slider and Max Node count changes.
        // Only timeframe, includeViaDigipeaters toggle, and time passing affect the score.
        let health = NetworkHealthCalculator.calculate(
            graphModel: viewState.graphModel,
            timeframePackets: timeframePackets,
            allRecentPackets: packets,
            timeframeDisplayName: timeframe.displayName,
            includeViaDigipeaters: includeViaDigipeaters,
            now: now
        )
        viewState.networkHealth = health
    }

    /// Returns the ID of the primary hub based on the current hub metric.
    /// Uses GraphAlgorithms for consistent hub selection across the app.
    func primaryHubNodeID() -> String? {
        GraphAlgorithms.findPrimaryHub(
            model: viewState.graphModel,
            metric: focusState.hubMetric
        )
    }

    /// Returns IDs of stations active in the last 10 minutes
    func activeNodeIDs() -> Set<String> {
        let recentCutoff = Date().addingTimeInterval(-600) // 10 minutes
        let recentPackets = packets.filter { $0.timestamp >= recentCutoff }
        var activeCallsigns: Set<String> = []
        for packet in recentPackets {
            if let from = packet.from?.call { activeCallsigns.insert(from) }
            if let to = packet.to?.call { activeCallsigns.insert(to) }
        }
        // Map callsigns to node IDs
        return Set(viewState.graphModel.nodes.filter { activeCallsigns.contains($0.callsign) }.map { $0.id })
    }

    // MARK: - Focus Mode Actions

    /// Selects the primary hub, sets it as anchor, enables focus mode, and fits.
    ///
    /// Design: "Focus Primary Hub" does:
    /// 1. Finds hub node (based on current hubMetric)
    /// 2. Sets it as focus ANCHOR (independent from selection)
    /// 3. Also selects it (for inspection convenience)
    /// 4. Enables focus mode (k-hop neighborhood filtering)
    /// 5. Performs ONE animated fit
    /// 6. Shows status message if neighborhood is small
    func selectPrimaryHub() {
        let metricName = focusState.hubMetric.rawValue
        guard let hubID = primaryHubNodeID(),
              let hubNode = viewState.graphModel.nodes.first(where: { $0.id == hubID }) else {
            // No hub found - graph might be empty
            logger.warning("No primary hub found for metric \(metricName)")
            return
        }

        // Set as focus anchor
        focusState.setAnchor(nodeID: hubID, displayName: hubNode.callsign)

        // Also select it for inspection convenience
        _ = GraphSelectionReducer.reduce(
            state: &selectionState,
            action: .clickNode(id: hubID, isShift: false)
        )
        updateSelectionState()

        // Recompute filtered graph
        recomputeFilteredGraph()

        // Log if neighborhood is small for debugging
        let neighborCount = filteredGraph.visibleNodeIDs.count - 1 // exclude anchor
        let maxHops = focusState.maxHops
        if neighborCount == 0 {
            logger.info("Hub \(hubID) has no neighbors in \(maxHops)-hop neighborhood")
        }

        // Request a single fit
        focusState.didAutoFitForCurrentAnchor = true
        fitTargetNodeIDs = []
        fitToSelectionRequest = UUID()

        Telemetry.breadcrumb(
            category: "graph.focusHub",
            message: "Primary hub set as focus anchor",
            data: [
                "hubID": hubID,
                "metric": metricName,
                "maxHops": maxHops,
                "visibleNodes": filteredGraph.visibleNodeIDs.count
            ]
        )
    }

    /// Single selection: sets selected node as focus anchor and fits focused graph.
    /// Multi-selection: keeps current focus state and fits camera to selected node extents.
    func setSelectedAsAnchor() {
        let selectedIDs = viewState.selectedNodeIDs
        guard !selectedIDs.isEmpty else { return }

        if selectedIDs.count > 1 {
            // Multi-select action is view-centric: zoom to selected extents.
            fitTargetNodeIDs = selectedIDs
            fitToSelectionRequest = UUID()

            Telemetry.breadcrumb(
                category: "graph.focusSelection",
                message: "Focused selected node extents",
                data: [
                    "selectedCount": selectedIDs.count
                ]
            )
            return
        }

        guard let selectedID = selectedIDs.first,
              let selectedNode = viewState.graphModel.nodes.first(where: { $0.id == selectedID }) else { return }

        focusState.setAnchor(nodeID: selectedID, displayName: selectedNode.callsign)
        recomputeFilteredGraph()

        // Fit to the new focus area.
        fitTargetNodeIDs = []
        fitToSelectionRequest = UUID()
        focusState.didAutoFitForCurrentAnchor = true

        Telemetry.breadcrumb(
            category: "graph.setAnchor",
            message: "Selected node set as focus anchor",
            data: [
                "anchorID": selectedID,
                "maxHops": focusState.maxHops
            ]
        )
    }

    /// Clears focus mode and anchor, showing all nodes.
    func clearFocus() {
        focusState.clearFocus()
        recomputeFilteredGraph()

        // Fit to show all nodes
        fitTargetNodeIDs = []
        fitToSelectionRequest = UUID()

        Telemetry.breadcrumb(
            category: "graph.clearFocus",
            message: "Focus mode cleared"
        )
    }

    /// Toggles focus mode on/off.
    /// When enabled without an anchor, uses current selection as anchor.
    func toggleFocusMode() {
        if focusState.isFocusEnabled {
            clearFocus()
        } else if let selectedID = viewState.selectedNodeID,
                  let selectedNode = viewState.graphModel.nodes.first(where: { $0.id == selectedID }) {
            focusState.setAnchor(nodeID: selectedID, displayName: selectedNode.callsign)
            recomputeFilteredGraph()
            fitTargetNodeIDs = []
            fitToSelectionRequest = UUID()
        }
    }

    /// Updates the max hops for focus filtering.
    func setMaxHops(_ hops: Int) {
        let clamped = hops.clamped(to: GraphFocusState.hopRange)
        guard focusState.maxHops != clamped else { return }
        focusState.maxHops = clamped
        recomputeFilteredGraph()
    }

    /// Updates the hub metric used for Primary Hub selection.
    func setHubMetric(_ metric: HubMetric) {
        guard focusState.hubMetric != metric else { return }
        focusState.hubMetric = metric
        persistHubMetric()
    }

    /// Explicit fit-to-view camera action.
    /// Computes bounding box of visible nodes and fits camera.
    func requestFitToView() {
        fitTargetNodeIDs = []
        fitToSelectionRequest = UUID()
    }

    /// Explicit reset camera action.
    /// Returns camera to default zoom/pan (zoom = 1, offset = 0).
    /// Does NOT affect selection or focus.
    func requestResetView() {
        resetCameraRequest = UUID()
    }

    /// Recomputes the filtered graph based on anchor and focus state.
    /// Focus is based on ANCHOR node, not selection.
    private func recomputeFilteredGraph() {
        if focusState.isFocusEnabled, let anchorID = focusState.anchorNodeID {
            filteredGraph = GraphAlgorithms.filterToKHop(
                model: viewState.graphModel,
                selectedNodeIDs: Set([anchorID]),
                maxHops: focusState.maxHops
            )
        } else {
            // No filtering: show all nodes and edges
            filteredGraph = FilteredGraphResult(
                visibleNodeIDs: Set(viewState.graphModel.nodes.map { $0.id }),
                visibleEdgeKeys: Set(viewState.graphModel.edges.map { FocusEdgeKey($0.sourceID, $0.targetID) }),
                focusNodeID: nil,
                hopDistances: [:]
            )
        }
    }

    /// Generates a text summary of network health for export
    func exportNetworkSummary() -> String {
        let health = viewState.networkHealth
        let metrics = health.metrics
        var lines: [String] = []

        lines.append("AXTerm Network Health Summary")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("Overall Health: \(health.rating.rawValue) (\(health.score)/100)")
        lines.append("")
        lines.append("Metrics:")
        lines.append("  Total stations heard: \(metrics.totalStations)")
        lines.append("  Active stations (10m): \(metrics.activeStations)")
        lines.append("  Total packets: \(metrics.totalPackets)")
        lines.append("  Packet rate: \(String(format: "%.2f", metrics.packetRate)) packets/min")
        lines.append("  Largest cluster: \(Int(metrics.largestComponentPercent))% of network")
        lines.append("  Top relay concentration: \(Int(metrics.topRelayConcentration))%")
        if let relay = metrics.topRelayCallsign {
            lines.append("  Top relay: \(relay)")
        }
        lines.append("  Isolated nodes: \(metrics.isolatedNodes)")
        lines.append("")

        if !health.warnings.isEmpty {
            lines.append("Warnings:")
            for warning in health.warnings {
                lines.append("  [\(warning.severity.rawValue.uppercased())] \(warning.title): \(warning.detail)")
            }
            lines.append("")
        }

        lines.append("Health Score Breakdown:")
        for reason in health.reasons {
            lines.append("  - \(reason)")
        }

        return lines.joined(separator: "\n")
    }

    private func prepareLayout(reason: String) {
        layoutTask?.cancel()
        layoutState = nil
        guard isActive else { return }
        let model = viewState.graphModel
        guard !model.nodes.isEmpty else {
            viewState.nodePositions = []
            viewState.layoutEnergy = 0
            layoutKey = nil
            return
        }

        let key = GraphLayoutKey.from(model: model)
        if let cached = layoutCache[key], key == layoutKey {
            viewState.nodePositions = cached
            viewState.layoutEnergy = 0
            reconcileSelectionAfterLayout()
            maintainPinnedSelectionViewportIfNeeded()
            return
        }

        let positions = RadialGraphLayout.layout(model: model, myCallsign: myCallsignForLayout)
        assert(positions.count == model.nodes.count, "Layout dropped nodes: \(positions.count)/\(model.nodes.count)")
        layoutKey = key
        layoutCache[key] = positions
        viewState.nodePositions = positions
        viewState.layoutEnergy = 0
        reconcileSelectionAfterLayout()
        maintainPinnedSelectionViewportIfNeeded()
    }

    private func updateSelectionState() {
        viewState.selectedNodeIDs = selectionState.selectedIDs
        selectionState.normalizePrimary()
        viewState.selectedNodeID = selectionState.primarySelectionID
        captureMissingSelectionIfNeeded()

        // If an explicit fit target is active (selection-focus mode), keep it aligned to selection changes.
        if !fitTargetNodeIDs.isEmpty {
            fitTargetNodeIDs.formIntersection(viewState.selectedNodeIDs)
        }

        // Reset auto-fit flag when selection changes (unless via selectPrimaryHub)
        // This ensures explicit selection changes don't trigger unwanted auto-fits
        focusState.didAutoFitForCurrentAnchor = false

        // Recompute filtered graph when selection changes
        recomputeFilteredGraph()
    }

    /// When explicit selection-fit mode is active, keep selected nodes in frame across graph/layout updates.
    private func maintainPinnedSelectionViewportIfNeeded() {
        if !fitTargetNodeIDs.isEmpty {
            let positionedIDs = Set(viewState.nodePositions.map(\.id))
            let validTargets = fitTargetNodeIDs.intersection(positionedIDs)
            guard !validTargets.isEmpty else { return }
            requestPinnedRefitIfNeeded(targetNodeIDs: validTargets)
            return
        }

        // Anchor-focused mode should also remain framed when graph/layout updates move nodes.
        if focusState.isFocusEnabled, focusState.anchorNodeID != nil {
            let targetIDs = filteredGraph.visibleNodeIDs.isEmpty
                ? Set(viewState.graphModel.nodes.map(\.id))
                : filteredGraph.visibleNodeIDs
            requestPinnedRefitIfNeeded(targetNodeIDs: targetIDs)
        }
    }

    private func requestPinnedRefitIfNeeded(targetNodeIDs: Set<String>) {
        guard !targetNodeIDs.isEmpty else { return }
        guard let bounds = GraphAlgorithms.boundingBox(
            visibleNodeIDs: targetNodeIDs,
            positions: viewState.nodePositions
        ) else { return }

        let now = Date()
        let cooldownElapsed = now.timeIntervalSince(lastPinnedRefitTimestamp) >= pinnedRefitCooldown
        let nodeSetChanged = targetNodeIDs != lastPinnedRefitNodeIDs
        let driftedEnough = shouldRefitForBoundsChange(bounds)

        // Only auto-refit when either:
        // 1) target set changed, or
        // 2) bounds drifted meaningfully and cooldown elapsed.
        if !nodeSetChanged && !(cooldownElapsed && driftedEnough) {
            return
        }

        fitTargetNodeIDs = targetNodeIDs
        fitToSelectionRequest = UUID()
        lastPinnedRefitTimestamp = now
        lastPinnedRefitNodeIDs = targetNodeIDs
        lastPinnedRefitBounds = RefitBounds(bounds)
    }

    private func shouldRefitForBoundsChange(
        _ bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    ) -> Bool {
        guard let previous = lastPinnedRefitBounds else { return true }
        let current = RefitBounds(bounds)
        let centerDelta = hypot(current.centerX - previous.centerX, current.centerY - previous.centerY)
        let spanDelta = abs(current.maxSpan - previous.maxSpan)
        return centerDelta >= pinnedRefitCenterThreshold || spanDelta >= pinnedRefitSpanThreshold
    }

    private func captureMissingSelectionIfNeeded() {
        let availableIDs = Set(viewState.graphModel.nodes.map { $0.id })
        let missing = viewState.selectedNodeIDs.subtracting(availableIDs)
        guard !missing.isEmpty else { return }
        Telemetry.capture(
            message: "graph.selection.missingNode",
            data: [
                "missingCount": missing.count,
                "missingIDs": Array(missing).sorted()
            ]
        )
    }

    private func reconcileSelectionAfterLayout() {
        let availableIDs = Set(viewState.graphModel.nodes.map { $0.id })
        let missing = selectionState.selectedIDs.subtracting(availableIDs)
        guard !missing.isEmpty else { return }
        Telemetry.capture(
            message: "graph.selection.missingNode",
            data: [
                "missingCount": missing.count,
                "missingIDs": Array(missing).sorted()
            ]
        )
        selectionState.selectedIDs = selectionState.selectedIDs.intersection(availableIDs)
        selectionState.normalizePrimary()
        updateSelectionState()
    }

    private func handleSelectionEffect(_ effect: GraphSelectionEffect) {
        switch effect {
        case .none:
            break
        case .inspect:
            break
        }
    }

    #if DEBUG
    private func debugLog(_ message: String) {
        print("[AnalyticsDashboardViewModel] \(message)")
    }
    #endif

    private func cancelWork() {
        aggregationTask?.cancel()
        graphTask?.cancel()
        layoutTask?.cancel()
        aggregationScheduler.cancel()
        graphScheduler.cancel()
        isAggregationLoading = false
        isGraphLoading = false
        loopDetection.reset()
    }
}

private struct RefitBounds {
    let centerX: Double
    let centerY: Double
    let maxSpan: Double

    init(_ bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)) {
        centerX = (bounds.minX + bounds.maxX) * 0.5
        centerY = (bounds.minY + bounds.maxY) * 0.5
        maxSpan = max(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY)
    }
}

private struct AggregationCacheKey: Hashable {
    let timeframe: AnalyticsTimeframe
    let bucket: TimeBucket
    let includeVia: Bool
    let packetCount: Int
    let lastTimestamp: Date?
    let customStart: Date
    let customEnd: Date
}

private struct GraphCacheKey: Hashable {
    let timeframe: AnalyticsTimeframe
    let includeVia: Bool
    let minEdgeCount: Int
    let maxNodes: Int
    let stationIdentityMode: StationIdentityMode
    let viewMode: GraphViewMode
    let packetCount: Int
    let lastTimestamp: Date?
    let netRomUpdateCount: Int
    let customStart: Date
    let customEnd: Date
}

struct GraphInspectorDetails: Hashable, Sendable {
    let node: NetworkGraphNode
    let neighbors: [GraphNeighborStat]

    /// Classified relationships grouped by link type.
    /// Used for the new inspector sections: Direct Peers, Heard Direct, Seen Via.
    let directPeers: [StationRelationship]
    let heardDirect: [StationRelationship]
    let seenVia: [StationRelationship]

    /// Creates inspector details with classified relationships.
    init(
        node: NetworkGraphNode,
        neighbors: [GraphNeighborStat],
        directPeers: [StationRelationship] = [],
        heardDirect: [StationRelationship] = [],
        seenVia: [StationRelationship] = []
    ) {
        self.node = node
        self.neighbors = neighbors
        self.directPeers = directPeers
        self.heardDirect = heardDirect
        self.seenVia = seenVia
    }
}

struct GraphMultiInspectorDetails: Hashable, Sendable {
    nonisolated struct InternalLink: Hashable, Sendable, Identifiable {
        let sourceID: String
        let sourceCallsign: String
        let targetID: String
        let targetCallsign: String
        let packetCount: Int
        let bytes: Int

        var id: String { "\(sourceID)->\(targetID)" }
        var sortKey: String { "\(sourceCallsign)|\(targetCallsign)" }
    }

    nonisolated struct SharedExternalConnection: Hashable, Sendable, Identifiable {
        let id: String
        let callsign: String
        var connectedSelectedIDs: Set<String>
        var totalPackets: Int
    }

    let selectedNodes: [NetworkGraphNode]
    let internalLinks: [InternalLink]
    let sharedExternalConnections: [SharedExternalConnection]
    let relationshipBreakdown: [LinkType: Int]
    let possibleInternalLinks: Int
    let internalPacketCount: Int
    let internalByteCount: Int
    let touchingByteCount: Int

    var selectionCount: Int { selectedNodes.count }
    var internalLinkCount: Int { internalLinks.count }
    var density: Double {
        guard possibleInternalLinks > 0 else { return 0 }
        return Double(internalLinkCount) / Double(possibleInternalLinks)
    }
    var externalReachCount: Int { sharedExternalConnections.count }
}

private enum AnalyticsInputHasher {
    static func hash(
        timeframe: AnalyticsTimeframe,
        bucket: TimeBucket,
        includeVia: Bool,
        packetCount: Int,
        lastTimestamp: Date?,
        customStart: Date,
        customEnd: Date
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(timeframe)
        hasher.combine(bucket)
        hasher.combine(includeVia)
        hasher.combine(packetCount)
        hasher.combine(lastTimestamp?.timeIntervalSince1970 ?? 0)
        hasher.combine(customStart.timeIntervalSince1970)
        hasher.combine(customEnd.timeIntervalSince1970)
        return hasher.finalize()
    }
}

private final class TelemetryRateLimiter {
    private let minimumInterval: TimeInterval
    private var lastFire: Date?

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func breadcrumb(category: String, message: String, data: [String: Any]) {
        let now = Date()
        if let lastFire, now.timeIntervalSince(lastFire) < minimumInterval {
            return
        }
        lastFire = now
        Telemetry.breadcrumb(category: category, message: message, data: data)
    }
}

private struct RecomputeLoopDetector {
    private var lastReason: String?
    private var lastTimestamp: Date?
    private var count: Int = 0

    mutating func record(reason: String) -> Bool {
        let now = Date()
        if lastReason == reason, let lastTimestamp, now.timeIntervalSince(lastTimestamp) < 0.5 {
            count += 1
        } else {
            count = 1
        }
        lastReason = reason
        lastTimestamp = now
        return count >= 4
    }

    mutating func reset() {
        lastReason = nil
        lastTimestamp = nil
        count = 0
    }
}
