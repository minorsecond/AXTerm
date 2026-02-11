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
    @State private var sidebarTab: GraphSidebarTab = .overview
    @State private var showExportToast = false
    @State private var showCustomRangePopover = false
    @State private var showGraphOptionsPopover = false
    @State private var graphViewportHeight: CGFloat = AnalyticsStyle.Layout.graphHeight
    @State private var preferredPacketViewMode: GraphViewMode = .connectivity
    @State private var preferredNetRomViewMode: GraphViewMode = .netromHybrid

    init(packetEngine: PacketEngine, settings: AppSettingsStore, viewModel: AnalyticsDashboardViewModel) {
        self.packetEngine = packetEngine
        self.settings = settings
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    @State private var scrollOffset: CGFloat = 0
    @State private var controlBarHeight: CGFloat = 56
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .top) {
            // Main scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: AnalyticsStyle.Layout.sectionSpacing) {
                    // Spacer for the floating header
                    Color.clear
                        .frame(height: controlBarHeight + 12)

                    summarySection
                    chartsSection
                    graphSection
                }
                .padding(AnalyticsStyle.Layout.pagePadding)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: geo.frame(in: .named("scroll")).minY
                        )
                    }
                )
            }
            .scrollDisabled(false)
            .defaultScrollAnchor(.top)  // Prevent scroll jumping on layout changes
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                scrollOffset = -value
            }

            // Floating glass control bar
            FloatingControlBar(
                scrollOffset: scrollOffset,
                reduceTransparency: reduceTransparency
            ) {
                filterSection
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: FloatingControlBarHeightPreferenceKey.self, value: geo.size.height)
                }
            )

            // Export toast notification
            if showExportToast {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(GraphCopy.QuickActions.exportSuccessMessage)
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            viewModel.trackDashboardOpened()
            viewModel.updatePackets(packetEngine.packets)
            syncPreferredGraphModes(with: viewModel.graphViewMode)
            Task { @MainActor in
                viewModel.setActive(true)
            }
        }
        .onDisappear {
            viewModel.setActive(false)
        }
        .onReceive(packetEngine.$packets) { packets in
            viewModel.updatePackets(packets)
        }
        .onChange(of: viewModel.viewState.selectedNodeID) { _, newValue in
            packetEngine.selectedStationCall = newValue
            if newValue == nil {
                sidebarTab = .overview
            }
        }
        .onChange(of: viewModel.graphViewMode) { _, newValue in
            syncPreferredGraphModes(with: newValue)
        }
        .onPreferenceChange(FloatingControlBarHeightPreferenceKey.self) { value in
            // Keep height stable and avoid tiny oscillations from fractional layout updates.
            let rounded = ceil(value)
            if abs(controlBarHeight - rounded) > 1 {
                controlBarHeight = rounded
            }
        }
    }

    private var filterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 12) {
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

                if viewModel.timeframe == .custom {
                    Button {
                        showCustomRangePopover.toggle()
                    } label: {
                        Label("Range", systemImage: "calendar")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $showCustomRangePopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            DatePicker("Start", selection: $viewModel.customRangeStart, displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.compact)
                            DatePicker("End", selection: $viewModel.customRangeEnd, displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.compact)
                        }
                        .padding(12)
                        .frame(width: 320)
                    }
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

                Toggle("Auto-update", isOn: $viewModel.autoUpdateEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Automatically refresh analytics as new packets arrive")

                Button {
                    viewModel.manualRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh analytics now")

                Button {
                    showGraphOptionsPopover.toggle()
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showGraphOptionsPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Graph Options")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Min edge count")
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
                                .frame(width: 140)
                                Text("\(viewModel.minEdgeCount)")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 20, alignment: .trailing)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Max nodes")
                                .font(.caption)
                                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                            Stepper(value: $viewModel.maxNodes, in: AnalyticsStyle.Graph.minNodes...300, step: 10) {
                                Text("\(viewModel.maxNodes)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .frame(width: 240)
                }
            }
        }
    }

    private var summarySection: some View {
        AnalyticsCard(title: "Summary") {
            if let summary = viewModel.viewState.summary, viewModel.hasLoadedAggregation {
                LazyVGrid(columns: metricColumns, spacing: AnalyticsStyle.Layout.cardSpacing) {
                    SummaryMetricCard(title: "Total packets", value: summary.totalPackets.formatted())
                    SummaryMetricCard(title: "Unique stations", value: summary.uniqueStations.formatted())
                    SummaryMetricCard(title: "Payload bytes", value: ByteCountFormatter.string(fromByteCount: Int64(summary.totalPayloadBytes), countStyle: .file))
                    SummaryMetricCard(title: "UI frames", value: summary.uiFrames.formatted())
                    SummaryMetricCard(title: "I frames", value: summary.iFrames.formatted())
                    SummaryMetricCard(title: "Info-text ratio", value: String(format: "%.0f%%", summary.infoTextRatio * 100))
                }
            } else {
                LazyVGrid(columns: metricColumns, spacing: AnalyticsStyle.Layout.cardSpacing) {
                    ForEach(0..<6, id: \.self) { _ in
                        SummaryMetricPlaceholderCard()
                    }
                }
            }
        }
    }

    private var chartsSection: some View {
        AnalyticsCard(title: "Charts") {
            LazyVGrid(columns: chartColumns, spacing: AnalyticsStyle.Layout.cardSpacing) {
                ChartCard(title: "Packets over time") {
                    if viewModel.hasLoadedAggregation {
                        TimeSeriesChart(points: viewModel.viewState.series.packetsPerBucket, valueLabel: "Packets", bucket: viewModel.resolvedBucket)
                            .background(ChartWidthReader { width in
                                viewModel.updateChartWidth(width)
                            })
                    } else {
                        ChartLoadingPlaceholder(label: "Loading packets")
                    }
                }

                ChartCard(title: "Bytes over time") {
                    if viewModel.hasLoadedAggregation {
                        TimeSeriesChart(points: viewModel.viewState.series.bytesPerBucket, valueLabel: "Bytes", bucket: viewModel.resolvedBucket)
                    } else {
                        ChartLoadingPlaceholder(label: "Loading bytes")
                    }
                }

                ChartCard(title: "Unique stations over time") {
                    if viewModel.hasLoadedAggregation {
                        TimeSeriesChart(points: viewModel.viewState.series.uniqueStationsPerBucket, valueLabel: "Stations", bucket: viewModel.resolvedBucket)
                    } else {
                        ChartLoadingPlaceholder(label: "Loading stations")
                    }
                }

                ChartCard(title: "Traffic intensity (hour vs day)", height: AnalyticsStyle.Layout.heatmapHeight) {
                    if viewModel.hasLoadedAggregation {
                        HeatmapView(data: viewModel.viewState.heatmap)
                    } else {
                        ChartLoadingPlaceholder(label: "Loading heatmap")
                    }
                }

                ChartCard(title: "Payload size distribution") {
                    if viewModel.hasLoadedAggregation {
                        HistogramChart(data: viewModel.viewState.histogram)
                    } else {
                        ChartLoadingPlaceholder(label: "Loading distribution")
                    }
                }

                ChartCard(title: "Top talkers") {
                    if viewModel.hasLoadedAggregation {
                        TopListView(rows: viewModel.viewState.topTalkers)
                    } else {
                        ChartLoadingPlaceholder(label: "Loading top talkers")
                    }
                }

                ChartCard(title: "Top destinations") {
                    if viewModel.hasLoadedAggregation {
                        TopListView(rows: viewModel.viewState.topDestinations)
                    } else {
                        ChartLoadingPlaceholder(label: "Loading destinations")
                    }
                }

                ChartCard(title: "Top digipeaters") {
                    if viewModel.hasLoadedAggregation {
                        TopListView(rows: viewModel.viewState.topDigipeaters)
                    } else {
                        ChartLoadingPlaceholder(label: "Loading digipeaters")
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if viewModel.isAggregationLoading && viewModel.hasLoadedAggregation {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating charts")
                            .font(.caption)
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 4)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var graphSection: some View {
        AnalyticsCardWithControls(title: "Network Graph") {
            // Right-aligned controls in header
            networkGraphHeaderControls
        } content: {
            VStack(spacing: 8) {
                // Graph toolbar (HIG: single canonical location for view controls)
                GraphToolbar(
                    focusState: $viewModel.focusState,
                    selectedNodeCount: viewModel.viewState.selectedNodeIDs.count,
                    onFitToView: {
                        viewModel.requestFitToView()
                    },
                    onResetView: {
                        viewModel.requestResetView()
                    },
                    onClearSelection: {
                        // Clear selection AND fit to nodes (per UX spec)
                        viewModel.clearSelectionAndFit()
                    },
                    onClearFocus: {
                        viewModel.clearFocus()
                        // Switch to Overview tab when exiting focus mode
                        sidebarTab = .overview
                    },
                    onChangeAnchor: {
                        viewModel.setSelectedAsAnchor()
                    }
                )

                // Legend
                HStack(spacing: 16) {
                    if showsMyNodeLegend {
                        LegendItem(color: .systemPurple, label: "My Node")
                    }
                    if showsRoutingNodeLegend {
                        LegendItem(color: .systemOrange, label: "Routing Node")
                    }
                    if showsStationLegend {
                        LegendItem(color: .secondaryLabelColor, label: "Station")
                    }

                    Divider()
                        .frame(height: 14)

                    nodeSizeVisualLegend

                    edgeVisualLegend

                    Spacer()
                }
                .padding(.horizontal, 4)

                // Graph and sidebar
                HStack(alignment: .top, spacing: AnalyticsStyle.Layout.cardSpacing) {
                    ZStack {
                        AnalyticsGraphView(
                            graphModel: viewModel.viewState.graphModel,
                            nodePositions: viewModel.viewState.nodePositions,
                            selectedNodeIDs: viewModel.viewState.selectedNodeIDs,
                            hoveredNodeID: viewModel.viewState.hoveredNodeID,
                            myCallsign: settings.myCallsign,
                            resetToken: graphResetToken,
                            focusNodeID: focusNodeID,
                            fitToSelectionRequest: viewModel.fitToSelectionRequest,
                            fitTargetNodeIDs: viewModel.fitTargetNodeIDs,
                            resetCameraRequest: viewModel.resetCameraRequest,
                            visibleNodeIDs: viewModel.filteredGraph.visibleNodeIDs,
                            onSelect: { nodeID, isShift in
                                viewModel.handleNodeClick(nodeID, isShift: isShift)
                                // Switch to Inspector tab whenever a selection exists (single or multi).
                                if !viewModel.viewState.selectedNodeIDs.isEmpty {
                                    sidebarTab = .inspector
                                }
                            },
                            onSelectMany: { nodeIDs, isShift in
                                viewModel.handleSelectionRect(nodeIDs, isShift: isShift)
                                if !viewModel.viewState.selectedNodeIDs.isEmpty {
                                    sidebarTab = .inspector
                                }
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
                        if (!viewModel.hasLoadedGraph || viewModel.isGraphLoading) && viewModel.viewState.graphModel.nodes.isEmpty {
                            AnalyticsLoadingOverlay(label: "Building network graph")
                        }

                        if viewModel.isGraphLoading && !viewModel.viewState.graphModel.nodes.isEmpty {
                            Color.clear
                                .overlay(alignment: .topLeading) {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Updating graph…")
                                            .font(.caption2)
                                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .padding(8)
                                    .allowsHitTesting(false)
                                }
                        }
                    }
                    .frame(minHeight: AnalyticsStyle.Layout.graphHeight)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: GraphViewportHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                    .onAppear {
                        viewModel.setMyCallsignForLayout(settings.myCallsign)
                    }
                    .onChange(of: settings.myCallsign) { _, newValue in
                        viewModel.setMyCallsignForLayout(newValue)
                    }

                    // New tabbed sidebar (HIG: stable, always-present)
                    GraphSidebar(
                        selectedTab: $sidebarTab,
                        networkHealth: viewModel.viewState.networkHealth,
                        onFocusPrimaryHub: {
                            viewModel.selectPrimaryHub()
                            sidebarTab = .inspector
                        },
                        onShowActiveNodes: {
                            let activeIDs = viewModel.activeNodeIDs()
                            viewModel.handleSelectionRect(activeIDs, isShift: false)
                            if !viewModel.viewState.selectedNodeIDs.isEmpty {
                                sidebarTab = .inspector
                            }
                        },
                        onExportSummary: {
                            let summary = viewModel.exportNetworkSummary()
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(summary, forType: .string)
                            // Show toast feedback
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showExportToast = true
                            }
                            // Auto-hide after 2 seconds
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showExportToast = false
                                }
                            }
                        },
                        selectedNodeDetails: viewModel.selectedNodeDetails(),
                        selectedMultiNodeDetails: viewModel.selectedMultiNodeDetails(),
                        onSetAsAnchor: {
                            viewModel.setSelectedAsAnchor()
                        },
                        onClearSelection: {
                            // Clear selection AND fit to nodes (per UX spec)
                            viewModel.clearSelectionAndFit()
                        },
                        hubMetric: $viewModel.focusState.hubMetric,
                        fixedHeight: graphViewportHeight
                    )
                }
                .onPreferenceChange(GraphViewportHeightPreferenceKey.self) { newHeight in
                    guard newHeight > 0 else { return }
                    if abs(graphViewportHeight - newHeight) > 1 {
                        graphViewportHeight = newHeight
                    }
                }
            }

            if let note = viewModel.viewState.graphNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    .padding(.top, 4)
            }

            // Keyboard shortcuts hint
            Text("Click to select, Shift-drag to select, drag to pan, ⌘ or Opt + scroll to zoom, Esc clears")
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .padding(.top, 4)
        }
    }

    // MARK: - Network Graph Header Controls

    /// Controls scoped to the Network Graph card: View Mode and Station Identity.
    /// These settings affect only the graph visualization, not global analytics or Network Health.
    private var networkGraphHeaderControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text(GraphCopy.ViewMode.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    AnalyticsSegmentedPicker(
                        selection: graphSourceBinding,
                        items: GraphSourceChoice.allCases,
                        label: { $0.label },
                        tooltip: { $0.tooltip }
                    )
                }

                HStack(spacing: 6) {
                    Text(GraphCopy.ViewMode.pickerLabel)
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

                    if viewModel.graphViewMode.isNetRomMode {
                        AnalyticsSegmentedPicker(
                            selection: netRomModeBinding,
                            items: [GraphViewMode.netromClassic, GraphViewMode.netromInferred, GraphViewMode.netromHybrid],
                            label: { labelForGraphMode($0) },
                            tooltip: { $0.tooltip }
                        )
                    } else {
                        AnalyticsSegmentedPicker(
                            selection: packetModeBinding,
                            items: [GraphViewMode.connectivity, GraphViewMode.routing, GraphViewMode.all],
                            label: { labelForGraphMode($0) },
                            tooltip: { $0.tooltip }
                        )
                    }
                }

                Divider()
                    .frame(height: 18)

                if canConfigureDigipeaterPaths {
                    Toggle(isOn: $viewModel.includeViaDigipeaters) {
                        Text(GraphCopy.GraphControls.includeViaLabel)
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(GraphCopy.GraphControls.includeViaTooltip)
                } else {
                    Text(digipeaterPathStatusLabel)
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AnalyticsStyle.Colors.neutralFill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .help(digipeaterPathStatusTooltip)
                }

                HStack(spacing: 4) {
                    Text(GraphCopy.StationIdentity.pickerLabel)
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

                    Picker(GraphCopy.StationIdentity.pickerLabel, selection: $viewModel.stationIdentityMode) {
                        ForEach(StationIdentityMode.allCases) { mode in
                            Text(mode.shortName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .help(GraphCopy.StationIdentity.pickerTooltip)
                }
            }

            Text(graphViewSummaryText)
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
    }
}



extension AnalyticsDashboardView {
    private var graphSourceBinding: Binding<GraphSourceChoice> {
        Binding(
            get: {
                viewModel.graphViewMode.isNetRomMode ? .netrom : .packets
            },
            set: { newSource in
                switch newSource {
                case .packets:
                    if viewModel.graphViewMode.isNetRomMode {
                        viewModel.graphViewMode = preferredPacketViewMode
                    }
                case .netrom:
                    if !viewModel.graphViewMode.isNetRomMode {
                        viewModel.graphViewMode = preferredNetRomViewMode
                    }
                }
            }
        )
    }

    private var packetModeBinding: Binding<GraphViewMode> {
        Binding(
            get: {
                if viewModel.graphViewMode.isNetRomMode { return preferredPacketViewMode }
                return viewModel.graphViewMode
            },
            set: { newMode in
                guard [.connectivity, .routing, .all].contains(newMode) else { return }
                viewModel.graphViewMode = newMode
            }
        )
    }

    private var netRomModeBinding: Binding<GraphViewMode> {
        Binding(
            get: {
                if viewModel.graphViewMode.isNetRomMode { return viewModel.graphViewMode }
                return preferredNetRomViewMode
            },
            set: { newMode in
                guard [.netromClassic, .netromInferred, .netromHybrid].contains(newMode) else { return }
                viewModel.graphViewMode = newMode
            }
        )
    }

    private var graphViewSummaryText: String {
        switch viewModel.graphViewMode {
        case .connectivity:
            return "Packet source. Direct shows direct peer traffic and direct-heard RF evidence."
        case .routing:
            return viewModel.includeViaDigipeaters
                ? "Packet source. Routed emphasizes digipeater-mediated paths plus direct peers."
                : "Packet source. Routed currently shows direct peers only (digipeater paths are off)."
        case .all:
            return viewModel.includeViaDigipeaters
                ? "Packet source. Combined includes all packet-derived relationship evidence."
                : "Packet source. Combined omits digipeater-mediated paths while this toggle is off."
        case .netromClassic:
            return "NET/ROM source. Classic uses broadcast routing tables with direct neighbors."
        case .netromInferred:
            return "NET/ROM source. Inferred uses passive route discovery from observed traffic."
        case .netromHybrid:
            return "NET/ROM source. Hybrid merges classic broadcasts with inferred routes."
        }
    }

    private var edgeVisualLegend: some View {
        HStack(spacing: 8) {
            EdgeStrokeLegendItem(
                label: "Weak",
                lineColor: Color(nsColor: .secondaryLabelColor),
                thickness: 1.0,
                opacity: 0.55,
                tooltip: edgeWeakTooltip
            )

            EdgeStrokeLegendItem(
                label: "Strong",
                lineColor: Color(nsColor: .secondaryLabelColor),
                thickness: 2.4,
                opacity: 0.92,
                tooltip: edgeStrongTooltip
            )

            if showsViaStrokeLegend {
                EdgeStrokeLegendItem(
                    label: "Via",
                    lineColor: Color(nsColor: .tertiaryLabelColor),
                    thickness: 1.6,
                    opacity: 0.72,
                    tooltip: "Digipeater-mediated path evidence. Reachability on network, not direct RF proof."
                )
            }

            Text(edgeDimLegendLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
                )
                .help(edgeDimLegendTooltip)
        }
    }

    private var nodeSizeVisualLegend: some View {
        HStack(spacing: 8) {
            ScaleDotLegendItem(
                label: nodeSizeLowerLabel,
                diameter: 6,
                tooltip: nodeSizeSmallTooltip
            )
            ScaleDotLegendItem(
                label: nodeSizeHigherLabel,
                diameter: 12,
                tooltip: nodeSizeLargeTooltip
            )
        }
    }

    private func labelForGraphMode(_ mode: GraphViewMode) -> String {
        switch mode {
        case .connectivity:
            return GraphCopy.ViewMode.connectivityLabel
        case .routing:
            return GraphCopy.ViewMode.routingLabel
        case .all:
            return GraphCopy.ViewMode.allLabel
        case .netromClassic:
            return GraphCopy.ViewMode.netromClassicLabel
        case .netromInferred:
            return GraphCopy.ViewMode.netromInferredLabel
        case .netromHybrid:
            return GraphCopy.ViewMode.netromHybridLabel
        }
    }

    private func syncPreferredGraphModes(with mode: GraphViewMode) {
        if mode.isNetRomMode {
            preferredNetRomViewMode = mode
        } else {
            preferredPacketViewMode = mode
        }
    }

    private var showsViaStrokeLegend: Bool {
        guard !viewModel.graphViewMode.isNetRomMode else { return false }
        guard viewModel.includeViaDigipeaters else { return false }
        return viewModel.graphViewMode == .routing || viewModel.graphViewMode == .all
    }

    private var edgeWeakTooltip: String {
        if viewModel.graphViewMode.isNetRomMode {
            return "Thinner/lighter lines indicate lower relative route quality in this view."
        }
        return "Thinner/lighter lines indicate lower relative packet volume in this view."
    }

    private var edgeStrongTooltip: String {
        if viewModel.graphViewMode.isNetRomMode {
            return "Thicker/darker lines indicate higher relative route quality in this view."
        }
        return "Thicker/darker lines indicate higher relative packet volume in this view."
    }

    private var edgeDimLegendLabel: String {
        if viewModel.focusState.isFocusEnabled, viewModel.focusState.anchorNodeID != nil {
            return "Dimmed: context"
        }
        if viewModel.graphViewMode.isNetRomMode {
            return "Dimmed: stale"
        }
        return "Dimmed: lower evidence"
    }

    private var edgeDimLegendTooltip: String {
        if viewModel.focusState.isFocusEnabled, viewModel.focusState.anchorNodeID != nil {
            return "Dimmed lines are outside the active focus neighborhood."
        }
        if viewModel.graphViewMode.isNetRomMode {
            return "Dimmed lines are stale NET/ROM routes or weaker context."
        }
        return "Dimmer lines represent weaker relative evidence in the current packet view."
    }

    private var nodeSizeSmallTooltip: String {
        if viewModel.graphViewMode.isNetRomMode {
            return "Smaller node: lower relative route centrality in the current NET/ROM view."
        }
        return "Smaller node: lower relative traffic/connection weight in the current packet view."
    }

    private var nodeSizeLargeTooltip: String {
        if viewModel.graphViewMode.isNetRomMode {
            return "Larger node: higher relative route centrality in the current NET/ROM view."
        }
        return "Larger node: higher relative traffic/connection weight in the current packet view."
    }

    private var nodeSizeLowerLabel: String {
        if viewModel.graphViewMode.isNetRomMode {
            return "Lower centrality"
        }
        return "Lower weight"
    }

    private var nodeSizeHigherLabel: String {
        if viewModel.graphViewMode.isNetRomMode {
            return "Higher centrality"
        }
        return "Higher weight"
    }

    private var canConfigureDigipeaterPaths: Bool {
        !viewModel.graphViewMode.isNetRomMode && viewModel.graphViewMode != .connectivity
    }

    private var digipeaterPathStatusLabel: String {
        if viewModel.graphViewMode.isNetRomMode {
            return "Digipeater Paths: Packet source only"
        }
        return "Digipeater Paths: Not used in Direct lens"
    }

    private var digipeaterPathStatusTooltip: String {
        if viewModel.graphViewMode.isNetRomMode {
            return GraphCopy.GraphControls.includeViaUnavailableTooltip
        }
        return "Direct lens excludes digipeater-mediated paths by definition. Switch to Routed or Combined to configure this."
    }

    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: AnalyticsStyle.Layout.cardSpacing), count: AnalyticsStyle.Layout.metricColumns)
    }

    private var chartColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: AnalyticsStyle.Layout.cardSpacing), count: AnalyticsStyle.Layout.chartColumns)
    }

    private var visibleGraphNodesForLegend: [NetworkGraphNode] {
        let nodes = viewModel.viewState.graphModel.nodes
        let visibleNodeIDs = viewModel.filteredGraph.visibleNodeIDs
        guard !visibleNodeIDs.isEmpty else { return nodes }
        return nodes.filter { visibleNodeIDs.contains($0.id) }
    }

    private var normalizedMyCallsignForLegend: String {
        CallsignValidator.normalize(settings.myCallsign)
    }

    private var showsMyNodeLegend: Bool {
        guard !normalizedMyCallsignForLegend.isEmpty else { return false }
        return visibleGraphNodesForLegend.contains { node in
            nodeMatchesMyCallsign(node.callsign)
        }
    }

    private var showsRoutingNodeLegend: Bool {
        visibleGraphNodesForLegend.contains { $0.isNetRomOfficial }
    }

    private var showsStationLegend: Bool {
        visibleGraphNodesForLegend.contains { node in
            let isMyNode = !normalizedMyCallsignForLegend.isEmpty && nodeMatchesMyCallsign(node.callsign)
            return !isMyNode && !node.isNetRomOfficial
        }
    }

    private func nodeMatchesMyCallsign(_ nodeCallsign: String) -> Bool {
        let node = CallsignValidator.normalize(nodeCallsign)
        let mine = normalizedMyCallsignForLegend
        guard !mine.isEmpty else { return false }
        if node == mine { return true }
        if node.hasPrefix("\(mine)-") { return true }
        if mine.hasPrefix("\(node)-") { return true }
        return false
    }
}

