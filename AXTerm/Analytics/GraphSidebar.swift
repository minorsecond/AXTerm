//
//  GraphSidebar.swift
//  AXTerm
//
//  A HIG-compliant sidebar for the network graph with tabbed content.
//
//  Design principles (Apple HIG):
//  - Sidebar is always present, never disappears
//  - Uses segmented control for tab switching
//  - Selection changes do not cause layout shifts
//  - Both tabs are always rendered, visibility controlled by tab state
//  - All copy centralized in GraphCopy.swift
//

import SwiftUI

private typealias Copy = GraphCopy

// MARK: - Sidebar Tab

enum GraphSidebarTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case inspector = "Inspector"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "chart.bar"
        case .inspector: return "info.circle"
        }
    }
}

// MARK: - Graph Sidebar

/// Tabbed sidebar with Overview (Network Health) and Inspector (Node Details)
struct GraphSidebar: View {
    // Tab state
    @Binding var selectedTab: GraphSidebarTab

    // Overview tab data
    let networkHealth: NetworkHealth
    let onFocusPrimaryHub: () -> Void
    let onShowActiveNodes: () -> Void
    let onExportSummary: () -> Void

    // Inspector tab data
    let selectedNodeDetails: GraphInspectorDetails?
    let onSetAsAnchor: () -> Void
    let onClearSelection: () -> Void

    // Hub metric for Primary Hub action
    @Binding var hubMetric: HubMetric

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            tabPicker
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Tab content
            tabContent
        }
        .frame(width: AnalyticsStyle.Layout.inspectorWidth)
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(GraphSidebarTab.allCases) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Tab Content

    private var tabContent: some View {
        // Use ZStack to prevent layout shifts - both views are always rendered
        ZStack {
            // Overview tab
            SidebarOverviewContent(
                health: networkHealth,
                hubMetric: $hubMetric,
                onFocusPrimaryHub: onFocusPrimaryHub,
                onShowActiveNodes: onShowActiveNodes,
                onExportSummary: onExportSummary
            )
            .opacity(selectedTab == .overview ? 1 : 0)

            // Inspector tab
            SidebarInspectorContent(
                details: selectedNodeDetails,
                onSetAsAnchor: onSetAsAnchor,
                onClearSelection: onClearSelection
            )
            .opacity(selectedTab == .inspector ? 1 : 0)
        }
    }
}

// MARK: - Overview Content

/// Content for the Overview tab (Network Health)
private struct SidebarOverviewContent: View {
    let health: NetworkHealth
    @Binding var hubMetric: HubMetric
    let onFocusPrimaryHub: () -> Void
    let onShowActiveNodes: () -> Void
    let onExportSummary: () -> Void

    @State private var showingScoreInfo = false
    @State private var showingHubMetricPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                headerSection

                Divider()

                // Health score
                healthScoreSection

                // Reasons
                if !health.reasons.isEmpty {
                    reasonsSection
                }

                Divider()

                // Metrics grid
                metricsSection

                // Warnings
                if !health.warnings.isEmpty {
                    Divider()
                    warningsSection
                }

                // Activity trend
                if !health.activityTrend.isEmpty {
                    Divider()
                    trendSection
                }

                Divider()

