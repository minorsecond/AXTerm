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
            recomputeSeries(packets: packets)
        }
    }
    @Published var includeViaDigipeaters: Bool {
        didSet {
            guard includeViaDigipeaters != oldValue else { return }
            trackFilterChange(reason: "includeVia")
            recomputeAll(packets: packets)
        }
    }
    @Published var minEdgeCount: Int {
        didSet {
            guard minEdgeCount != oldValue else { return }
            trackFilterChange(reason: "minEdgeCount")
            recomputeEdges(packets: packets)
        }
    }

    @Published private(set) var summary: AnalyticsSummary?
    @Published private(set) var series: AnalyticsSeries = .empty
    @Published private(set) var edges: [GraphEdge] = []
    @Published private(set) var nodePositions: [NodePosition] = []

    @Published var selectedNodeID: String?
    @Published var hoveredNodeID: String?
    @Published var pinnedNodeID: String?

    private let calendar: Calendar
    private let packetSubject = CurrentValueSubject<[Packet], Never>([])
    private var cancellables: Set<AnyCancellable> = []
    private var packets: [Packet] = []
    private var graphLayoutSize: CGSize = .zero
    private var graphLayoutSeed: Int = 1
    private let packetDebounce: RunLoop.SchedulerTimeType.Stride
    private let packetScheduler: RunLoop

    init(
        calendar: Calendar = .current,
        bucket: TimeBucket = .fiveMinutes,
        includeViaDigipeaters: Bool = false,
        minEdgeCount: Int = 1,
        packetDebounce: RunLoop.SchedulerTimeType.Stride = .milliseconds(150),
        packetScheduler: RunLoop = .main
    ) {
        self.calendar = calendar
        self.bucket = bucket
        self.includeViaDigipeaters = includeViaDigipeaters
        self.minEdgeCount = minEdgeCount
        self.packetDebounce = packetDebounce
        self.packetScheduler = packetScheduler
        bindPackets()
    }

    func updatePackets(_ packets: [Packet]) {
        packetSubject.send(packets)
    }

    func updateLayout(size: CGSize, seed: Int = 1) {
        graphLayoutSize = size
        graphLayoutSeed = seed
        recomputeLayout(reason: "layoutRequested")
    }

    func trackDashboardOpened() {
        Telemetry.breadcrumb(
            category: "analytics.dashboard.opened",
            message: "Analytics dashboard opened",
            data: nil
        )
    }

    func selectNode(_ nodeID: String?) {
        selectedNodeID = nodeID
        guard let nodeID else { return }
        Telemetry.breadcrumb(
            category: "analytics.graph.node.selected",
            message: "Analytics graph node selected",
            data: ["nodeID": nodeID]
        )
    }

    func togglePinnedNode(_ nodeID: String) {
        pinnedNodeID = pinnedNodeID == nodeID ? nil : nodeID
    }

    func updateHover(for nodeID: String, isHovering: Bool) {
        if isHovering {
            hoveredNodeID = nodeID
        } else if hoveredNodeID == nodeID {
            hoveredNodeID = nil
        }
    }

    private func bindPackets() {
        let pipeline = packetSubject
            .removeDuplicates(by: { lhs, rhs in
                lhs.count == rhs.count && lhs.last?.id == rhs.last?.id
            })

        if packetDebounce == .zero {
            pipeline
                .sink { [weak self] packets in
                    self?.packets = packets
                    self?.recomputeAll(packets: packets)
                }
                .store(in: &cancellables)
        } else {
            pipeline
                .debounce(for: packetDebounce, scheduler: packetScheduler)
                .sink { [weak self] packets in
                    self?.packets = packets
                    self?.recomputeAll(packets: packets)
                }
                .store(in: &cancellables)
        }
    }

    private func trackFilterChange(reason: String) {
        Telemetry.breadcrumb(
            category: "analytics.filter.changed",
            message: "Analytics filter changed",
            data: [
                "reason": reason,
                "bucket": bucket.displayName,
                "includeVia": includeViaDigipeaters,
                "minEdgeCount": minEdgeCount
            ]
        )
    }

    private func recomputeAll(packets: [Packet]) {
        recomputeSummary(packets: packets)
        recomputeSeries(packets: packets)
        recomputeEdges(packets: packets)
    }

    private func recomputeSummary(packets: [Packet]) {
        let uniqueStations = AnalyticsEngine.uniqueStationsCount(
            packets: packets,
            includeViaInUniqueStations: includeViaDigipeaters
        )

        let summary = Telemetry.measure(
            name: "analytics.computeSummary",
            data: [
                TelemetryContext.packetCount: packets.count,
                TelemetryContext.uniqueStations: uniqueStations
            ]
        ) {
            AnalyticsEngine.computeSummary(
                packets: packets,
                includeViaInUniqueStations: includeViaDigipeaters
            )
        }
        self.summary = summary

        if summary.infoTextRatio.isNaN || summary.totalPayloadBytes < 0 {
            Telemetry.capture(
                message: "analytics.summary.invalid",
                data: [
                    "infoTextRatio": summary.infoTextRatio,
                    "totalPayloadBytes": summary.totalPayloadBytes
                ]
            )
        }
    }

    private func recomputeSeries(packets: [Packet]) {
        let uniqueStations = AnalyticsEngine.uniqueStationsCount(
            packets: packets,
            includeViaInUniqueStations: includeViaDigipeaters
        )

        let series = Telemetry.measure(
            name: "analytics.computeSeries",
            data: [
                TelemetryContext.packetCount: packets.count,
                TelemetryContext.uniqueStations: uniqueStations,
                TelemetryContext.activeBucket: bucket.displayName
            ]
        ) {
            AnalyticsEngine.computeSeries(
                packets: packets,
                bucket: bucket,
                calendar: calendar,
                includeViaInUniqueStations: includeViaDigipeaters
            )
        }
        self.series = series

        let seriesIssues = validateSeries(series)
        if !seriesIssues.isEmpty {
            Telemetry.capture(
                message: "analytics.series.invalid",
                data: [
                    "issues": seriesIssues,
                    "bucket": bucket.displayName
                ]
            )
        }
    }

    private func recomputeEdges(packets: [Packet]) {
        let uniqueStations = AnalyticsEngine.uniqueStationsCount(
            packets: packets,
            includeViaInUniqueStations: includeViaDigipeaters
        )

        let edges = Telemetry.measureWithResult(
            name: "analytics.computeEdges",
            data: [
                TelemetryContext.packetCount: packets.count,
                TelemetryContext.uniqueStations: uniqueStations,
                "includeVia": includeViaDigipeaters,
                "minCount": minEdgeCount
            ],
            updateData: { result in
                ["edgeCount": result.count]
            }
        ) {
            AnalyticsEngine.computeEdges(
                packets: packets,
                includeViaDigipeaters: includeViaDigipeaters,
                minCount: minEdgeCount
            )
        }
        self.edges = edges

        if edges.contains(where: { $0.source.isEmpty || $0.target.isEmpty || $0.count <= 0 }) {
            Telemetry.capture(
                message: "analytics.edges.invalid",
                data: [
                    "includeVia": includeViaDigipeaters,
                    "minCount": minEdgeCount,
                    "edgeCount": edges.count
                ]
            )
        }

        recomputeLayout(reason: "edgesUpdated")
    }

    private func recomputeLayout(reason: String) {
        let nodes = buildGraphNodes(from: edges)

        let positions = Telemetry.measure(
            name: "analytics.graph.layout",
            data: [
                "nodeCount": nodes.count,
                "edgeCount": edges.count,
                "algorithm": GraphLayoutEngine.algorithmName,
                "iterations": GraphLayoutEngine.iterations,
                "reason": reason
            ]
        ) {
            GraphLayoutEngine.layout(
                nodes: nodes,
                edges: edges,
                size: graphLayoutSize,
                seed: graphLayoutSeed
            )
        }
        nodePositions = positions

        let invalidPositions = positions.filter { !$0.x.isFinite || !$0.y.isFinite }
        if !invalidPositions.isEmpty {
            Telemetry.capture(
                message: "analytics.graph.layout.invalid",
                data: [
                    "nodeCount": nodes.count,
                    "edgeCount": edges.count,
                    "invalidCount": invalidPositions.count
                ]
            )
        }
    }

    private func buildGraphNodes(from edges: [GraphEdge]) -> [GraphNode] {
        struct NodeMetrics {
            var degree: Int = 0
            var count: Int = 0
            var bytes: Int = 0
            var hasBytes: Bool = false
        }

        var metricsById: [String: NodeMetrics] = [:]
        for edge in edges {
            let edgeBytes = edge.bytes

            var sourceMetrics = metricsById[edge.source, default: NodeMetrics()]
            sourceMetrics.degree += 1
            sourceMetrics.count += edge.count
            if let edgeBytes {
                sourceMetrics.bytes += edgeBytes
                sourceMetrics.hasBytes = true
            }
            metricsById[edge.source] = sourceMetrics

            var targetMetrics = metricsById[edge.target, default: NodeMetrics()]
            targetMetrics.degree += 1
            targetMetrics.count += edge.count
            if let edgeBytes {
                targetMetrics.bytes += edgeBytes
                targetMetrics.hasBytes = true
            }
            metricsById[edge.target] = targetMetrics
        }

        return metricsById.map { key, metrics in
            GraphNode(
                id: key,
                degree: metrics.degree,
                count: metrics.count,
                bytes: metrics.hasBytes ? metrics.bytes : nil
            )
        }
    }

    private func validateSeries(_ series: AnalyticsSeries) -> [String] {
        var issues: [String] = []
        issues.append(contentsOf: validate(points: series.packetsPerBucket, label: "packetsPerBucket"))
        issues.append(contentsOf: validate(points: series.bytesPerBucket, label: "bytesPerBucket"))
        issues.append(contentsOf: validate(points: series.uniqueStationsPerBucket, label: "uniqueStationsPerBucket"))
        return issues
    }

    private func validate(points: [AnalyticsSeriesPoint], label: String) -> [String] {
        var issues: [String] = []
        var seen: Set<Date> = []
        var lastBucket: Date?

        for point in points {
            if let lastBucket, point.bucket < lastBucket {
                issues.append("\(label).unsorted")
            }
            if !seen.insert(point.bucket).inserted {
                issues.append("\(label).duplicateBucket")
            }
            lastBucket = point.bucket
        }

        return issues
    }
}