private enum GraphSourceChoice: String, CaseIterable, Identifiable {
    case packets
    case netrom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .packets:
            return GraphCopy.ViewMode.packetSourceLabel
        case .netrom:
            return GraphCopy.ViewMode.netRomSourceLabel
        }
    }

    var tooltip: String {
        switch self {
        case .packets:
            return GraphCopy.ViewMode.packetSourceTooltip
        case .netrom:
            return GraphCopy.ViewMode.netRomSourceTooltip
        }
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

private struct AnalyticsCardWithControls<Content: View, Controls: View>: View {
    let title: String
    @ViewBuilder var controls: Controls
    @ViewBuilder var content: Content

    init(
        title: String,
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.controls = controls()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AnalyticsStyle.Layout.cardSpacing) {
            // Header with title and controls
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                controls
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

private struct AnalyticsLoadingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct AnalyticsLoadingOverlay: View {
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ChartLoadingPlaceholder: View {
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
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

private struct SummaryMetricPlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(AnalyticsStyle.Colors.cardStroke)
                .frame(width: 90, height: 10)
            RoundedRectangle(cornerRadius: 4)
                .fill(AnalyticsStyle.Colors.cardStroke)
                .frame(width: 50, height: 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
        .redacted(reason: .placeholder)
    }
}

private struct LegendItem: View {
    let color: NSColor
    let label: String
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
    }
}

private struct EdgeStrokeLegendItem: View {
    let label: String
    let lineColor: Color
    let thickness: CGFloat
    let opacity: Double
    let tooltip: String

    var body: some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(lineColor.opacity(opacity))
                .frame(width: 20, height: thickness)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        )
        .help(tooltip)
    }
}

private struct ScaleDotLegendItem: View {
    let label: String
    let diameter: CGFloat
    let tooltip: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(nsColor: .secondaryLabelColor).opacity(0.95))
                .frame(width: diameter, height: diameter)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        )
        .help(tooltip)
    }
}