                // Quick actions
                actionsSection

                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            Text(Copy.Health.headerLabel)
                .font(.headline)
                .help(Copy.Health.headerTooltip)
            Spacer()
            Button(action: { showingScoreInfo.toggle() }) {
                Image(systemName: "info.circle")
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(Copy.Health.overallScoreTooltip)
            .popover(isPresented: $showingScoreInfo, arrowEdge: .trailing) {
                ScoreExplainerView(
                    breakdown: health.scoreBreakdown,
                    finalScore: health.score,
                    timeframeDisplayName: health.timeframeDisplayName
                )
            }
        }
    }

    private var healthScoreSection: some View {
        HStack(alignment: .center, spacing: 12) {
            HealthGaugeView(score: health.score, rating: health.rating)
                .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text(health.rating.rawValue)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ratingColor(health.rating))
                Text("\(health.score)/100")
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            }

            Spacer()
        }
    }

    private var reasonsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(health.reasons, id: \.self) { reason in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                }
            }
        }
    }

    private var metricsSection: some View {
        let tf = health.timeframeDisplayName

        return VStack(alignment: .leading, spacing: 8) {
            Text("Metrics")
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .help(Copy.Health.headerTooltip)

            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ], spacing: 8) {
                // Topology metrics (timeframe-dependent, canonical graph)
                MetricCell(
                    label: Copy.Health.stationsHeardLabelWithTimeframe(tf),
                    value: formatNumber(health.metrics.totalStations),
                    tooltip: Copy.Health.stationsHeardTooltip(tf)
                )
                // Activity metrics (fixed 10-minute window)
                MetricCell(
                    label: Copy.Health.activeStationsLabel,
                    value: "\(health.metrics.activeStations)",
                    tooltip: Copy.Health.activeStationsTooltip
                )
                MetricCell(
                    label: Copy.Health.mainClusterLabelWithTimeframe(tf),
                    value: formatPercent(health.metrics.largestComponentPercent),
                    tooltip: Copy.Health.mainClusterTooltip(tf)
                )
                MetricCell(
                    label: Copy.Health.packetRateLabel,
                    value: String(format: "%.1f", health.metrics.packetRate),
                    tooltip: Copy.Health.packetRateTooltip
                )
                MetricCell(
                    label: Copy.Health.connectivityRatioLabelWithTimeframe(tf),
                    value: formatPercent(health.metrics.connectivityRatio),
                    tooltip: Copy.Health.connectivityRatioTooltip(tf)
                )
                MetricCell(
                    label: Copy.Health.isolationReductionLabelWithTimeframe(tf),
                    value: formatPercent(health.metrics.isolationReduction),
                    tooltip: Copy.Health.isolationReductionTooltip(tf)
                )
            }
        }
    }

    /// Dynamic percentage formatting per HIG:
    /// ≥10%: 0 decimals, <10%: 1 decimal, <1%: 2 decimals
    private func formatPercent(_ value: Double) -> String {
        if value >= 10 {
            return "\(Int(value.rounded()))%"
        } else if value >= 1 {
            return String(format: "%.1f%%", value)
        } else if value > 0 {
            return String(format: "%.2f%%", value)
        } else {
            return "0%"
        }
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attention")
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

            ForEach(health.warnings) { warning in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: warning.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(warning.severity == .warning ? Color(nsColor: .systemOrange) : Color(nsColor: .systemBlue))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.title)
                            .font(.caption.weight(.medium))
                        Text(warning.detail)
                            .font(.caption2)
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(warning.severity == .warning
                              ? Color(nsColor: .systemOrange).opacity(0.1)
                              : Color(nsColor: .systemBlue).opacity(0.1))
                )
            }
        }
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.Health.activityChartLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .help(Copy.Health.activityChartTooltip)

            ActivitySparkline(data: health.activityTrend)
                .frame(height: 40)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions")
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

            // Focus Primary Hub with metric picker
            HStack(spacing: 4) {
                Button(action: onFocusPrimaryHub) {
                    HStack {
                        Image(systemName: "scope")
                        Text(Copy.QuickActions.focusPrimaryHubLabel)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help(Copy.QuickActions.focusPrimaryHubTooltip)
                .accessibilityLabel(Copy.QuickActions.focusPrimaryHubAccessibility)

                // Hub metric picker button
                Button(action: { showingHubMetricPicker.toggle() }) {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .help(Copy.HubMetric.pickerTooltip)
                .popover(isPresented: $showingHubMetricPicker, arrowEdge: .bottom) {
                    hubMetricPickerContent
                }
            }

            Button(action: onShowActiveNodes) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(Copy.QuickActions.showActiveNodesLabel)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help(Copy.QuickActions.showActiveNodesTooltip)
            .accessibilityLabel(Copy.QuickActions.showActiveNodesAccessibility)

            Button(action: onExportSummary) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text(Copy.QuickActions.exportSummaryLabel)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help(Copy.QuickActions.exportSummaryTooltip)
            .accessibilityLabel(Copy.QuickActions.exportSummaryAccessibility)
        }
    }

    private var hubMetricPickerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.HubMetric.pickerLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Picker("", selection: $hubMetric) {
                ForEach(HubMetric.allCases) { metric in
                    VStack(alignment: .leading) {
                        Text(metric.rawValue)
                        Text(metric.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(metric)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(12)
        .frame(width: 180)
    }

    // MARK: - Helpers

    private func ratingColor(_ rating: HealthRating) -> Color {
        switch rating {
        case .excellent: return Color(nsColor: .systemGreen)
        case .good: return Color(nsColor: .systemBlue)
        case .fair: return Color(nsColor: .systemOrange)
        case .poor: return Color(nsColor: .systemRed)
        case .unknown: return AnalyticsStyle.Colors.textSecondary
        }
    }

    private func formatNumber(_ value: Int) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000)
        }
        return "\(value)"
    }
}

