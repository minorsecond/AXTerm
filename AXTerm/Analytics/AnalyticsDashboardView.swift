//
//  AnalyticsDashboardView.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-21.
//

import AppKit
import Charts
import SwiftUI

struct AnalyticsDashboardView: View {
    @ObservedObject var packetEngine: PacketEngine
    @StateObject private var viewModel: AnalyticsDashboardViewModel
    @State private var graphResetToken = UUID()
    @State private var focusNodeID: String?

    init(packetEngine: PacketEngine, viewModel: AnalyticsDashboardViewModel) {
        self.packetEngine = packetEngine
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyticsStyle.Layout.sectionSpacing) {
                filterSection
                summarySection
                chartsSection
                graphSection
            }
            .padding(AnalyticsStyle.Layout.pagePadding)
        }
        .onAppear {
            viewModel.trackDashboardOpened()
            viewModel.updatePackets(packetEngine.packets)
        }
        .onReceive(packetEngine.$packets) { packets in
            viewModel.updatePackets(packets)
        }
        .onChange(of: viewModel.selectedNodeID) { _, newValue in
            packetEngine.selectedStationCall = newValue
        }
    }

    private var filterSection: some View {
        AnalyticsCard {
            HStack(alignment: .center, spacing: AnalyticsStyle.Layout.cardSpacing) {
                Picker("Bucket", selection: $viewModel.bucket) {
                    ForEach(TimeBucket.allCases, id: \.self) { bucket in
                        Text(bucket.displayName).tag(bucket)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Toggle("Include via digipeaters", isOn: $viewModel.includeViaDigipeaters)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Minimum edge count")
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.minEdgeCount) },
                                set: { viewModel.minEdgeCount = Int($0) }
                            ),
                            in: 1...10,
                            step: 1
                        )
                        Text("\(viewModel.minEdgeCount)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 24, alignment: .trailing)
                    }
                }
                .frame(maxWidth: 220)

                Stepper(value: $viewModel.maxNodes, in: AnalyticsStyle.Graph.minNodes...300, step: 10) {
                    Text("Max nodes: \(viewModel.maxNodes)")
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                }

                Spacer()

                Button("Reset") {
                    graphResetToken = UUID()
                    viewModel.resetGraphView()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var summarySection: some View {
        AnalyticsCard(title: "Summary") {
            if let summary = viewModel.summary {
                LazyVGrid(columns: metricColumns, spacing: AnalyticsStyle.Layout.cardSpacing) {
                    SummaryMetricCard(title: "Total packets", value: summary.totalPackets.formatted())
                    SummaryMetricCard(title: "Unique stations", value: summary.uniqueStations.formatted())
                    SummaryMetricCard(title: "Payload bytes", value: ByteCountFormatter.string(fromByteCount: Int64(summary.totalPayloadBytes), countStyle: .file))
                    SummaryMetricCard(title: "UI frames", value: summary.uiFrames.formatted())
                    SummaryMetricCard(title: "I frames", value: summary.iFrames.formatted())
                    SummaryMetricCard(title: "Info-text ratio", value: String(format: "%.0f%%", summary.infoTextRatio * 100))
                }
            } else {
                Text("No packets yet")
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    .padding(.vertical, 6)
            }
        }
    }

    private var chartsSection: some View {
        AnalyticsCard(title: "Charts") {
            LazyVGrid(columns: chartColumns, spacing: AnalyticsStyle.Layout.cardSpacing) {
                ChartCard(title: "Packets over time") {
                    TimeSeriesChart(points: viewModel.series.packetsPerBucket, valueLabel: "Packets")
                }

                ChartCard(title: "Bytes over time") {
                    TimeSeriesChart(points: viewModel.series.bytesPerBucket, valueLabel: "Bytes")
                }

                ChartCard(title: "Unique stations over time") {
                    TimeSeriesChart(points: viewModel.series.uniqueStationsPerBucket, valueLabel: "Stations")
                }

                ChartCard(title: "Traffic intensity (hour vs day)", height: AnalyticsStyle.Layout.heatmapHeight) {
                    HeatmapView(data: viewModel.heatmap)
                }

                ChartCard(title: "Payload size distribution") {
                    HistogramChart(data: viewModel.histogram)
                }

                ChartCard(title: "Top talkers") {
                    TopListView(rows: viewModel.topTalkers)
                }

                ChartCard(title: "Top destinations") {
                    TopListView(rows: viewModel.topDestinations)
                }

                ChartCard(title: "Top digipeaters") {
                    TopListView(rows: viewModel.topDigipeaters)
                }
            }
        }
    }

    private var graphSection: some View {
        AnalyticsCard(title: "Network graph") {
            HStack(alignment: .top, spacing: AnalyticsStyle.Layout.cardSpacing) {
                AnalyticsGraphView(
                    graphModel: viewModel.graphModel,
                    nodePositions: viewModel.nodePositions,
                    selectedNodeIDs: viewModel.selectedNodeIDs,
                    hoveredNodeID: viewModel.hoveredNodeID,
                    resetToken: graphResetToken,
                    focusNodeID: focusNodeID,
                    onSelect: { nodeID, isShift in
                        viewModel.handleNodeClick(nodeID, isShift: isShift)
                    },
                    onClearSelection: {
                        viewModel.handleBackgroundClick()
                    },
                    onHover: { nodeID in
                        DispatchQueue.main.async {
                            viewModel.updateHover(for: nodeID)
                        }
                    },
                    onFocusHandled: {
                        focusNodeID = nil
                    }
                )
                .frame(minHeight: AnalyticsStyle.Layout.graphHeight)

                GraphInspectorView(details: viewModel.selectedNodeDetails()) {
                    viewModel.handleBackgroundClick()
                } onFocus: {
                    focusNodeID = viewModel.selectedNodeID
                }
                .frame(width: AnalyticsStyle.Layout.inspectorWidth)
            }

            if let note = viewModel.graphNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    .padding(.top, 4)
            }

            Text("Click to select, shift-click to add, scroll to zoom, drag to pan, Esc clears")
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .padding(.top, 4)
        }
    }

    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: AnalyticsStyle.Layout.cardSpacing), count: AnalyticsStyle.Layout.metricColumns)
    }

    private var chartColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: AnalyticsStyle.Layout.cardSpacing), count: AnalyticsStyle.Layout.chartColumns)
    }
}

