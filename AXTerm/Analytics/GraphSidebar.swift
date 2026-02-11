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

import AppKit
import SwiftUI

private typealias Copy = GraphCopy

// MARK: - Sidebar Tab

nonisolated enum GraphSidebarTab: String, CaseIterable, Identifiable {
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
    let selectedMultiNodeDetails: GraphMultiInspectorDetails?
    let onSetAsAnchor: () -> Void
    let onClearSelection: () -> Void

    // Hub metric for Primary Hub action
    @Binding var hubMetric: HubMetric
    var fixedHeight: CGFloat? = nil
    var body: some View {
        // Stable sidebar height (matches develop visuals) and shared by Overview/Inspector.
        let resolvedHeight = max(fixedHeight ?? 0, AnalyticsStyle.Layout.graphHeight + 320)
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
        .frame(height: resolvedHeight, alignment: .top)
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
        Group {
            if selectedTab == .overview {
                SidebarOverviewContent(
                    health: networkHealth,
                    hubMetric: $hubMetric,
                    onFocusPrimaryHub: onFocusPrimaryHub,
                    onShowActiveNodes: onShowActiveNodes,
                    onExportSummary: onExportSummary
                )
            } else {
                SidebarInspectorContent(
                    details: selectedNodeDetails,
                    multiDetails: selectedMultiNodeDetails,
                    onSetAsAnchor: onSetAsAnchor,
                    onClearSelection: onClearSelection
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                .help(reason)
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
                .help("\(warning.title): \(warning.detail)")
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
    let multiDetails: GraphMultiInspectorDetails?
    let onSetAsAnchor: () -> Void
    let onClearSelection: () -> Void
    @State private var showAllSelectedStationsSheet = false

    var body: some View {
        Group {
            if let multiDetails {
                multiNodeDetailsView(multiDetails)
            } else if let details {
                nodeDetailsView(details)
            } else {
                emptyStateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Node Details

    private func multiNodeDetailsView(_ details: GraphMultiInspectorDetails) -> some View {
        let maxSelectedRows = 10
        let maxInlineNames = 10
        let displayedSelectedRows = Array(details.selectedNodes.prefix(maxSelectedRows))
        let displayedNames = details.selectedNodes.prefix(maxInlineNames).map(\.callsign)
        let remainingNames = max(0, details.selectedNodes.count - displayedNames.count)
        let namesSummary = remainingNames > 0
            ? "\(displayedNames.joined(separator: ", ")) +\(remainingNames) more"
            : displayedNames.joined(separator: ", ")

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(Copy.Inspector.tabLabel)
                    .font(.headline)

                HStack(alignment: .firstTextBaseline) {
                    Text("\(details.selectionCount)")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text(Copy.Inspector.multiSelectionTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                }

                Text(namesSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .background(Color.clear)
                    .contentShape(Rectangle())
                    .help(Copy.Inspector.multiSelectionListTooltip)

                if details.selectedNodes.count > maxSelectedRows {
                    Button {
                        showAllSelectedStationsSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.expand.vertical")
                                .font(.caption2)
                            Text("View All (\(details.selectedNodes.count))")
                            Spacer()
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    .help("Open a full list of all selected stations in a dedicated view.")
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    InspectorMetricStringRow(
                        title: Copy.Inspector.internalLinksLabel,
                        value: "\(details.internalLinkCount)/\(details.possibleInternalLinks)",
                        tooltip: Copy.Inspector.internalLinksTooltip
                    )
                    InspectorMetricStringRow(
                        title: Copy.Inspector.selectionDensityLabel,
                        value: String(format: "%.0f%%", details.density * 100),
                        tooltip: Copy.Inspector.selectionDensityTooltip
                    )
                    InspectorMetricStringRow(
                        title: Copy.Inspector.packetsWithinSelectionLabel,
                        value: details.internalPacketCount.formatted(),
                        tooltip: Copy.Inspector.packetsWithinSelectionTooltip
                    )
                    InspectorMetricStringRow(
                        title: Copy.Inspector.bytesWithinSelectionLabel,
                        value: ByteCountFormatter.string(fromByteCount: Int64(details.internalByteCount), countStyle: .file),
                        tooltip: Copy.Inspector.bytesWithinSelectionTooltip
                    )
                    InspectorMetricStringRow(
                        title: Copy.Inspector.bytesTouchingSelectionLabel,
                        value: ByteCountFormatter.string(fromByteCount: Int64(details.touchingByteCount), countStyle: .file),
                        tooltip: Copy.Inspector.bytesTouchingSelectionTooltip
                    )
                    InspectorMetricStringRow(
                        title: Copy.Inspector.sharedExternalRelaysLabel,
                        value: details.externalReachCount.formatted(),
                        tooltip: Copy.Inspector.sharedExternalRelaysTooltip
                    )

                    Text(Copy.Inspector.selectionBytesLegend)
                        .font(.caption2)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                        .padding(.top, 2)
                }

                Divider()

                if !details.relationshipBreakdown.isEmpty {
                    relationshipBreakdownSection(details.relationshipBreakdown)
                    Divider()
                }

                if !details.internalLinks.isEmpty {
                    groupedSectionHeader(
                        Copy.Inspector.withinSelectionHeader,
                        systemImage: "link",
                        tooltip: Copy.Inspector.withinSelectionTooltip
                    )
                    ForEach(details.internalLinks.prefix(8)) { link in
                        internalLinkRow(link)
                    }
                    if details.internalLinks.count > 8 {
                        Text("+ \(details.internalLinks.count - 8) more links")
                            .font(.caption2)
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    }
                    Divider()
                }

                if !details.sharedExternalConnections.isEmpty {
                    groupedSectionHeader(
                        Copy.Inspector.sharedConnectionsHeader,
                        systemImage: "point.3.connected.trianglepath.dotted",
                        tooltip: Copy.Inspector.sharedConnectionsTooltip
                    )
                    ForEach(details.sharedExternalConnections.prefix(6)) { connection in
                        sharedConnectionRow(connection)
                    }
                    if details.sharedExternalConnections.count > 6 {
                        Text("+ \(details.sharedExternalConnections.count - 6) more shared connections")
                            .font(.caption2)
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    }
                    Divider()
                }

                groupedSectionHeader(
                    Copy.Inspector.selectedStationsHeader,
                    systemImage: "dot.circle.and.hand.point.up.left.fill",
                    tooltip: Copy.Inspector.selectedStationsTooltip
                )
                ForEach(displayedSelectedRows) { node in
                    selectedStationRow(node)
                }
                if details.selectedNodes.count > displayedSelectedRows.count {
                    Text("+ \(details.selectedNodes.count - displayedSelectedRows.count) more selected stations")
                        .font(.caption2)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                        .help("Inspector stays compact. Use View All to inspect every selected station.")
                }

                Divider()

                VStack(spacing: 8) {
                    Button(action: onSetAsAnchor) {
                        HStack {
                            Image(systemName: "scope")
                            Text(Copy.Focus.focusSelectionLabel)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help(Copy.Focus.focusSelectionTooltip)
                    .accessibilityLabel(Copy.Focus.focusSelectionAccessibility)

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
        .id("multi-\(details.selectionCount)-\(details.selectedNodes.map(\.id).joined(separator: ","))")
        .onChange(of: details.selectionCount) { _, _ in
            showAllSelectedStationsSheet = false
        }
        .sheet(isPresented: $showAllSelectedStationsSheet) {
            AllSelectedStationsSheet(nodes: details.selectedNodes)
        }
    }

    private func nodeDetailsView(_ details: GraphInspectorDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                Text(Copy.Inspector.tabLabel)
                    .font(.headline)

                // Node callsign with grouped SSID indicator
                HStack(alignment: .center, spacing: 6) {
                    Text(details.node.callsign)
                        .font(.title3.weight(.semibold))

                    // Show badge if multiple SSIDs are grouped
                    if details.node.isGroupedStation {
                        Text("\(details.node.groupedSSIDs.count)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                            .help(String(format: Copy.StationIdentity.groupedBadgeTooltipTemplate,
                                         details.node.groupedSSIDs.count,
                                         details.node.groupedSSIDs.joined(separator: ", ")))
                    }
                }

                // Grouped SSIDs section (if multiple)
                if details.node.isGroupedStation {
                    groupedSSIDsSection(details.node.groupedSSIDs)
                }

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
                    InspectorMetricStringRow(
                        title: Copy.Inspector.bytesInLabel,
                        value: ByteCountFormatter.string(fromByteCount: Int64(details.node.inBytes), countStyle: .file),
                        tooltip: Copy.Inspector.bytesInTooltip
                    )
                    InspectorMetricStringRow(
                        title: Copy.Inspector.bytesOutLabel,
                        value: ByteCountFormatter.string(fromByteCount: Int64(details.node.outBytes), countStyle: .file),
                        tooltip: Copy.Inspector.bytesOutTooltip
                    )
                    InspectorMetricRow(
                        title: Copy.Inspector.degreeLabel,
                        value: details.node.degree,
                        tooltip: Copy.Inspector.degreeTooltip
                    )
                }

                Divider()

                // Classified relationship sections
                relationshipSections(details)

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

    private func relationshipBreakdownSection(_ breakdown: [LinkType: Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            groupedSectionHeader(
                Copy.Inspector.interactionTypesHeader,
                systemImage: "arrow.triangle.branch",
                tooltip: Copy.Inspector.interactionTypesTooltip
            )

            if let direct = breakdown[.directPeer] {
                InspectorMetricStringRow(
                    title: Copy.Inspector.directPeersSection,
                    value: direct.formatted(),
                    tooltip: Copy.Inspector.directPeersSectionTooltip
                )
            }
            if let heardDirect = breakdown[.heardDirect] {
                InspectorMetricStringRow(
                    title: Copy.Inspector.heardDirectSection,
                    value: heardDirect.formatted(),
                    tooltip: Copy.Inspector.heardDirectSectionTooltip
                )
            }
            if let heardVia = breakdown[.heardVia] {
                InspectorMetricStringRow(
                    title: Copy.Inspector.heardViaSection,
                    value: heardVia.formatted(),
                    tooltip: Copy.Inspector.heardViaSectionTooltip
                )
            }
        }
    }

    private func groupedSectionHeader(_ title: String, systemImage: String, tooltip: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(Color.clear)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private func internalLinkRow(_ link: GraphMultiInspectorDetails.InternalLink) -> some View {
        HStack(spacing: 8) {
            Text("\(link.sourceCallsign)  \u{2194}  \(link.targetCallsign)")
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(link.packetCount.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(Color.clear)
        .contentShape(Rectangle())
        .help(String(format: Copy.Inspector.internalLinkRowTooltipTemplate, link.packetCount, link.bytes))
    }

    private func sharedConnectionRow(_ connection: GraphMultiInspectorDetails.SharedExternalConnection) -> some View {
        HStack(spacing: 8) {
            Text(connection.callsign)
                .font(.caption)
            Spacer(minLength: 6)
            Text("\(connection.connectedSelectedIDs.count)x")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            Text(connection.totalPackets.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(Color.clear)
        .contentShape(Rectangle())
        .help(
            String(
                format: Copy.Inspector.sharedConnectionRowTooltipTemplate,
                connection.connectedSelectedIDs.count,
                connection.totalPackets
            )
        )
    }

    private func selectedStationRow(_ node: NetworkGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(node.callsign)
                    .font(.caption)
                Spacer()
                Text("\(node.degree)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            }
            Text("In \(node.inCount.formatted()) • Out \(node.outCount.formatted())")
                .font(.caption2)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(Color.clear)
        .contentShape(Rectangle())
        .help(String(format: Copy.Inspector.selectedStationRowTooltipTemplate, node.inCount, node.outCount, node.degree))
    }

    // MARK: - Relationship Sections

    @ViewBuilder
    private func relationshipSections(_ details: GraphInspectorDetails) -> some View {
        // Direct Peers section
        if !details.directPeers.isEmpty {
            relationshipSection(
                title: Copy.Inspector.directPeersSection,
                tooltip: Copy.Inspector.directPeersSectionTooltip,
                relationships: details.directPeers,
                icon: "arrow.left.arrow.right",
                iconColor: Color(nsColor: .systemGreen)
            )
        }

        // Heard Direct section
        if !details.heardDirect.isEmpty {
            relationshipSection(
                title: Copy.Inspector.heardDirectSection,
                tooltip: Copy.Inspector.heardDirectSectionTooltip,
                relationships: details.heardDirect,
                icon: "antenna.radiowaves.left.and.right",
                iconColor: Color(nsColor: .systemBlue)
            )
        }

        // Seen Via section
        if !details.seenVia.isEmpty {
            relationshipSection(
                title: Copy.Inspector.heardViaSection,
                tooltip: Copy.Inspector.heardViaSectionTooltip,
                relationships: details.seenVia,
                icon: "arrow.triangle.branch",
                iconColor: Color(nsColor: .systemOrange)
            )
        }

        // Show empty state if no relationships at all
        if details.directPeers.isEmpty && details.heardDirect.isEmpty && details.seenVia.isEmpty {
            Text(Copy.HubMetric.noNeighborsFound)
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .padding(.vertical, 4)
        }
    }

    private func relationshipSection(
        title: String,
        tooltip: String,
        relationships: [StationRelationship],
        icon: String,
        iconColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                Text("(\(relationships.count))")
                    .font(.caption2)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary.opacity(0.7))
            }
            .help(tooltip)

            ForEach(relationships.prefix(5)) { rel in
                relationshipRow(rel)
            }

            if relationships.count > 5 {
                Text("+ \(relationships.count - 5) more")
                    .font(.caption2)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary.opacity(0.7))
            }
        }
        .padding(.bottom, 8)
    }

    private func relationshipRow(_ rel: StationRelationship) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(rel.id)
                    .font(.caption)
                Spacer()
                Text("\(rel.packetCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            }

            // Show via digipeaters for heardVia relationships
            if rel.linkType == .heardVia && !rel.viaDigipeaters.isEmpty {
                Text(String(format: Copy.Inspector.viaDigipeaterTemplate, rel.viaDigipeaters.joined(separator: ", ")))
                    .font(.caption2)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary.opacity(0.7))
            }

            // Show last heard time if available
            if let lastHeard = rel.lastHeard {
                Text(String(format: Copy.Inspector.lastHeardTemplate, relativeTimeString(lastHeard)))
                    .font(.caption2)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary.opacity(0.7))
            }
        }
    }

    private func relativeTimeString(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }

    // MARK: - Grouped SSIDs

    private func groupedSSIDsSection(_ ssids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Copy.StationIdentity.inspectorGroupedHeader)
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .help(Copy.StationIdentity.inspectorGroupedTooltip)

            // Use a simple comma-separated list for compact display
            Text(ssids.joined(separator: ", "))
                .font(.caption2.monospaced())
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
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
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(tooltip)
    }
}

private struct AllSelectedStationsSheet: View {
    let nodes: [NetworkGraphNode]
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredNodes: [NetworkGraphNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nodes }
        return nodes.filter { $0.callsign.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Selected Stations")
                    .font(.headline)
                Spacer()
                Text("\(filteredNodes.count)/\(nodes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            }

            TextField("Filter callsigns", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredNodes) { node in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.callsign)
                                    .font(.body)
                                Text("In \(node.inCount.formatted()) • Out \(node.outCount.formatted())")
                                    .font(.caption)
                                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                            }
                            Spacer()
                            Text("Degree \(node.degree)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 620, maxWidth: 700, minHeight: 520, idealHeight: 640, maxHeight: 740)
        .onExitCommand { dismiss() }
    }
}

private struct InspectorMetricStringRow: View {
    let title: String
    let value: String
    let tooltip: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .monospacedDigit()
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .padding(.vertical, 2)
        .background(Color.clear)
        .contentShape(Rectangle())
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
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
                selectedMultiNodeDetails: nil,
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
                selectedMultiNodeDetails: nil,
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
                selectedMultiNodeDetails: nil,
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
                id: "W0ARP",
                callsign: "W0ARP",
                weight: 66,
                inCount: 0,
                outCount: 66,
                inBytes: 0,
                outBytes: 727,
                degree: 3,
                groupedSSIDs: ["W0ARP", "W0ARP-1", "W0ARP-10", "W0ARP-15"]  // Grouped SSIDs
            ),
            neighbors: [
                GraphNeighborStat(id: "N0XCR", weight: 44, bytes: 512, isStale: false),
                GraphNeighborStat(id: "KC0LDY", weight: 11, bytes: 128, isStale: false),
                GraphNeighborStat(id: "WB4CIW", weight: 11, bytes: 128, isStale: false)
            ],
            directPeers: [
                StationRelationship(id: "N0XCR", linkType: .directPeer, packetCount: 44, lastHeard: Date().addingTimeInterval(-300), viaDigipeaters: [], score: 1.0),
                StationRelationship(id: "KC0LDY", linkType: .directPeer, packetCount: 11, lastHeard: Date().addingTimeInterval(-600), viaDigipeaters: [], score: 1.0)
            ],
            heardDirect: [
                StationRelationship(id: "WB4CIW", linkType: .heardDirect, packetCount: 8, lastHeard: Date().addingTimeInterval(-120), viaDigipeaters: [], score: 0.75),
                StationRelationship(id: "K0EPI", linkType: .heardDirect, packetCount: 5, lastHeard: Date().addingTimeInterval(-900), viaDigipeaters: [], score: 0.45)
            ],
            seenVia: [
                StationRelationship(id: "DRL", linkType: .heardVia, packetCount: 15, lastHeard: Date().addingTimeInterval(-180), viaDigipeaters: ["K0NTS-7", "W0ARP-10"], score: 0),
                StationRelationship(id: "ANH", linkType: .heardVia, packetCount: 3, lastHeard: Date().addingTimeInterval(-3600), viaDigipeaters: ["DRL"], score: 0)
            ]
        )
    }
}
#endif
