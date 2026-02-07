//
//  NetworkHealthView.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import SwiftUI

/// Network Health inspector view shown when no node is selected.
/// Displays health score, metrics, warnings, quick actions, and focus controls in a macOS-native style.
struct NetworkHealthView: View {
    let health: NetworkHealth
    let onFocusPrimaryHub: () -> Void
    let onShowActiveNodes: () -> Void
    let onExportSummary: () -> Void

    // Focus mode controls
    @Binding var focusState: GraphFocusState
    let onFitToSelection: () -> Void
    let onResetCamera: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            Divider()
            healthIndexSection
            if !health.reasons.isEmpty {
                reasonsSection
            }
            Divider()
            metricsGrid
            if !health.warnings.isEmpty {
                Divider()
                warningsSection
            }
            if !health.activityTrend.isEmpty {
                Divider()
                trendSection
            }
            Divider()
            focusControlsSection
            Spacer(minLength: 0)
            Divider()
            actionsSection
        }
        .padding(12)
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
    }

    @State private var showingScoreInfo = false

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            Text(GraphCopy.Health.headerLabel)
                .font(.headline)
                .help(GraphCopy.Health.headerTooltip)
            Spacer()
            Button(action: { showingScoreInfo.toggle() }) {
                Image(systemName: "info.circle")
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("How this score is calculated")
            .popover(isPresented: $showingScoreInfo, arrowEdge: .trailing) {
                ScoreExplainerView(
                    breakdown: health.scoreBreakdown,
                    finalScore: health.score,
                    timeframeDisplayName: health.timeframeDisplayName
                )
            }
        }
    }

    private var healthIndexSection: some View {
        HStack(alignment: .center, spacing: 12) {
            HealthGaugeView(score: health.score, rating: health.rating)
                .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text(health.rating.rawValue)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ratingColor(health.rating))
                    .contentTransition(.interpolate)
                    .animation(.easeInOut(duration: 0.3), value: health.rating)
                Text("\(health.score)/100")
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: health.score)
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
                        .foregroundStyle(Color(nsColor: .systemGreen).opacity(0.8))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                }
            }
        }
    }

    private var metricsGrid: some View {
        let tf = health.timeframeDisplayName

        return VStack(alignment: .leading, spacing: 8) {
            Text("Metrics")
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .help(GraphCopy.Health.headerTooltip)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 6) {
                // Topology metrics (canonical graph, timeframe-dependent)
                MetricCell(
                    label: GraphCopy.Health.stationsHeardLabelWithTimeframe(tf),
                    value: "\(health.metrics.totalStations)",
                    tooltip: GraphCopy.Health.stationsHeardTooltip(tf)
                )
                // Activity metrics (fixed 10-minute window)
                MetricCell(
                    label: GraphCopy.Health.activeStationsLabel,
                    value: "\(health.metrics.activeStations)",
                    tooltip: GraphCopy.Health.activeStationsTooltip
                )
                MetricCell(
                    label: GraphCopy.Health.mainClusterLabelWithTimeframe(tf),
                    value: formatPercent(health.metrics.largestComponentPercent),
                    tooltip: GraphCopy.Health.mainClusterTooltip(tf)
                )
                MetricCell(
                    label: GraphCopy.Health.packetRateLabel,
                    value: String(format: "%.1f", health.metrics.packetRate),
                    tooltip: GraphCopy.Health.packetRateTooltip
                )
                MetricCell(
                    label: GraphCopy.Health.connectivityRatioLabelWithTimeframe(tf),
                    value: formatPercent(health.metrics.connectivityRatio),
                    tooltip: GraphCopy.Health.connectivityRatioTooltip(tf)
                )
                MetricCell(
                    label: GraphCopy.Health.isolationReductionLabelWithTimeframe(tf),
                    value: formatPercent(health.metrics.isolationReduction),
                    tooltip: GraphCopy.Health.isolationReductionTooltip(tf)
                )
            }
        }
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attention")
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

            ForEach(health.warnings) { warning in
                WarningRow(warning: warning)
            }
        }
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(GraphCopy.Health.activityChartLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .help(GraphCopy.Health.activityChartTooltip)

            SparklineView(values: health.activityTrend)
                .frame(height: 32)
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 8) {
            Button(action: onFocusPrimaryHub) {
                HStack {
                    Image(systemName: "target")
                    Text("Focus Primary Hub")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(health.metrics.topRelayCallsign == nil)

            HStack(spacing: 8) {
                Button(action: onShowActiveNodes) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Active")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(health.metrics.activeStations == 0)

                Button(action: onExportSummary) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var focusControlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Graph Focus")
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

            // Focus mode toggle
            Toggle(isOn: $focusState.isFocusEnabled) {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                        .font(.caption)
                    Text("Focus Mode")
                        .font(.caption)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("When enabled, shows only nodes within k hops of the selected node")

            // K-hop stepper (only shown when focus is enabled)
            if focusState.isFocusEnabled {
                HStack {
                    Text("Max hops:")
                        .font(.caption)
                        .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    Spacer()
                    Stepper(
                        value: $focusState.maxHops,
                        in: GraphFocusState.hopRange
                    ) {
                        Text("\(focusState.maxHops)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 20, alignment: .trailing)
                    }
                    .controlSize(.small)
                }
                .help("Number of hops from selected node to include (1-6)")
            }

            // Hub metric picker
            HStack {
                Text("Hub metric:")
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                Spacer()
                Picker("", selection: $focusState.hubMetric) {
                    ForEach(HubMetric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 90)
            }
            .help("Metric used to identify the primary hub node")

            // Camera control buttons
            HStack(spacing: 8) {
                Button(action: onFitToSelection) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                        Text("Fit")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Fit camera to show selected nodes")

                Button(action: onResetCamera) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                        Text("Reset")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reset camera to show entire graph")
            }
        }
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
}

// MARK: - Supporting Views

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
                .animation(.easeOut(duration: 0.5), value: score)

            // Score text
            Text("\(score)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.5), value: score)
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

private struct MetricCell: View {
    let label: String
    let value: String
    var tooltip: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: value)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(tooltip)
    }
}

private struct WarningRow: View {
    let warning: NetworkWarning

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(warning.title)
                    .font(.caption.weight(.medium))
                Text(warning.detail)
                    .font(.caption2)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
    }

    private var iconName: String {
        switch warning.severity {
        case .info: return "info.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch warning.severity {
        case .info: return Color(nsColor: .systemBlue)
        case .caution: return Color(nsColor: .systemOrange)
        case .warning: return Color(nsColor: .systemRed)
        }
    }

    private var backgroundColor: Color {
        switch warning.severity {
        case .info: return Color(nsColor: .systemBlue).opacity(0.08)
        case .caution: return Color(nsColor: .systemOrange).opacity(0.08)
        case .warning: return Color(nsColor: .systemRed).opacity(0.08)
        }
    }
}

private struct SparklineView: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geometry in
            let maxValue = max(1, values.max() ?? 1)
            let width = geometry.size.width
            let height = geometry.size.height
            let stepX = width / CGFloat(max(1, values.count - 1))

            Path { path in
                guard !values.isEmpty else { return }
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = height - (CGFloat(value) / CGFloat(maxValue)) * height * 0.9
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(
                AnalyticsStyle.Colors.accent,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )

            // Fill area under curve
            Path { path in
                guard !values.isEmpty else { return }
                path.move(to: CGPoint(x: 0, y: height))
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = height - (CGFloat(value) / CGFloat(maxValue)) * height * 0.9
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: width, y: height))
                path.closeSubpath()
            }
            .fill(AnalyticsStyle.Colors.accent.opacity(0.15))
        }
        .animation(.easeInOut(duration: 0.4), value: values)
    }
}