private struct GraphViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
    @State private var hoverLocation: CGPoint?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

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

                // Highlight selected point with a rule mark
                if let selectedPoint {
                    RuleMark(x: .value("Selected", selectedPoint.bucket))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))

                    PointMark(
                        x: .value("Time", selectedPoint.bucket),
                        y: .value(valueLabel, selectedPoint.value)
                    )
                    .foregroundStyle(AnalyticsStyle.Colors.accent)
                    .symbolSize(60)
                }
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartYScale(range: .plotDimension(startPadding: 8, endPadding: 8))
            .chartXScale(range: .plotDimension(startPadding: 6, endPadding: 6))
            .chartXAxis {
                if shortRangeSpansBoundary {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                        AxisGridLine()
                            .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                        AxisTick()
                            .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                        AxisValueLabel(centered: true) {
                            if let date = value.as(Date.self) {
                                Text(shortRangeBoundaryLabel(for: date))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                    }
                } else if spansMultipleDays {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine()
                            .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                        AxisTick()
                            .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                        AxisValueLabel(format: multiDayXAxisFormat, centered: true)
                            .font(.caption2)
                            .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                            .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                        AxisTick()
                            .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                        AxisValueLabel(centered: false) {
                            if let date = value.as(Date.self) {
                                Text(xAxisLabel(for: date))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: AnalyticsStyle.Chart.axisLabelCount)) { _ in
                    AxisGridLine()
                        .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                    AxisTick()
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
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
                                hoverLocation = nil
                            }
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                hoverLocation = location
                                if let date: Date = proxy.value(atX: location.x) {
                                    let closest = points.min { lhs, rhs in
                                        abs(lhs.bucket.timeIntervalSince(date)) < abs(rhs.bucket.timeIntervalSince(date))
                                    }
                                    selectedPoint = closest
                                }
                            case .ended:
                                selectedPoint = nil
                                hoverLocation = nil
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let selectedPoint, let hoverLocation {
                                TimeSeriesChartTooltip(
                                    point: selectedPoint,
                                    valueLabel: valueLabel,
                                    bucket: bucket
                                )
                                .position(
                                    x: min(max(hoverLocation.x, 60), geometry.size.width - 60),
                                    y: max(hoverLocation.y - 40, 30)
                                )
                            }
                        }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: points.map { $0.value })
            .padding(.horizontal, 4)
        }
    }

    /// Returns a compact time format for x-axis labels based on bucket size
    private var spansMultipleDays: Bool {
        guard let first = points.first?.bucket, let last = points.last?.bucket else { return false }
        return !Calendar.current.isDate(first, inSameDayAs: last)
    }

    private var shortRangeSpansBoundary: Bool {
        guard spansMultipleDays,
              let first = points.first?.bucket,
              let last = points.last?.bucket else { return false }
        return last.timeIntervalSince(first) <= 36 * 3600
    }

    private var multiDaySpanDays: Int {
        guard let first = points.first?.bucket, let last = points.last?.bucket else { return 0 }
        let start = Calendar.current.startOfDay(for: first)
        let end = Calendar.current.startOfDay(for: last)
        return max(0, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0)
    }

    private var multiDayXAxisFormat: Date.FormatStyle {
        // HIG-aligned: concise labels for broad ranges.
        if multiDaySpanDays >= 6 {
            return .dateTime.weekday(.abbreviated)
        }
        return .dateTime.month(.abbreviated).day()
    }

    private func shortRangeBoundaryLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.component(.hour, from: date) == 0 {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }

    private func xAxisLabel(for date: Date) -> String {
        switch bucket {
        case .tenSeconds, .minute, .fiveMinutes, .fifteenMinutes:
            return Self.timeFormatter.string(from: date)
        case .hour:
            return Self.timeFormatter.string(from: date)
        case .day:
            return Self.dateTimeFormatter.string(from: date)
        }
    }
}

