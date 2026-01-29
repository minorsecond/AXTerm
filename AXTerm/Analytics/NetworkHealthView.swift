//
//  NetworkHealthView.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import SwiftUI

/// Network Health inspector view shown when no node is selected.
/// Displays health score, metrics, warnings, and quick actions in a macOS-native style.
struct NetworkHealthView: View {
    let health: NetworkHealth
    let onFocusPrimaryHub: () -> Void
    let onShowActiveNodes: () -> Void
    let onExportSummary: () -> Void

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
            Text("Network Health")
                .font(.headline)
            Spacer()
            Button(action: { showingScoreInfo.toggle() }) {
                Image(systemName: "info.circle")
                    .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("How this score is calculated")
            .popover(isPresented: $showingScoreInfo, arrowEdge: .trailing) {
                ScoreExplainerView(breakdown: health.scoreBreakdown, finalScore: health.score)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Metrics")
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 6) {
                MetricCell(
                    label: "Stations heard",
                    value: "\(health.metrics.totalStations)",
                    tooltip: "Total unique amateur radio stations observed in the current timeframe."
                )
                MetricCell(
                    label: "Active (10m)",
                    value: "\(health.metrics.activeStations)",
                    tooltip: "Stations that have transmitted or been addressed in the last 10 minutes."
                )
                MetricCell(
                    label: "Total packets",
                    value: formatNumber(health.metrics.totalPackets),
                    tooltip: "Total AX.25 frames received during this session."
                )
                MetricCell(
                    label: "Packets/min",
                    value: String(format: "%.1f", health.metrics.packetRate),
                    tooltip: "Rolling average packet rate over the last 10 minutes."
                )
                MetricCell(
                    label: "Main cluster",
                    value: "\(Int(health.metrics.largestComponentPercent))%",
                    tooltip: "Percentage of stations in the largest connected component. Higher values indicate a well-connected network."
                )
                MetricCell(
                    label: "Top relay share",
                    value: "\(Int(health.metrics.topRelayConcentration))%",
                    tooltip: "Percentage of connections involving the most-connected station. High values may indicate single-point dependency."
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
            Text("Activity (last hour)")
                .font(.caption.weight(.medium))
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

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
private struct ScoreExplainerView: View {
    let breakdown: HealthScoreBreakdown
    let finalScore: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How this score is calculated")
                .font(.headline)

            Text("The Network Health score is a weighted combination of five metrics:")
                .font(.caption)
                .foregroundStyle(AnalyticsStyle.Colors.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(breakdown.components, id: \.name) { component in
                    HStack {
                        Text(component.name)
                            .font(.caption.weight(.medium))
                            .frame(width: 80, alignment: .leading)
                        Text("\(Int(component.weight))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AnalyticsStyle.Colors.textSecondary)
                            .frame(width: 30, alignment: .trailing)
                        ProgressView(value: component.score / 100)
                            .progressViewStyle(.linear)
                            .frame(width: 60)
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
            }

            HStack {
                Text("Final Score:")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(finalScore)/100")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 300)
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
                    "Healthy packet activity (1.2/min)",
                    "8 stations active recently",
                    "Well-connected network"
                ],
                metrics: NetworkHealthMetrics(
                    totalStations: 15,
                    activeStations: 8,
                    totalPackets: 234,
                    packetRate: 1.2,
                    largestComponentPercent: 85,
                    topRelayConcentration: 35,
                    topRelayCallsign: "W5ABC-10",
                    freshness: 0.53,
                    isolatedNodes: 1
                ),
                warnings: [
                    NetworkWarning(
                        id: "isolated",
                        severity: .info,
                        title: "Isolated stations",
                        detail: "1 station with no connections"
                    )
                ],
                activityTrend: [2, 5, 3, 8, 12, 7, 4, 6, 9, 11, 8, 5],
                scoreBreakdown: HealthScoreBreakdown(
                    activityScore: 85, activityWeight: 25,
                    freshnessScore: 53, freshnessWeight: 20,
                    connectivityScore: 85, connectivityWeight: 25,
                    redundancyScore: 70, redundancyWeight: 20,
                    stabilityScore: 100, stabilityWeight: 10
                )
            ),
            onFocusPrimaryHub: {},
            onShowActiveNodes: {},
            onExportSummary: {}
        )
        .frame(width: 260, height: 600)
        .padding()
    }
}
#endif