// MARK: - Inspector Content

/// Content for the Inspector tab (Node Details)
private struct SidebarInspectorContent: View {
    let details: GraphInspectorDetails?
    let onSetAsAnchor: () -> Void
    let onClearSelection: () -> Void

    var body: some View {
        if let details {
            nodeDetailsView(details)
        } else {
            emptyStateView
        }
    }

    // MARK: - Node Details

    private func nodeDetailsView(_ details: GraphInspectorDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                Text(Copy.Inspector.tabLabel)
                    .font(.headline)

                // Node callsign
                Text(details.node.callsign)
                    .font(.title3.weight(.semibold))

                Divider()

                // Metrics
                VStack(alignment: .leading, spacing: 6) {
                    InspectorMetricRow(
                        title: Copy.Inspector.packetsInLabel,
                        value: details.node.inCount,
                        tooltip: Copy.Inspector.packetsInTooltip
                    )
                    InspectorMetricRow(
                        title: Copy.Inspector.packetsOutLabel,
                        value: details.node.outCount,
                        tooltip: Copy.Inspector.packetsOutTooltip
                    )
                    InspectorMetricRow(
                        title: Copy.Inspector.bytesInLabel,
                        value: details.node.inBytes,
                        tooltip: Copy.Inspector.bytesInTooltip
                    )
                    InspectorMetricRow(
                        title: Copy.Inspector.bytesOutLabel,
                        value: details.node.outBytes,
                        tooltip: Copy.Inspector.bytesOutTooltip
                    )
                    InspectorMetricRow(
                        title: Copy.Inspector.degreeLabel,
                        value: details.node.degree,
                        tooltip: Copy.Inspector.degreeTooltip
                    )
                }

                Divider()

                // Top neighbors
                VStack(alignment: .leading, spacing: 6) {
                    Text(Copy.Inspector.neighborsLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                        .help(Copy.Inspector.neighborsTooltip)

                    if details.neighbors.isEmpty {
                        Text(Copy.HubMetric.noNeighborsFound)
                            .font(.caption)
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                            .padding(.vertical, 4)
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

                Spacer(minLength: 0)

                Divider()

                // Actions
                VStack(spacing: 8) {
                    Button(action: onSetAsAnchor) {
                        HStack {
                            Image(systemName: "scope")
                            Text(Copy.Focus.setAsAnchorLabel)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help(Copy.Focus.setAsAnchorTooltip)
                    .accessibilityLabel(Copy.Focus.setAsAnchorAccessibility)

                    Button(action: onClearSelection) {
                        HStack {
                            Image(systemName: "xmark")
                            Text(Copy.Toolbar.clearSelectionLabel + " Selection")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help(Copy.Selection.nodeChipClearTooltip)
                    .accessibilityLabel(Copy.Selection.clearButtonAccessibility)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "cursorarrow.click")
                .font(.system(size: 32))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary.opacity(0.5))

            VStack(spacing: 4) {
                Text(Copy.Inspector.noSelectionTitle)
                    .font(.headline)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

                Text(Copy.Inspector.noSelectionMessage)
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary.opacity(0.8))
                    .multilineTextAlignment(.center)

                Text("Shift-click or drag to\nselect multiple nodes.")
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }
}

// MARK: - Supporting Views

private struct InspectorMetricRow: View {
    let title: String
    let value: Int
    let tooltip: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted())
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .monospacedDigit()
        }
        .font(.caption)
        .help(tooltip)
    }
}

private struct MetricCell: View {
    let label: String
    let value: String
    var tooltip: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(tooltip)
    }
}

private struct ActivitySparkline: View {
    let data: [Int]

    var body: some View {
        GeometryReader { geometry in
            let maxValue = max(1, data.max() ?? 1)
            let width = geometry.size.width
            let height = geometry.size.height
            let stepWidth = width / CGFloat(max(1, data.count - 1))

            Path { path in
                guard !data.isEmpty else { return }

                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) * stepWidth
                    let y = height - (CGFloat(value) / CGFloat(maxValue)) * height

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
    }
}

// MARK: - Health Gauge View

private struct HealthGaugeView: View {
    let score: Int
    let rating: HealthRating

    var body: some View {
        ZStack {
            // Background arc
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(
                    Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(90))

            // Foreground arc (score)
            Circle()
                .trim(from: 0.15, to: 0.15 + 0.7 * CGFloat(score) / 100)
                .stroke(
                    gaugeColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(90))

            // Score text
            Text("\(score)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var gaugeColor: Color {
        switch rating {
        case .excellent: return Color(nsColor: .systemGreen)
        case .good: return Color(nsColor: .systemBlue)
        case .fair: return Color(nsColor: .systemOrange)
        case .poor: return Color(nsColor: .systemRed)
        case .unknown: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct GraphSidebar_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            // Overview tab
            GraphSidebar(
                selectedTab: .constant(.overview),
                networkHealth: previewHealth,
                onFocusPrimaryHub: {},
                onShowActiveNodes: {},
                onExportSummary: {},
                selectedNodeDetails: nil,
                onSetAsAnchor: {},
                onClearSelection: {},
                hubMetric: .constant(.degree)
            )

            // Inspector tab with selection
            GraphSidebar(
                selectedTab: .constant(.inspector),
                networkHealth: previewHealth,
                onFocusPrimaryHub: {},
                onShowActiveNodes: {},
                onExportSummary: {},
                selectedNodeDetails: previewDetails,
                onSetAsAnchor: {},
                onClearSelection: {},
                hubMetric: .constant(.degree)
            )

            // Inspector tab without selection
            GraphSidebar(
                selectedTab: .constant(.inspector),
                networkHealth: previewHealth,
                onFocusPrimaryHub: {},
                onShowActiveNodes: {},
                onExportSummary: {},
                selectedNodeDetails: nil,
                onSetAsAnchor: {},
                onClearSelection: {},
                hubMetric: .constant(.degree)
            )
        }
        .padding()
    }

    static var previewHealth: NetworkHealth {
        NetworkHealth(
            score: 69,
            rating: .good,
            reasons: [
                "Moderately connected (64% in main cluster)",
                "7 stations recently active",
                "Light traffic (0.50/min)"
            ],
            metrics: NetworkHealthMetrics(
                // Topology metrics (canonical graph, timeframe-dependent)
                totalStations: 25,
                totalPackets: 1300,
                largestComponentPercent: 64,
                connectivityRatio: 8.5,
                isolationReduction: 92,
                isolatedNodes: 2,
                topRelayCallsign: "DRL",
                topRelayConcentration: 26,
                // Activity metrics (fixed 10-minute window)
                activeStations: 7,
                packetRate: 0.5,
                freshness: 0.28  // 7/25
            ),
            warnings: [
                NetworkWarning(
                    id: "stale",
                    severity: .info,
                    title: "Stale stations",
                    detail: "18 stations not heard in 10 minutes"
                )
            ],
            activityTrend: [2, 5, 3, 8, 12, 7, 4, 6, 9, 11, 8, 5],
            scoreBreakdown: HealthScoreBreakdown(
                c1MainClusterPct: 64, c2ConnectivityPct: 8.5, c3IsolationReduction: 92, topologyScore: 38.5,
                a1ActiveNodesPct: 28, a2PacketRateScore: 50, packetRatePerMin: 0.5, activityScore: 36.8,
                totalNodes: 25, activeNodes10m: 7, isolatedNodes: 2, finalScore: 69
            ),
            timeframeDisplayName: "24h"
        )
    }

    static var previewDetails: GraphInspectorDetails {
        GraphInspectorDetails(
            node: NetworkGraphNode(
                id: "W0ARP-10",
                callsign: "W0ARP-10",
                weight: 66,
                inCount: 0,
                outCount: 66,
                inBytes: 0,
                outBytes: 727,
                degree: 3
            ),
            neighbors: [
                GraphNeighborStat(id: "N0XCR", weight: 44, bytes: 512),
                GraphNeighborStat(id: "KC0LDY", weight: 11, bytes: 128),
                GraphNeighborStat(id: "WB4CIW", weight: 11, bytes: 128)
            ]
        )
    }
}
#endif