private struct TimeSeriesChartTooltip: View {
    let point: AnalyticsSeriesPoint
    let valueLabel: String
    let bucket: TimeBucket

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formattedTime)
                .font(.caption2)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            Text("\(valueLabel): \(point.value)")
                .font(.caption.weight(.medium))
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 2)
        )
    }

    private var formattedTime: String {
        switch bucket {
        case .minute, .fiveMinutes, .fifteenMinutes:
            return Self.timeFormatter.string(from: point.bucket)
        default:
            return Self.dateTimeFormatter.string(from: point.bucket)
        }
    }
}

private struct HistogramChart: View {
    let data: HistogramData
    @State private var selectedBin: HistogramBin?
    @State private var hoverLocation: CGPoint?

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
                    .foregroundStyle(selectedBin?.label == bin.label
                        ? AnalyticsStyle.Colors.accent
                        : AnalyticsStyle.Colors.accent.opacity(0.8))
                    .opacity(selectedBin == nil || selectedBin?.label == bin.label ? 1 : 0.5)
                }
            }
            .chartYScale(range: .plotDimension(startPadding: 8, endPadding: 8))
            .chartXScale(range: .plotDimension(startPadding: 6, endPadding: 6))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: AnalyticsStyle.Histogram.maxLabelCount)) { _ in
                    AxisGridLine()
                        .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                    AxisTick()
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                    AxisValueLabel()
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: AnalyticsStyle.Chart.axisLabelCount)) { _ in
                    AxisGridLine()
                        .foregroundStyle(AnalyticsStyle.Colors.chartGridLine)
                    AxisTick()
                        .foregroundStyle(AnalyticsStyle.Colors.chartAxis)
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
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                hoverLocation = location
                                if let label: String = proxy.value(atX: location.x) {
                                    let bin = data.bins.first(where: { $0.label == label })
                                    selectedBin = bin
                                }
                            case .ended:
                                selectedBin = nil
                                hoverLocation = nil
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let selectedBin, let hoverLocation {
                                HistogramChartTooltip(bin: selectedBin)
                                    .position(
                                        x: min(max(hoverLocation.x, 60), geometry.size.width - 60),
                                        y: max(hoverLocation.y - 40, 30)
                                    )
                            }
                        }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: data.bins.map { $0.count })
            .padding(.horizontal, 4)
        }
    }
}