private struct AnalyticsCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AnalyticsStyle.Layout.cardSpacing) {
            if let title {
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            content
        }
        .padding(AnalyticsStyle.Layout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius)
                .fill(AnalyticsStyle.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius)
                .stroke(AnalyticsStyle.Colors.cardStroke, lineWidth: 1)
        )
    }
}

private struct SummaryMetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
    }
}

private struct ChartCard<Content: View>: View {
    let title: String
    let height: CGFloat
    @ViewBuilder var content: Content

    init(title: String, height: CGFloat = AnalyticsStyle.Layout.chartHeight, @ViewBuilder content: () -> Content) {
        self.title = title
        self.height = height
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
                .frame(height: height)
        }
        .padding(12)
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
    }
}

private struct TimeSeriesChart: View {
    let points: [AnalyticsSeriesPoint]
    let valueLabel: String
    @State private var selectedPoint: AnalyticsSeriesPoint?

    var body: some View {
        if points.isEmpty {
            EmptyChartPlaceholder(text: "No data")
        } else {
                Chart {
                ForEach(points, id: \.bucket) { point in
                    if #available(macOS 13.0, *) {
                        LineMark(
                            x: .value("Time", point.bucket),
                            y: .value(valueLabel, point.value)
                        )
                        .interpolationMethod(AnalyticsStyle.Chart.smoothLines ? .catmullRom : .linear)
                        .foregroundStyle(AnalyticsStyle.Colors.accent)
                    } else {
                        LineMark(
                            x: .value("Time", point.bucket),
                            y: .value(valueLabel, point.value)
                        )
                        .foregroundStyle(AnalyticsStyle.Colors.accent)
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: AnalyticsStyle.Chart.axisLabelCount))
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: AnalyticsStyle.Chart.axisLabelCount))
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onHover { isHovering in
                            if !isHovering {
                                selectedPoint = nil
                            }
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                if let date: Date = proxy.value(atX: location.x) {
                                    let closest = points.min { lhs, rhs in
                                        abs(lhs.bucket.timeIntervalSince(date)) < abs(rhs.bucket.timeIntervalSince(date))
                                    }
                                    selectedPoint = closest
                                }
                            case .ended:
                                selectedPoint = nil
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let selectedPoint {
                                ChartTooltip(text: "\(valueLabel): \(selectedPoint.value)")
                                    .offset(x: 6, y: 6)
                            }
                        }
                }
            }
        }
    }
}

