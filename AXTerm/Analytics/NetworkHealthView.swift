//
//  NetworkHealthView.swift
//  AXTerm
//
//  Score explainer popover for the Network Health panel.
//  The panel itself is rendered by GraphSidebar's Overview tab; the standalone
//  NetworkHealthView that used to live here was an unreferenced duplicate that
//  had already drifted from the shipping UI, so it was removed.
//

import SwiftUI

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
                        .foregroundStyle(Color(platform: .systemBlue))
                        .help(GraphCopy.ScoreBreakdown.activityTooltip)
                    Label(topologyLabel, systemImage: "network")
                        .font(.caption2)
                        .foregroundStyle(Color(platform: .systemGreen))
                        .help(GraphCopy.ScoreBreakdown.topologyTooltip)
                }
                .contentShape(Rectangle())
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(breakdown.components, id: \.name) { component in
                    HStack {
                        Circle()
                            .fill(component.isActivity ? Color(platform: .systemBlue) : Color(platform: .systemGreen))
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
                        Text(formattedComponentScore(component.score))
                            .font(.caption.monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .help(tooltip(for: component.name))
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
                    .help(GraphCopy.ScoreBreakdown.headerTooltip)
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

    private func tooltip(for componentName: String) -> String {
        switch componentName {
        case "Main Cluster (TF)":
            return GraphCopy.ScoreBreakdown.c1MainClusterTooltip
        case "Connectivity (TF)":
            return GraphCopy.ScoreBreakdown.c2ConnectivityTooltip
        case "Isolation Reduction (TF)":
            return GraphCopy.ScoreBreakdown.c3IsolationTooltip
        case "Active Nodes (10m)":
            return GraphCopy.ScoreBreakdown.a1ActiveNodesTooltip
        case "Packet Rate (10m)":
            return GraphCopy.ScoreBreakdown.a2PacketRateTooltip
        default:
            return GraphCopy.ScoreBreakdown.headerTooltip
        }
    }

    private func formattedComponentScore(_ value: Double) -> String {
        if value >= 10 {
            return "\(Int(value.rounded()))"
        } else if value >= 1 {
            return String(format: "%.1f", value)
        } else if value > 0 {
            return String(format: "%.2f", value)
        } else {
            return "0"
        }
    }
}
