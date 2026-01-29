//
//  AnalyticsDashboardViewModel.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-21.
//

import Combine
import CoreGraphics
import Foundation

@MainActor
final class AnalyticsDashboardViewModel: ObservableObject {
    @Published var bucket: TimeBucket {
        didSet {
            guard bucket != oldValue else { return }
            trackFilterChange(reason: "bucket")
            scheduleAggregation(reason: "bucket")
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
            guard minEdgeCount != oldValue else { return }
            trackFilterChange(reason: "minEdgeCount")
            scheduleGraphBuild(reason: "minEdgeCount")
        }
    }
    @Published var maxNodes: Int {
        didSet {
            guard maxNodes != oldValue else { return }
            trackFilterChange(reason: "maxNodes")
            scheduleGraphBuild(reason: "maxNodes")
        }
    }

    @Published private(set) var summary: AnalyticsSummaryMetrics?
    @Published private(set) var series: AnalyticsSeries = .empty
    @Published private(set) var heatmap: HeatmapData = .empty
    @Published private(set) var histogram: HistogramData = .empty
    @Published private(set) var topTalkers: [RankRow] = []
    @Published private(set) var topDestinations: [RankRow] = []
    @Published private(set) var topDigipeaters: [RankRow] = []
    @Published private(set) var graphModel: GraphModel = .empty
    @Published private(set) var nodePositions: [NodePosition] = []
    @Published private(set) var layoutEnergy: Double = 0
    @Published private(set) var graphNote: String?

    @Published private(set) var selectedNodeID: String?
    @Published private(set) var selectedNodeIDs: Set<String> = []
    @Published var hoveredNodeID: String?

    private let calendar: Calendar
    private let packetSubject = CurrentValueSubject<[Packet], Never>([])
    private var cancellables: Set<AnyCancellable> = []
    private var packets: [Packet] = []
    private var graphLayoutSeed: Int = 1
    private var selectionState = GraphSelectionState()
    private let aggregationDebouncer: Debouncer
    private let graphDebouncer: Debouncer
    private var layoutState: ForceLayoutState?
    private var layoutTicker: AnyCancellable?
    private var layoutTickCount: Int = 0
    private var aggregationCache: [AggregationCacheKey: AnalyticsAggregationResult] = [:]
    private var graphCache: [GraphCacheKey: GraphModel] = [:]

    init(
        calendar: Calendar = .current,
        bucket: TimeBucket = .fiveMinutes,
        includeViaDigipeaters: Bool = false,
        minEdgeCount: Int = 1,
        maxNodes: Int? = nil,
        packetDebounce: TimeInterval = 0.25,
        graphDebounce: TimeInterval = 0.4,
        packetScheduler: RunLoop = .main
    ) {
        self.calendar = calendar
        self.bucket = bucket
        self.includeViaDigipeaters = includeViaDigipeaters
        self.minEdgeCount = minEdgeCount
        self.maxNodes = maxNodes ?? AnalyticsStyle.Graph.maxNodesDefault
        self.aggregationDebouncer = Debouncer(delay: packetDebounce)
        self.graphDebouncer = Debouncer(delay: graphDebounce)
        bindPackets(packetScheduler: packetScheduler)
    }

    func updatePackets(_ packets: [Packet]) {
        packetSubject.send(packets)
    }

    func resetGraphView() {
        graphLayoutSeed += 1
        prepareLayout(reason: "graphReset")
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

        if let node = graphModel.nodes.first(where: { $0.id == nodeID }) {
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

    func handleBackgroundClick() {
        _ = GraphSelectionReducer.reduce(state: &selectionState, action: .clickBackground)
        updateSelectionState()
    }

    func updateHover(for nodeID: String?) {
        hoveredNodeID = nodeID
    }

    func handleEscape() {
        handleBackgroundClick()
    }

    func selectedNodeDetails() -> GraphInspectorDetails? {
        guard let selectedNodeID = selectedNodeID,
              let node = graphModel.nodes.first(where: { $0.id == selectedNodeID }) else {
            return nil
        }
        let neighbors = graphModel.adjacency[selectedNodeID] ?? []
        return GraphInspectorDetails(node: node, neighbors: neighbors)
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
                "bucket": bucket.displayName,
                "includeVia": includeViaDigipeaters,
                "minEdgeCount": minEdgeCount,
                "maxNodes": maxNodes
            ]
        )
    }

