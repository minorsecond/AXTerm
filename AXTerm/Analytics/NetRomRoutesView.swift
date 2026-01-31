//
//  NetRomRoutesView.swift
//  AXTerm
//
//  NET/ROM Routes page displaying neighbors, routes, and link quality metrics.
//  Apple HIG-compliant design with native table styling, tooltips, and export functionality.
//

import AppKit
import SwiftUI

/// Main view for the NET/ROM Routes page.
struct NetRomRoutesView: View {
    @StateObject private var viewModel: NetRomRoutesViewModel

    init(integration: NetRomIntegration?) {
        _viewModel = StateObject(wrappedValue: NetRomRoutesViewModel(integration: integration))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            routesToolbar

            Divider()

            // Content based on selected tab
            tabContent
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Toolbar

    private var routesToolbar: some View {
        HStack(spacing: 12) {
            // Tab picker
            Picker("View", selection: $viewModel.selectedTab) {
                ForEach(NetRomRoutesTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)

            Spacer()

            // Mode picker
            Picker("Mode", selection: $viewModel.routingMode) {
                Text("Classic").tag(NetRomRoutingMode.classic)
                Text("Inferred").tag(NetRomRoutingMode.inference)
                Text("Hybrid").tag(NetRomRoutingMode.hybrid)
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            .help("NET/ROM routing mode: Classic uses only explicit broadcasts, Inferred uses passive observation, Hybrid combines both")

            // Search field
            TextField("Search...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            // Refresh button
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh data")

            // Export menu
            Menu {
                switch viewModel.selectedTab {
                case .neighbors:
                    Button("Copy as JSON") { copyToClipboard(viewModel.copyNeighborsAsJSON()) }
                    Button("Copy as CSV") { copyToClipboard(viewModel.copyNeighborsAsCSV()) }
                case .routes:
                    Button("Copy as JSON") { copyToClipboard(viewModel.copyRoutesAsJSON()) }
                    Button("Copy as CSV") { copyToClipboard(viewModel.copyRoutesAsCSV()) }
                case .linkQuality:
                    Button("Copy as JSON") { copyToClipboard(viewModel.copyLinkStatsAsJSON()) }
                    Button("Copy as CSV") { copyToClipboard(viewModel.copyLinkStatsAsCSV()) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("Export data")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch viewModel.selectedTab {
        case .neighbors:
            neighborsTable
        case .routes:
            routesTable
        case .linkQuality:
            linkQualityTable
        }
    }

    // MARK: - Neighbors Table

    private var neighborsTable: some View {
        Group {
            if viewModel.filteredNeighbors.isEmpty {
                emptyState(
                    title: "No Neighbors",
                    message: "No neighbors have been discovered yet. Neighbors are stations heard directly without digipeaters."
                )
            } else {
                Table(viewModel.filteredNeighbors) {
                    TableColumn("Callsign") { neighbor in
                        Text(neighbor.callsign)
                            .fontWeight(.medium)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Quality") { neighbor in
                        QualityBadge(quality: neighbor.quality, percent: neighbor.qualityPercent)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Source") { neighbor in
                        SourceTypeBadge(sourceType: neighbor.sourceType)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Last Seen") { neighbor in
                        Text(neighbor.lastSeenRelative)
                            .foregroundStyle(.secondary)
                            .help("Last heard: \(neighbor.lastSeen.formatted())")
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Decay") { neighbor in
                        Text(neighbor.decayDisplayString)
                            .foregroundStyle(.secondary)
                            .help(NeighborDisplayInfo.decayTooltip)
                            .accessibilityLabel(neighbor.decayAccessibilityLabel)
                    }
                    .width(min: 40, ideal: 60)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Routes Table

    private var routesTable: some View {
        Group {
            if viewModel.filteredRoutes.isEmpty {
                emptyState(
                    title: "No Routes",
                    message: "No routes have been discovered yet. Routes are built from NET/ROM broadcasts or inferred from packet observations."
                )
            } else {
                Table(viewModel.filteredRoutes) {
                    TableColumn("Destination") { route in
                        Text(route.destination)
                            .fontWeight(.medium)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Next Hop") { route in
                        Text(route.nextHop)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Quality") { route in
                        QualityBadge(quality: route.quality, percent: route.qualityPercent)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Source") { route in
                        SourceTypeBadge(sourceType: route.sourceType)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Path") { route in
                        Text(route.pathSummary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help("Full path: \(route.pathSummary)")
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Hops") { route in
                        Text("\(route.hopCount)")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 40, ideal: 50)

                    TableColumn("Updated") { route in
                        Text(route.lastUpdatedRelative)
                            .foregroundStyle(.secondary)
                            .help("Last updated: \(route.lastUpdated.formatted())")
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Decay") { route in
                        Text(route.decayDisplayString)
                            .foregroundStyle(.secondary)
                            .help(RouteDisplayInfo.decayTooltip)
                            .accessibilityLabel(route.decayAccessibilityLabel)
                    }
                    .width(min: 40, ideal: 60)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Link Quality Table

    private var linkQualityTable: some View {
        Group {
            if viewModel.filteredLinkStats.isEmpty {
                emptyState(
                    title: "No Link Statistics",
                    message: "No link quality data has been collected yet. Link quality is estimated from packet observations using ETX-style metrics."
                )
            } else {
                Table(viewModel.filteredLinkStats) {
                    TableColumn("From") { stat in
                        Text(stat.fromCall)
                            .fontWeight(.medium)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("To") { stat in
                        Text(stat.toCall)
                            .fontWeight(.medium)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Quality") { stat in
                        QualityBadge(quality: stat.quality, percent: stat.qualityPercent)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("df") { stat in
                        if let df = stat.dfEstimate {
                            Text(String(format: "%.2f", df))
                                .foregroundStyle(.secondary)
                                .help("Forward delivery probability (0-1)")
                        } else {
                            Text("-")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("dr") { stat in
                        if let dr = stat.drEstimate {
                            Text(String(format: "%.2f", dr))
                                .foregroundStyle(.secondary)
                                .help("Reverse delivery probability (0-1)")
                        } else {
                            Text("-")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("ETX") { stat in
                        if let etx = stat.etx {
                            Text(String(format: "%.1f", etx))
                                .foregroundStyle(etx > 3 ? .orange : .secondary)
                                .help("Expected Transmission Count: lower is better (1.0 = perfect link)")
                        } else {
                            Text("-")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("Dups") { stat in
                        Text("\(stat.duplicateCount)")
                            .foregroundStyle(stat.duplicateCount > 5 ? .orange : .secondary)
                            .help("Duplicate/retry packets observed (high count may indicate retries)")
                    }
                    .width(min: 40, ideal: 50)

                    TableColumn("Updated") { stat in
                        Text(stat.lastUpdatedRelative)
                            .foregroundStyle(.secondary)
                            .help("Last updated: \(stat.lastUpdated.formatted())")
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Decay") { stat in
                        Text(stat.decayDisplayString)
                            .foregroundStyle(.secondary)
                            .help(LinkStatDisplayInfo.decayTooltip)
                            .accessibilityLabel(stat.decayAccessibilityLabel)
                    }
                    .width(min: 40, ideal: 60)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Empty State

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Supporting Views

/// Badge displaying quality value with color coding.
struct QualityBadge: View {
    let quality: Int
    let percent: Double

    private var color: Color {
        if percent >= 80 { return .green }
        if percent >= 50 { return .yellow }
        if percent >= 25 { return .orange }
        return .red
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(quality)")
                .fontWeight(.medium)
            Text("(\(Int(percent))%)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .help("Quality: \(quality)/255 (\(String(format: "%.1f", percent))%) - Higher is better")
    }
}

/// Badge displaying the source type (classic/inferred/broadcast).
struct SourceTypeBadge: View {
    let sourceType: String

    private var displayText: String {
        switch sourceType.lowercased() {
        case "classic": return "Classic"
        case "inferred": return "Inferred"
        case "broadcast": return "Broadcast"
        default: return sourceType.capitalized
        }
    }

    private var icon: String {
        switch sourceType.lowercased() {
        case "classic": return "radio"
        case "inferred": return "wand.and.stars"
        case "broadcast": return "megaphone"
        default: return "questionmark.circle"
        }
    }

    private var helpText: String {
        switch sourceType.lowercased() {
        case "classic":
            return "Classic: Discovered through direct RF observation"
        case "inferred":
            return "Inferred: Deduced from packet patterns without explicit announcement"
        case "broadcast":
            return "Broadcast: Received via NET/ROM routing broadcast"
        default:
            return "Source type: \(sourceType)"
        }
    }

    var body: some View {
        Label(displayText, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(helpText)
    }
}

// MARK: - Preview

#Preview {
    NetRomRoutesView(integration: nil)
        .frame(width: 900, height: 500)
}