private struct HistogramChart: View {
    let data: HistogramData
    @State private var selectedBin: HistogramBin?

    var body: some View {
        if data.bins.isEmpty {
            EmptyChartPlaceholder(text: "No data")
        } else {
            Chart {
                ForEach(data.bins, id: \.lowerBound) { bin in
                    BarMark(
                        x: .value("Payload", bin.label),
                        y: .value("Count", bin.count)
                    )
                    .foregroundStyle(AnalyticsStyle.Colors.accent)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: AnalyticsStyle.Histogram.maxLabelCount))
            }
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                if let label: String = proxy.value(atX: location.x) {
                                    selectedBin = data.bins.first(where: { $0.label == label })
                                }
                            case .ended:
                                selectedBin = nil
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let selectedBin {
                                ChartTooltip(text: "Count: \(selectedBin.count)")
                                    .offset(x: 6, y: 6)
                            }
                        }
                }
            }
        }
    }
}

private struct TopListView: View {
    let rows: [RankRow]

    var body: some View {
        if rows.isEmpty {
            EmptyChartPlaceholder(text: "No data")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    HStack {
                        Text(row.label)
                        Spacer()
                        Text("\(row.count)")
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

private struct HeatmapView: View {
    let data: HeatmapData

    var body: some View {
        if data.matrix.isEmpty {
            EmptyChartPlaceholder(text: "No data")
        } else {
            GeometryReader { proxy in
                Canvas { context, size in
                    let rows = data.matrix.count
                    let cols = data.matrix.first?.count ?? 0
                    guard rows > 0, cols > 0 else { return }

                    let labelWidth = AnalyticsStyle.Heatmap.labelWidth
                    let labelHeight = AnalyticsStyle.Heatmap.labelHeight
                    let gridWidth = Swift.max(1, size.width - labelWidth)
                    let gridHeight = Swift.max(1, size.height - labelHeight)
                    let cellWidth = gridWidth / CGFloat(cols)
                    let cellHeight = gridHeight / CGFloat(rows)
                    let maxValue = Swift.max(1, data.matrix.flatMap { $0 }.max() ?? 1)

                    for row in 0..<rows {
                        for col in 0..<cols {
                            let value = data.matrix[row][col]
                            let alpha = AnalyticsStyle.Heatmap.minAlpha + (AnalyticsStyle.Heatmap.maxAlpha - AnalyticsStyle.Heatmap.minAlpha) * (Double(value) / Double(maxValue))
                            let rect = CGRect(
                                x: labelWidth + CGFloat(col) * cellWidth,
                                y: CGFloat(row) * cellHeight,
                                width: cellWidth,
                                height: cellHeight
                            )
                            let path = Path(roundedRect: rect, cornerRadius: AnalyticsStyle.Heatmap.cellCornerRadius)
                            context.fill(path, with: .color(AnalyticsStyle.Colors.accent.opacity(alpha)))
                        }
                    }

                    let xStride = Swift.max(1, cols / AnalyticsStyle.Heatmap.labelStride)
                    for col in stride(from: 0, to: cols, by: xStride) {
                        let text = Text(data.xLabels[col])
                            .font(.system(size: 9))
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                        let position = CGPoint(
                            x: labelWidth + CGFloat(col) * cellWidth + AnalyticsStyle.Heatmap.labelPadding,
                            y: gridHeight + AnalyticsStyle.Heatmap.labelPadding
                        )
                        context.draw(text, at: position, anchor: .topLeading)
                    }

                    let yStride = Swift.max(1, rows / AnalyticsStyle.Heatmap.labelStride)
                    for row in stride(from: 0, to: rows, by: yStride) {
                        let text = Text(data.yLabels[row])
                            .font(.system(size: 9))
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                        let position = CGPoint(
                            x: AnalyticsStyle.Heatmap.labelPadding,
                            y: CGFloat(row) * cellHeight + AnalyticsStyle.Heatmap.labelPadding
                        )
                        context.draw(text, at: position, anchor: .topLeading)
                    }
                }
            }
        }
    }
}

private struct EmptyChartPlaceholder: View {
    let text: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius)
                .strokeBorder(AnalyticsStyle.Colors.cardStroke, lineWidth: 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
    }
}

private struct ChartTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(radius: 2)
            )
    }
}