    private func scheduleAggregation(reason: String) {
        aggregationDebouncer.schedule { [weak self] in
            self?.recomputeAggregation(reason: reason)
        }
    }

    private func scheduleGraphBuild(reason: String) {
        graphDebouncer.schedule { [weak self] in
            self?.rebuildGraph(reason: reason)
        }
    }

    private func recomputeAggregation(reason: String) {
        let key = AggregationCacheKey(
            bucket: bucket,
            includeVia: includeViaDigipeaters,
            packetCount: packets.count,
            lastTimestamp: packets.map { $0.timestamp }.max()
        )

        if let cached = aggregationCache[key] {
            applyAggregationResult(cached)
            return
        }

        Telemetry.breadcrumb(
            category: "analytics.recompute.start",
            message: "Analytics recompute started",
            data: [
                TelemetryContext.packetCount: packets.count,
                "bucket": bucket.displayName,
                "includeVia": includeViaDigipeaters,
                "reason": reason
            ]
        )

        let start = Date()
        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: bucket,
            calendar: calendar,
            options: AnalyticsAggregator.Options(
                includeViaDigipeaters: includeViaDigipeaters,
                histogramBinCount: AnalyticsStyle.Histogram.binCount,
                topLimit: AnalyticsStyle.Tables.topLimit
            )
        )
        aggregationCache[key] = result
        applyAggregationResult(result)

        let duration = Date().timeIntervalSince(start) * 1000
        Telemetry.breadcrumb(
            category: "analytics.recompute.end",
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

    private func applyAggregationResult(_ result: AnalyticsAggregationResult) {
        summary = result.summary
        series = result.series
        heatmap = result.heatmap
        histogram = result.histogram
        topTalkers = result.topTalkers
        topDestinations = result.topDestinations
        topDigipeaters = result.topDigipeaters
    }

    private func rebuildGraph(reason: String) {
        let key = GraphCacheKey(
            includeVia: includeViaDigipeaters,
            minEdgeCount: minEdgeCount,
            maxNodes: maxNodes,
            packetCount: packets.count,
            lastTimestamp: packets.map { $0.timestamp }.max()
        )

        if let cached = graphCache[key] {
            graphModel = cached
            graphNote = cached.droppedNodesCount > 0 ? "Showing top \(maxNodes) nodes" : nil
            prepareLayout(reason: "graphCache")
            return
        }

        Telemetry.breadcrumb(
            category: "graph.build.start",
            message: "Graph build started",
            data: [
                TelemetryContext.packetCount: packets.count,
                "includeVia": includeViaDigipeaters,
                "minEdgeCount": minEdgeCount,
                "maxNodes": maxNodes,
                "reason": reason
            ]
        )

        let start = Date()
        let model = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: includeViaDigipeaters,
                minimumEdgeCount: minEdgeCount,
                maxNodes: maxNodes
            )
        )
        graphCache[key] = model
        graphModel = model
        graphNote = model.droppedNodesCount > 0 ? "Showing top \(maxNodes) nodes" : nil

        let duration = Date().timeIntervalSince(start) * 1000
        Telemetry.breadcrumb(
            category: "graph.build.end",
            message: "Graph build finished",
            data: [
                "durationMs": duration,
                "nodeCount": model.nodes.count,
                "edgeCount": model.edges.count
            ]
        )

