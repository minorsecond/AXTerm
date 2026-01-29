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
    @ObservedObject var settings: AppSettingsStore
    @StateObject private var viewModel: AnalyticsDashboardViewModel
    @State private var graphResetToken = UUID()
    @State private var focusNodeID: String?

    init(packetEngine: PacketEngine, settings: AppSettingsStore, viewModel: AnalyticsDashboardViewModel) {
        self.packetEngine = packetEngine
        self.settings = settings
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
            viewModel.setActive(true)
            viewModel.updatePackets(packetEngine.packets)
        }
        .onDisappear {
            viewModel.setActive(false)
        }
        .onReceive(packetEngine.$packets) { packets in
            viewModel.updatePackets(packets)
        }
        .onChange(of: viewModel.viewState.selectedNodeID) { _, newValue in
            packetEngine.selectedStationCall = newValue
        }
    }

    private var filterSection: some View {
        AnalyticsCard {
            VStack(alignment: .leading, spacing: AnalyticsStyle.Layout.cardSpacing) {
                HStack(alignment: .center, spacing: AnalyticsStyle.Layout.cardSpacing) {
                    FilterControlGroup(title: "Timeframe") {
                        Picker("Timeframe", selection: $viewModel.timeframe) {
                            ForEach(AnalyticsTimeframe.allCases, id: \.self) { timeframe in
                                Text(timeframe.displayName)
                                    .lineLimit(1)
                                    .tag(timeframe)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .controlSize(.small)
                    }

                    FilterControlGroup(title: "Bucket") {
                        Picker("Bucket", selection: $viewModel.bucketSelection) {
                            ForEach(AnalyticsBucketSelection.allCases, id: \.self) { bucket in
                                Text(bucket.displayName)
                                    .lineLimit(1)
                                    .tag(bucket)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .controlSize(.small)
                    }

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

                if viewModel.timeframe == .custom {
                    HStack(spacing: 12) {
                        DatePicker("Start", selection: $viewModel.customRangeStart, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                        DatePicker("End", selection: $viewModel.customRangeEnd, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.compact)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var summarySection: some View {
        AnalyticsCard(title: "Summary") {
            if let summary = viewModel.viewState.summary {
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
                    TimeSeriesChart(points: viewModel.viewState.series.packetsPerBucket, valueLabel: "Packets", bucket: viewModel.resolvedBucket)
                        .background(ChartWidthReader { width in
                            viewModel.updateChartWidth(width)
                        })
                }

                ChartCard(title: "Bytes over time") {
                    TimeSeriesChart(points: viewModel.viewState.series.bytesPerBucket, valueLabel: "Bytes", bucket: viewModel.resolvedBucket)
                }

                ChartCard(title: "Unique stations over time") {
                    TimeSeriesChart(points: viewModel.viewState.series.uniqueStationsPerBucket, valueLabel: "Stations", bucket: viewModel.resolvedBucket)
                }

                ChartCard(title: "Traffic intensity (hour vs day)", height: AnalyticsStyle.Layout.heatmapHeight) {
                    HeatmapView(data: viewModel.viewState.heatmap)
                }

                ChartCard(title: "Payload size distribution") {
                    HistogramChart(data: viewModel.viewState.histogram)
                }

                ChartCard(title: "Top talkers") {
                    TopListView(rows: viewModel.viewState.topTalkers)
                }

                ChartCard(title: "Top destinations") {
                    TopListView(rows: viewModel.viewState.topDestinations)
                }

                ChartCard(title: "Top digipeaters") {
                    TopListView(rows: viewModel.viewState.topDigipeaters)
                }
            }
        }
    }

    private var graphSection: some View {
        AnalyticsCard(title: "Network graph") {
            HStack(alignment: .top, spacing: AnalyticsStyle.Layout.cardSpacing) {
                AnalyticsGraphView(
                    graphModel: viewModel.viewState.graphModel,
                    nodePositions: viewModel.viewState.nodePositions,
                    selectedNodeIDs: viewModel.viewState.selectedNodeIDs,
                    hoveredNodeID: viewModel.viewState.hoveredNodeID,
                    myCallsign: settings.myCallsign,
                    resetToken: graphResetToken,
                    focusNodeID: focusNodeID,
                    onSelect: { nodeID, isShift in
                        viewModel.handleNodeClick(nodeID, isShift: isShift)
                    },
                    onSelectMany: { nodeIDs, isShift in
                        viewModel.handleSelectionRect(nodeIDs, isShift: isShift)
                    },
                    onClearSelection: {
                        viewModel.handleBackgroundClick()
                    },
                    onHover: { nodeID in
                        viewModel.updateHover(for: nodeID)
                    },
                    onFocusHandled: {
                        focusNodeID = nil
                    }
                )
                .frame(minHeight: AnalyticsStyle.Layout.graphHeight)

                GraphInspectorView(details: viewModel.selectedNodeDetails()) {
                    viewModel.handleBackgroundClick()
                } onFocus: {
                    focusNodeID = viewModel.viewState.selectedNodeID
                }
                .frame(width: AnalyticsStyle.Layout.inspectorWidth)
            }

            if let note = viewModel.viewState.graphNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    .padding(.top, 4)
            }

            Text("Click to select, Shift-click to toggle, Shift-drag to select, drag to pan, pinch to zoom, ⌘-scroll to zoom, Esc clears")
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

private struct TimeSeriesChart: View {
    let points: [AnalyticsSeriesPoint]
    let valueLabel: String
    let bucket: TimeBucket
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
                AxisMarks(values: .stride(by: bucket.axisStride.component, count: bucket.axisStride.count)) { _ in
                    AxisGridLine()
                        .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                    AxisValueLabel()
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: AnalyticsStyle.Chart.axisLabelCount)) { _ in
                    AxisGridLine()
                        .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                    AxisValueLabel()
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                }
            }
            .chartPlotStyle { plotArea in
                plotArea.background(AnalyticsStyle.Colors.chartPlotBackground)
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
            .padding(.horizontal, 4)
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
                AxisMarks(values: .automatic(desiredCount: AnalyticsStyle.Histogram.maxLabelCount)) { _ in
                    AxisGridLine()
                        .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                    AxisValueLabel()
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: AnalyticsStyle.Chart.axisLabelCount)) { _ in
                    AxisGridLine()
                        .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                    AxisValueLabel()
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                }
            }
            .chartPlotStyle { plotArea in
                plotArea.background(AnalyticsStyle.Colors.chartPlotBackground)
            }
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                if let label: String = proxy.value(atX: location.x) {
                                    let bin = data.bins.first(where: { $0.label == label })
                                    selectedBin = bin
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
            .padding(.horizontal, 4)
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

private struct FilterControlGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            content
        }
    }
}

private struct ChartWidthReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    onChange(proxy.size.width)
                }
                .onChange(of: proxy.size.width) { _, newValue in
                    onChange(newValue)
                }
        }
    }
}