private struct HistogramChartTooltip: View {
    let bin: HistogramBin

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(bin.lowerBound)–\(bin.upperBound) bytes")
                .font(.caption2)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            Text("\(bin.count) packets")
                .font(.caption.weight(.medium))
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 2)
        )
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
    @State private var hoveredCell: HeatmapHoverInfo?

    private struct HeatmapHoverInfo: Equatable {
        let row: Int
        let col: Int
        let value: Int
        let xLabel: String
        let yLabel: String
        let position: CGPoint
    }

    var body: some View {
        if data.matrix.isEmpty {
            EmptyChartPlaceholder(text: "No data")
        } else {
            GeometryReader { proxy in
                let rows = data.matrix.count
                let cols = data.matrix.first?.count ?? 0
                let labelWidth = AnalyticsStyle.Heatmap.labelWidth
                let labelHeight = AnalyticsStyle.Heatmap.labelHeight
                let gridWidth = Swift.max(1, proxy.size.width - labelWidth)
                let gridHeight = Swift.max(1, proxy.size.height - labelHeight)
                let cellWidth = gridWidth / CGFloat(cols)
                let cellHeight = gridHeight / CGFloat(rows)

                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        guard rows > 0, cols > 0 else { return }
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

                                // Draw highlight border for hovered cell
                                if let hovered = hoveredCell, hovered.row == row, hovered.col == col {
                                    context.stroke(
                                        Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: AnalyticsStyle.Heatmap.cellCornerRadius),
                                        with: .color(Color(nsColor: .labelColor)),
                                        lineWidth: 2
                                    )
                                }
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

                    // Invisible hit area for hover detection
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                // Check if we're in the grid area
                                let gridX = location.x - labelWidth
                                let gridY = location.y
                                guard gridX >= 0, gridY >= 0, gridY < gridHeight else {
                                    hoveredCell = nil
                                    return
                                }
                                let col = Int(gridX / cellWidth)
                                let row = Int(gridY / cellHeight)
                                guard row >= 0, row < rows, col >= 0, col < cols else {
                                    hoveredCell = nil
                                    return
                                }
                                let value = data.matrix[row][col]
                                let xLabel = col < data.xLabels.count ? data.xLabels[col] : ""
                                let yLabel = row < data.yLabels.count ? data.yLabels[row] : ""
                                hoveredCell = HeatmapHoverInfo(
                                    row: row,
                                    col: col,
                                    value: value,
                                    xLabel: xLabel,
                                    yLabel: yLabel,
                                    position: location
                                )
                            case .ended:
                                hoveredCell = nil
                            }
                        }

                    // Tooltip overlay
                    if let hovered = hoveredCell {
                        HeatmapTooltip(
                            xLabel: hovered.xLabel,
                            yLabel: hovered.yLabel,
                            value: hovered.value
                        )
                        .position(
                            x: min(hovered.position.x + 50, proxy.size.width - 60),
                            y: max(hovered.position.y - 30, 30)
                        )
                    }
                }
            }
        }
    }
}

