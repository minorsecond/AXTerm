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
    private let logger = Logger(subsystem: "AXTerm", category: "Analytics")
    @Published var timeframe: AnalyticsTimeframe {
        didSet {
            guard timeframe != oldValue else { return }
            trackFilterChange(reason: "timeframe")
            updateResolvedBucket(reason: "timeframe")
            scheduleAggregation(reason: "timeframe")
            scheduleGraphBuild(reason: "timeframe")
        }
    }
    @Published var bucketSelection: AnalyticsBucketSelection {
        didSet {
            guard bucketSelection != oldValue else { return }
            trackFilterChange(reason: "bucket")
            updateResolvedBucket(reason: "bucket")
            scheduleAggregation(reason: "bucket")
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
        }
    }

    @Published private(set) var viewState: AnalyticsViewState = .empty

    private let calendar: Calendar
    private let packetSubject = CurrentValueSubject<[Packet], Never>([])
    private var cancellables: Set<AnyCancellable> = []
    private var packets: [Packet] = []
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
    private let aggregationScheduler: CoalescingScheduler
    private let graphScheduler: CoalescingScheduler
    private var aggregationTask: Task<Void, Never>?
    private var graphTask: Task<Void, Never>?
    private let telemetryLimiter = TelemetryRateLimiter(minimumInterval: 1.0)
    private var loopDetection = RecomputeLoopDetector()
    private var isActive = false

    init(
        calendar: Calendar = .current,
        timeframe: AnalyticsTimeframe = .oneHour,
        bucketSelection: AnalyticsBucketSelection = .auto,
        includeViaDigipeaters: Bool = false,
        minEdgeCount: Int = 1,
        maxNodes: Int? = nil,
        packetDebounce: TimeInterval = 0.25,
        graphDebounce: TimeInterval = 0.4,
        packetScheduler: RunLoop = .main
    ) {
        self.calendar = calendar
        self.timeframe = timeframe
        self.bucketSelection = bucketSelection
        self.includeViaDigipeaters = includeViaDigipeaters
        self.minEdgeCount = AnalyticsInputNormalizer.minEdgeCount(minEdgeCount)
        self.maxNodes = AnalyticsInputNormalizer.maxNodes(maxNodes ?? AnalyticsStyle.Graph.maxNodesDefault)
        let defaultRange = timeframe.dateInterval(
            now: Date(),
            customStart: Date().addingTimeInterval(-3600),
            customEnd: Date()
        )
        self.customRangeStart = defaultRange.start
        self.customRangeEnd = defaultRange.end
        self.resolvedBucket = bucketSelection.resolvedBucket(
            for: timeframe,
            chartWidth: chartWidth,
            customRange: defaultRange
        )
        self.aggregationScheduler = CoalescingScheduler(delay: .milliseconds(Int(packetDebounce * 1000)))
        self.graphScheduler = CoalescingScheduler(delay: .milliseconds(Int(graphDebounce * 1000)))
        bindPackets(packetScheduler: packetScheduler)
    }

    func updatePackets(_ packets: [Packet]) {
        self.packets = packets
        guard isActive else { return }
        packetSubject.send(packets)
    }

    func updateChartWidth(_ width: CGFloat) {
        guard width > 0, abs(width - chartWidth) > 4 else { return }
        chartWidth = width
        updateResolvedBucket(reason: "chartWidth")
        if bucketSelection == .auto {
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

    func updateHover(for nodeID: String?) {
        viewState.hoveredNodeID = nodeID
    }

    func handleEscape() {
        handleBackgroundClick()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            logger.debug("Analytics dashboard activated")
            scheduleAggregation(reason: "activate")
            scheduleGraphBuild(reason: "activate")
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
        return GraphInspectorDetails(node: node, neighbors: neighbors)
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
            .removeDuplicates(by: { lhs, rhs in
                lhs.count == rhs.count && lhs.last?.id == rhs.last?.id
            })
            .receive(on: packetScheduler)
            .sink { [weak self] packets in
                self?.packets = packets
                self?.scheduleAggregation(reason: "packets")
                self?.scheduleGraphBuild(reason: "packets")
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
        #if DEBUG
        debugLog("Scheduling graph build: \(reason)")
        #endif
        graphScheduler.schedule { [weak self] in
            await self?.rebuildGraph(reason: reason)
        }
    }

    private func recomputeAggregation(reason: String) async {
        let now = Date()
        let packetSnapshot = filteredPackets(now: now)
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
            applyAggregationResult(cached)
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

        aggregationTask?.cancel()
        aggregationTask = Task.detached(priority: .userInitiated) { [calendar] in
            let start = Date()
            let result = AnalyticsAggregator.aggregate(
                packets: packetSnapshot,
                bucket: bucketSnapshot,
                calendar: calendar,
                options: AnalyticsAggregator.Options(
                    includeViaDigipeaters: includeViaSnapshot,
                    histogramBinCount: AnalyticsStyle.Histogram.binCount,
                    topLimit: AnalyticsStyle.Tables.topLimit
                )
            )
            let duration = Date().timeIntervalSince(start) * 1000
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.aggregationCache[key] = result
                self.applyAggregationResult(result)
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

    private func updateResolvedBucket(reason: String) {
        let range = currentDateRange(now: Date())
        let nextBucket = bucketSelection.resolvedBucket(
            for: timeframe,
            chartWidth: chartWidth,
            customRange: range
        )
        guard nextBucket != resolvedBucket else { return }
        resolvedBucket = nextBucket
    }

    private func currentDateRange(now: Date) -> DateInterval {
        timeframe.dateInterval(now: now, customStart: customRangeStart, customEnd: customRangeEnd)
    }

    private func filteredPackets(now: Date) -> [Packet] {
        let range = currentDateRange(now: now)
        return packets.filter { range.contains($0.timestamp) }
    }

    private func rebuildGraph(reason: String) async {
        let now = Date()
        let packetSnapshot = filteredPackets(now: now)
        let includeViaSnapshot = includeViaDigipeaters
        let minEdgeSnapshot = minEdgeCount
        let maxNodesSnapshot = maxNodes
        let key = GraphCacheKey(
            timeframe: timeframe,
            includeVia: includeViaSnapshot,
            minEdgeCount: minEdgeSnapshot,
            maxNodes: maxNodesSnapshot,
            packetCount: packetSnapshot.count,
            lastTimestamp: packetSnapshot.map { $0.timestamp }.max(),
            customStart: customRangeStart,
            customEnd: customRangeEnd
        )

        if let cached = graphCache[key] {
            applyGraphModel(cached)
            prepareLayout(reason: "graphCache")
            return
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

        graphTask?.cancel()
        graphTask = Task.detached(priority: .userInitiated) {
            let start = Date()
            let model = NetworkGraphBuilder.build(
                packets: packetSnapshot,
                options: NetworkGraphBuilder.Options(
                    includeViaDigipeaters: includeViaSnapshot,
                    minimumEdgeCount: minEdgeSnapshot,
                    maxNodes: maxNodesSnapshot
                )
            )
            let duration = Date().timeIntervalSince(start) * 1000
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.graphCache[key] = model
                self.applyGraphModel(model)
                self.telemetryLimiter.breadcrumb(
                    category: "graph.build.finished",
                    message: "Graph build finished",
                    data: [
                        "durationMs": duration,
                        "nodeCount": model.nodes.count,
                        "edgeCount": model.edges.count
                    ]
                )

                if packetSnapshot.isEmpty == false && model.nodes.isEmpty {
                    Telemetry.capture(
                        message: "graph.build.empty",
                        data: [
                            "packetCount": packetSnapshot.count,
                            "includeVia": includeViaSnapshot,
                            "minEdgeCount": minEdgeSnapshot
                        ]
                    )
                }

                self.prepareLayout(reason: "graphBuild")
            }
        }
    }

    private func applyGraphModel(_ model: GraphModel) {
        viewState.graphModel = model
        viewState.graphNote = model.droppedNodesCount > 0 ? "Showing top \(maxNodes) nodes" : nil
        updateNetworkHealth()
    }

    private func updateNetworkHealth() {
        let health = NetworkHealthCalculator.calculate(
            graphModel: viewState.graphModel,
            packets: packets
        )
        viewState.networkHealth = health
    }

    /// Returns the ID of the primary hub (highest degree node) if available
    func primaryHubNodeID() -> String? {
        viewState.networkHealth.metrics.topRelayCallsign.flatMap { callsign in
            viewState.graphModel.nodes.first { $0.callsign == callsign }?.id
        }
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
            return
        }

        let positions = RadialGraphLayout.layout(model: model, myCallsign: myCallsignForLayout)
        layoutKey = key
        layoutCache[key] = positions
        viewState.nodePositions = positions
        viewState.layoutEnergy = 0
        reconcileSelectionAfterLayout()
    }

    private func updateSelectionState() {
        viewState.selectedNodeIDs = selectionState.selectedIDs
        selectionState.normalizePrimary()
        viewState.selectedNodeID = selectionState.primarySelectionID
        captureMissingSelectionIfNeeded()
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
        loopDetection.reset()
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
    let packetCount: Int
    let lastTimestamp: Date?
    let customStart: Date
    let customEnd: Date
}

struct GraphInspectorDetails: Hashable, Sendable {
    let node: NetworkGraphNode
    let neighbors: [GraphNeighborStat]
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