private struct GraphTooltipView: View {
    let node: NetworkGraphNode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.callsign)
                .font(.caption.weight(.semibold))
            Text("Packets: \(node.weight)")
                .font(.caption2)
            Text("Bytes: \((node.inBytes + node.outBytes).formatted())")
                .font(.caption2)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 2)
        )
    }
}

private struct AnalyticsGraphView: View {
    let graphModel: GraphModel
    let nodePositions: [NodePosition]
    let selectedNodeIDs: Set<String>
    let hoveredNodeID: String?
    let resetToken: UUID
    let focusNodeID: String?
    let onSelect: (String, Bool) -> Void
    let onClearSelection: () -> Void
    let onHover: (String?) -> Void
    let onFocusHandled: () -> Void

    @State private var viewport = GraphViewport()

    var body: some View {
        GeometryReader { proxy in
            let render = GraphRenderData(model: graphModel, positions: nodePositions)
            let map = render.positionMap(size: proxy.size, viewport: viewport)
            ZStack {
                Canvas { context, size in
                    let selection = selectedNodeIDs

                    for edge in graphModel.edges {
                        guard let source = map[edge.sourceID], let target = map[edge.targetID] else { continue }
                        let isRelated = selection.isEmpty || selection.contains(edge.sourceID) || selection.contains(edge.targetID)
                        var path = Path()
                        path.move(to: source)
                        path.addLine(to: target)
                        let thickness = render.edgeThickness(for: edge.weight)
                        let alpha = render.edgeAlpha(for: edge.weight) * (isRelated ? 1.0 : 0.2)
                        context.stroke(path, with: .color(AnalyticsStyle.Colors.graphEdge.opacity(alpha)), lineWidth: thickness)
                    }

                    for node in graphModel.nodes {
                        guard let position = map[node.id] else { continue }
                        let radius = render.nodeRadius(for: node.weight)
                        let isSelected = selectedNodeIDs.contains(node.id)
                        let isHovered = hoveredNodeID == node.id
                        let fill = isSelected ? AnalyticsStyle.Colors.accent : (isHovered ? AnalyticsStyle.Colors.graphNode : AnalyticsStyle.Colors.graphNodeMuted)
                        let rect = CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(fill))
                        if isSelected {
                            context.stroke(
                                Path(ellipseIn: rect.insetBy(dx: -AnalyticsStyle.Graph.selectionGlowWidth / 2, dy: -AnalyticsStyle.Graph.selectionGlowWidth / 2)),
                                with: .color(AnalyticsStyle.Colors.accent.opacity(0.6)),
                                lineWidth: AnalyticsStyle.Graph.selectionGlowWidth
                            )
                        }
                    }
                }

                if let hoveredNodeID = hoveredNodeID,
                   let node = graphModel.nodes.first(where: { $0.id == hoveredNodeID }),
                   let position = map[hoveredNodeID] {
                    GraphTooltipView(node: node)
                        .position(x: position.x + 12, y: position.y - 12)
                }

                GraphInteractionView(
                    onHover: { location in
                        onHover(hitTestNode(at: location, in: proxy.size)?.0)
                    },
                    onClick: { location, isShift, clickCount in
                        if let (nodeID, _) = hitTestNode(at: location, in: proxy.size) {
                            onSelect(nodeID, isShift)
                        } else {
                            if clickCount >= 2 {
                                viewport = GraphViewport()
                            }
                            onClearSelection()
                        }
                    },
                    onDrag: { delta in
                        viewport.offset.width += delta.width
                        viewport.offset.height += delta.height
                    },
                    onScroll: { delta, location in
                        let scaleDelta = Swift.max(0.8, Swift.min(1.2, 1 - delta * 0.01))
                        let newScale = (viewport.scale * scaleDelta).clamped(to: AnalyticsStyle.Graph.zoomRange)
                        viewport.zoom(at: location, size: proxy.size, newScale: newScale)
                    }
                )
            }
            .background(AnalyticsStyle.Colors.neutralFill)
            .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
            .focusable()
            .onExitCommand {
                onClearSelection()
            }
            .onChange(of: resetToken) { _, _ in
                viewport = GraphViewport()
            }
            .onChange(of: focusNodeID) { _, newValue in
                guard let newValue = newValue, nodePositions.contains(where: { $0.id == newValue }) else { return }
                viewport.scale = AnalyticsStyle.Graph.focusScale
                let map = GraphRenderData(model: graphModel, positions: nodePositions).positionMap(size: proxy.size, viewport: GraphViewport())
                if let focused = map[newValue] {
                    let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    viewport.offset = CGSize(width: center.x - focused.x, height: center.y - focused.y)
                }
                DispatchQueue.main.async {
                    onFocusHandled()
                }
            }
        }
    }

    private func hitTestNode(at location: CGPoint?, in size: CGSize) -> (String, CGFloat)? {
        guard let location else { return nil }
        let render = GraphRenderData(model: graphModel, positions: nodePositions)
        let map = render.positionMap(size: size, viewport: viewport)
        var closest: (String, CGFloat)?
        for node in graphModel.nodes {
            guard let position = map[node.id] else { continue }
            let distance = hypot(position.x - location.x, position.y - location.y)
            if distance <= AnalyticsStyle.Graph.nodeHitRadius {
                if let existing = closest {
                    if distance < existing.1 {
                        closest = (node.id, distance)
                    }
                } else {
                    closest = (node.id, distance)
                }
            }
        }
        return closest
    }
}