private struct HeatmapTooltip: View {
    let xLabel: String
    let yLabel: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(yLabel), \(xLabel)")
                .font(.caption2)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            Text("\(value) packets")
                .font(.caption.weight(.medium))
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 2)
        )
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

// Old GraphInspectorView, NodeDetailsView, and MetricRow removed
// Now using GraphSidebar component with tabbed Overview/Inspector

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
                    // Defer to next run loop to avoid modifying state during view update
                    DispatchQueue.main.async {
                        onChange(proxy.size.width)
                    }
                }
                .onChange(of: proxy.size.width) { _, newValue in
                    // Defer to next run loop to avoid modifying state during view update
                    DispatchQueue.main.async {
                        onChange(newValue)
                    }
                }
        }
    }
}

// MARK: - Flow Layout for Responsive Controls

/// A layout that wraps content to the next row when it doesn't fit.
nonisolated private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, proposal: proposal)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, proposal: proposal)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(subviews: Subviews, proposal: ProposedViewSize) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                // Move to next row
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, currentX - spacing)
        }

        totalHeight = currentY + rowHeight
        return (CGSize(width: totalWidth, height: totalHeight), positions)
    }
}

// MARK: - Floating Control Bar

/// Preference key for tracking scroll offset
nonisolated private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

nonisolated private struct FloatingControlBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 56
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Floating glass control bar that sticks to the top of the scroll view.
/// Uses material blur when available, falls back to solid background for accessibility.
private struct FloatingControlBar<Content: View>: View {
    let scrollOffset: CGFloat
    let reduceTransparency: Bool
    @ViewBuilder let content: Content

    /// Threshold in points before the bar transitions to "scrolled" state
    private let scrollThreshold: CGFloat = 12
    /// Corner radius for the pill-shaped bar
    private let cornerRadius: CGFloat = 12

    private var isScrolled: Bool {
        scrollOffset > scrollThreshold
    }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: AnalyticsStyle.Layout.floatingBarMaxWidth, alignment: .leading)
        .background(
            Group {
                if reduceTransparency {
                    // Solid background for accessibility
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    // Glass effect with material blur - more opaque for better readability
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                        .opacity(isScrolled ? 1 : 0.92)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isScrolled ? 0.10 : 0.05), radius: isScrolled ? 6 : 3, y: 1)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AnalyticsStyle.Layout.floatingBarOuterPadding)
        .padding(.top, 8)
        .animation(.easeOut(duration: 0.2), value: isScrolled)
    }
}