/// Popover view explaining how the health score is calculated.
/// Used by GraphSidebar's Overview tab.
struct ScoreExplainerView: View {
    let breakdown: HealthScoreBreakdown
    let finalScore: Int
    var timeframeDisplayName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How this score is calculated")
                .font(.headline)

            // Explain the hybrid model
            VStack(alignment: .leading, spacing: 4) {
                Text("The health score uses a hybrid model:")
                    .font(.caption)
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

                HStack(spacing: 8) {
                    Label("40% Activity (10m)", systemImage: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .systemBlue))
                    Label(topologyLabel, systemImage: "network")
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(breakdown.components, id: \.name) { component in
                    HStack {
                        Circle()
                            .fill(component.isActivity ? Color(nsColor: .systemBlue) : Color(nsColor: .systemGreen))
                            .frame(width: 6, height: 6)
                        Text(component.name)
                            .font(.caption.weight(.medium))
                            .frame(width: 130, alignment: .leading)
                        Text("\(Int(component.weight))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                            .frame(width: 30, alignment: .trailing)
                        ProgressView(value: component.score / 100)
                            .progressViewStyle(.linear)
                            .frame(width: 50)
                        Text("\(Int(component.score))")
                            .font(.caption.monospacedDigit())
                            .frame(width: 25, alignment: .trailing)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Formula")
                    .font(.caption.weight(.medium))
                Text(breakdown.formulaDescription)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }

            HStack {
                Text("Final Score:")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(finalScore)/100")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .padding(.top, 4)

            Text(GraphCopy.Health.scoreExperimentalNote)
                .font(.caption2)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                .italic()
        }
        .padding(12)
        .frame(width: 320)
    }

    private var topologyLabel: String {
        let tf = timeframeDisplayName.isEmpty ? "timeframe" : timeframeDisplayName
        return "60% Topology (\(tf))"
    }
}

// MARK: - Preview

#if DEBUG
struct NetworkHealthView_Previews: PreviewProvider {
    static var previews: some View {
        NetworkHealthView(
            health: NetworkHealth(
                score: 72,
                rating: .good,
                reasons: [
                    "Well-connected network (24h)",
                    "8 stations active (10m)",
                    "Healthy traffic (1.2/min)"
                ],
                metrics: NetworkHealthMetrics(
                    // Topology metrics (canonical graph, timeframe-dependent)
                    totalStations: 15,
                    totalPackets: 234,
                    largestComponentPercent: 85,
                    connectivityRatio: 12.4,
                    isolationReduction: 93.3,
                    isolatedNodes: 1,
                    topRelayCallsign: "W5ABC-10",
                    topRelayConcentration: 35,
                    // Activity metrics (fixed 10-minute window)
                    activeStations: 8,
                    packetRate: 1.2,
                    freshness: 0.53
                ),
                warnings: [
                    NetworkWarning(
                        id: "isolated",
                        severity: .info,
                        title: "Isolated stations (24h)",
                        detail: "1 station with no connections"
                    )
                ],
                activityTrend: [2, 5, 3, 8, 12, 7, 4, 6, 9, 11, 8, 5],
                scoreBreakdown: HealthScoreBreakdown(
                    c1MainClusterPct: 85, c2ConnectivityPct: 12.4, c3IsolationReduction: 93.3, topologyScore: 49.7,
                    a1ActiveNodesPct: 53.3, a2PacketRateScore: 100, packetRatePerMin: 1.2, activityScore: 72,
                    totalNodes: 15, activeNodes10m: 8, isolatedNodes: 1, finalScore: 72
                ),
                timeframeDisplayName: "24h"
            ),
            onFocusPrimaryHub: {},
            onShowActiveNodes: {},
            onExportSummary: {},
            focusState: .constant(GraphFocusState()),
            onFitToSelection: {},
            onResetCamera: {}
        )
        .frame(width: 260, height: 700)
        .padding()
    }
}
#endif