private struct GraphInspectorView: View {
    let details: GraphInspectorDetails?
    let onClear: () -> Void
    let onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector")
                .font(.headline)

            if let details {
                VStack(alignment: .leading, spacing: 8) {
                    Text(details.node.callsign)
                        .font(.title3.weight(.semibold))

                    MetricRow(title: "Packets in", value: details.node.inCount)
                    MetricRow(title: "Packets out", value: details.node.outCount)
                    MetricRow(title: "Bytes in", value: details.node.inBytes)
                    MetricRow(title: "Bytes out", value: details.node.outBytes)
                    MetricRow(title: "Degree", value: details.node.degree)

                    Divider().padding(.vertical, 4)

                    Text("Top neighbors")
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

                    if details.neighbors.isEmpty {
                        Text("No neighbors")
                            .font(.caption)
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    } else {
                        ForEach(details.neighbors.prefix(5), id: \.id) { neighbor in
                            HStack {
                                Text(neighbor.id)
                                Spacer()
                                Text("\(neighbor.weight)")
                                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            } else {
                Text("Select a node to inspect details.")
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Focus") {
                    onFocus()
                }
                .buttonStyle(.bordered)
                .disabled(details == nil)

                Button("Clear") {
                    onClear()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
    }
}

private struct MetricRow: View {
    let title: String
    let value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted())
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct GraphViewport: Hashable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    mutating func zoom(at location: CGPoint, size: CGSize, newScale: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let translated = CGPoint(x: location.x - center.x - offset.width, y: location.y - center.y - offset.height)
        let scaleRatio = newScale / scale
        offset.width = (offset.width + translated.x) * scaleRatio - translated.x
        offset.height = (offset.height + translated.y) * scaleRatio - translated.y
        scale = newScale
    }
}

private struct GraphRenderData {
    let model: GraphModel
    let positions: [NodePosition]
    private let minNodeWeight: Int
    private let maxNodeWeight: Int
    private let maxEdgeWeight: Int

    init(model: GraphModel, positions: [NodePosition]) {
        self.model = model
        self.positions = positions
        let nodeWeights = model.nodes.map { $0.weight }
        self.minNodeWeight = Swift.max(1, nodeWeights.min() ?? 1)
        self.maxNodeWeight = Swift.max(minNodeWeight, nodeWeights.max() ?? minNodeWeight)
        self.maxEdgeWeight = Swift.max(1, model.edges.map { $0.weight }.max() ?? 1)
    }

    func positionMap(size: CGSize, viewport: GraphViewport) -> [String: CGPoint] {
        let inset = AnalyticsStyle.Layout.graphInset
        let width = Swift.max(1, size.width - inset * 2)
        let height = Swift.max(1, size.height - inset * 2)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        var map: [String: CGPoint] = [:]
        for position in positions {
            let base = CGPoint(
                x: inset + CGFloat(position.x) * width,
                y: inset + CGFloat(position.y) * height
            )
            let scaled = CGPoint(
                x: (base.x - center.x) * viewport.scale + center.x + viewport.offset.width,
                y: (base.y - center.y) * viewport.scale + center.y + viewport.offset.height
            )
            map[position.id] = scaled
        }
        return map
    }

    func nodeRadius(for weight: Int) -> CGFloat {
        let logMin = log(Double(minNodeWeight))
        let logMax = log(Double(maxNodeWeight))
        let logValue = log(Double(Swift.max(weight, 1)))
        let t = logMax == logMin ? 0.5 : (logValue - logMin) / (logMax - logMin)
        let range = AnalyticsStyle.Graph.nodeRadiusRange
        return range.lowerBound + CGFloat(t) * (range.upperBound - range.lowerBound)
    }

    func edgeThickness(for weight: Int) -> CGFloat {
        let t = CGFloat(weight) / CGFloat(maxEdgeWeight)
        let range = AnalyticsStyle.Graph.edgeThicknessRange
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }

    func edgeAlpha(for weight: Int) -> Double {
        let t = Double(weight) / Double(maxEdgeWeight)
        let range = AnalyticsStyle.Graph.edgeAlphaRange
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }
}

private struct GraphInteractionView: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint, Bool, Int) -> Void
    let onDrag: (CGSize) -> Void
    let onScroll: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> GraphInteractionNSView {
        let view = GraphInteractionNSView()
        view.onHover = onHover
        view.onClick = onClick
        view.onDrag = onDrag
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: GraphInteractionNSView, context: Context) {
        nsView.onHover = onHover
        nsView.onClick = onClick
        nsView.onDrag = onDrag
        nsView.onScroll = onScroll
    }
}

private final class GraphInteractionNSView: NSView {
    var onHover: ((CGPoint?) -> Void)?
    var onClick: ((CGPoint, Bool, Int) -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onScroll: ((CGFloat, CGPoint) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var lastDragLocation: CGPoint?
    private var accumulatedDrag: CGSize = .zero

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onHover?(location)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = convert(event.locationInWindow, from: nil)
        accumulatedDrag = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let last = lastDragLocation else { return }
        let delta = CGSize(width: location.x - last.x, height: location.y - last.y)
        accumulatedDrag.width += delta.width
        accumulatedDrag.height += delta.height
        lastDragLocation = location
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let isClick = hypot(accumulatedDrag.width, accumulatedDrag.height) < 3
        if isClick {
            onClick?(location, event.modifierFlags.contains(.shift), event.clickCount)
        }
        lastDragLocation = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onScroll?(event.scrollingDeltaY, location)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
