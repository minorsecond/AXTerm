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
    @ObservedObject var settings: AppSettingsStore
    private weak var packetEngine: PacketEngine?

    @State private var showingClearConfirmation = false
    @State private var clearFeedback: String?

    init(integration: NetRomIntegration?, packetEngine: PacketEngine? = nil, settings: AppSettingsStore) {
        self.settings = settings
        self.packetEngine = packetEngine
        _viewModel = StateObject(wrappedValue: NetRomRoutesViewModel(integration: integration, packetEngine: packetEngine, settings: settings))
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
        .confirmationDialog(
            "Clear all NET/ROM routing data?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Routes", role: .destructive) {
                clearRoutes()
            }
        } message: {
            Text("This removes all neighbors, routes, and link quality data. New data will be collected as packets arrive.")
        }
    }

    // MARK: - Toolbar

    private var routesToolbar: some View {
        HStack(spacing: 12) {
            // Tab picker
            NativeSegmentedPicker(
                selection: $viewModel.selectedTab,
                items: Array(RoutesScope.allCases),
                title: { $0.title },
                tooltip: { $0.tooltip },
                accessibilityLabel: "Routes View"
            )
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

            // Hide expired toggle
            Toggle("Hide expired", isOn: $settings.hideExpiredRoutes)
                .toggleStyle(.checkbox)
                .help("When enabled, hides entries with 0% freshness (older than TTL)")

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

            // Clear button
            Button {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear all routing data")

            // Clear feedback
            if let feedback = clearFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            // Debug rebuild button
            debugRebuildButton
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func clearRoutes() {
        packetEngine?.clearNetRomData()
        clearFeedback = "Cleared"
        viewModel.refresh()

        // Auto-dismiss feedback after 2 seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            clearFeedback = nil
        }
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

                    TableColumn("Freshness") { neighbor in
                        Text(neighbor.freshnessDisplayString)
                            .foregroundColor(neighbor.freshnessColor)
                            .help(NeighborDisplayInfo.freshnessTooltip)
                            .accessibilityLabel(neighbor.freshnessAccessibilityLabel)
                    }
                    .width(min: 50, ideal: 70)
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
                            .help("Connect path: \(route.pathSummary)")
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Heard As") { route in
                        Text(route.heardPathSummary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.tertiary)
                            .help(route.heardPathTooltip)
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

                    TableColumn("Freshness") { route in
                        Text(route.freshnessDisplayString)
                            .foregroundColor(route.freshnessColor)
                            .help(RouteDisplayInfo.freshnessTooltip)
                            .accessibilityLabel(route.freshnessAccessibilityLabel)
                    }
                    .width(min: 50, ideal: 70)
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

                    TableColumn("Freshness") { stat in
                        Text(stat.freshnessDisplayString)
                            .foregroundColor(stat.freshnessColor)
                            .help(LinkStatDisplayInfo.freshnessTooltip)
                            .accessibilityLabel(stat.freshnessAccessibilityLabel)
                    }
                    .width(min: 50, ideal: 70)
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

    // MARK: - Debug Rebuild

    #if DEBUG
    @State private var showRebuildResult = false

    @ViewBuilder
    private var debugRebuildButton: some View {
        if viewModel.isRebuilding {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("\(Int(viewModel.rebuildProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 80)
        } else {
            Button {
                viewModel.debugRebuildFromPackets()
            } label: {
                Label("Rebuild", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canRebuild)
            .help("DEBUG: Rebuild all NET/ROM data from packets database")
            .onChange(of: viewModel.lastRebuildResult) { _, newValue in
                if newValue != nil {
                    showRebuildResult = true
                    // Auto-dismiss after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        showRebuildResult = false
                    }
                }
            }
            .popover(isPresented: $showRebuildResult) {
                if let result = viewModel.lastRebuildResult {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rebuild Result")
                            .font(.headline)
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("(auto-dismisses in 5s)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .frame(width: 260)
                }
            }
        }
    }
    #endif
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
        .help("Quality estimates how reliably packets travel in each direction. Lower values indicate retries or weak acknowledgement evidence.")
        .accessibilityLabel("Quality \(quality) of 255, \(Int(percent)) percent.")
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
    NetRomRoutesView(integration: nil, packetEngine: nil, settings: AppSettingsStore())
        .frame(width: 900, height: 500)
}