        if packets.isEmpty == false && model.nodes.isEmpty {
            Telemetry.capture(
                message: "graph.build.empty",
                data: [
                    "packetCount": packets.count,
                    "includeVia": includeViaDigipeaters,
                    "minEdgeCount": minEdgeCount
                ]
            )
        }

        prepareLayout(reason: "graphBuild")
    }

    private func prepareLayout(reason: String) {
        guard !graphModel.nodes.isEmpty else {
            nodePositions = []
            layoutState = nil
            layoutTicker?.cancel()
            layoutTicker = nil
            return
        }

        let previous = layoutState?.positions ?? [:]
        layoutState = ForceLayoutEngine.initialize(nodes: graphModel.nodes, previous: previous, seed: graphLayoutSeed)
        startLayoutTicker(reason: reason)
    }

    private func startLayoutTicker(reason: String) {
        layoutTicker?.cancel()
        layoutTickCount = 0

        layoutTicker = Timer
            .publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tickLayout(reason: reason)
            }
    }

    private func tickLayout(reason: String) {
        guard let state = layoutState else { return }

        let start = Date()
        let updated = ForceLayoutEngine.tick(
            model: graphModel,
            state: state,
            iterations: AnalyticsStyle.Graph.layoutIterationsPerTick,
            repulsion: AnalyticsStyle.Graph.repulsionStrength,
            springStrength: AnalyticsStyle.Graph.springStrength,
            springLength: AnalyticsStyle.Graph.springLength,
            damping: AnalyticsStyle.Graph.layoutCooling,
            timeStep: AnalyticsStyle.Graph.layoutTimeStep
        )

        layoutState = updated
        layoutEnergy = updated.energy

        nodePositions = graphModel.nodes.compactMap { node in
            guard let position = updated.positions[node.id] else { return nil }
            return NodePosition(id: node.id, x: Double(position.x), y: Double(position.y))
        }

        if nodePositions.contains(where: { !$0.x.isFinite || !$0.y.isFinite }) {
            Telemetry.capture(
                message: "graph.layout.invalid",
                data: [
                    "nodeCount": graphModel.nodes.count,
                    "edgeCount": graphModel.edges.count
                ]
            )
        }

        layoutTickCount += 1
        if layoutTickCount.isMultiple(of: 10) {
            let duration = Date().timeIntervalSince(start) * 1000
            Telemetry.breadcrumb(
                category: "layout.tick",
                message: "Layout tick",
                data: [
                    "iterationCount": AnalyticsStyle.Graph.layoutIterationsPerTick,
                    "energy": updated.energy,
                    "durationMs": duration,
                    "reason": reason
                ]
            )
        }

        if updated.energy < AnalyticsStyle.Graph.layoutEnergyThreshold {
            layoutTicker?.cancel()
            layoutTicker = nil
        }

        reconcileSelectionAfterLayout()
    }

    private func updateSelectionState() {
        selectedNodeIDs = selectionState.selectedIDs
        selectionState.normalizePrimary()
        selectedNodeID = selectionState.primarySelectionID
        captureMissingSelectionIfNeeded()
    }

    private func captureMissingSelectionIfNeeded() {
        let availableIDs = Set(graphModel.nodes.map { $0.id })
        let missing = selectedNodeIDs.subtracting(availableIDs)
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
        let availableIDs = Set(graphModel.nodes.map { $0.id })
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
}

private struct AggregationCacheKey: Hashable {
    let bucket: TimeBucket
    let includeVia: Bool
    let packetCount: Int
    let lastTimestamp: Date?
}

private struct GraphCacheKey: Hashable {
    let includeVia: Bool
    let minEdgeCount: Int
    let maxNodes: Int
    let packetCount: Int
    let lastTimestamp: Date?
}

private final class Debouncer {
    private let delay: TimeInterval
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func schedule(_ block: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: block)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

struct GraphInspectorDetails: Hashable, Sendable {
    let node: NetworkGraphNode
    let neighbors: [GraphNeighborStat]
}
