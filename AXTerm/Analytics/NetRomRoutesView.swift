//
//  NetRomRoutesView.swift
//  AXTerm
//
//  NET/ROM Routes page displaying neighbors, routes, and link quality metrics.
//  Apple HIG-compliant design with native table styling, tooltips, and export functionality.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Main view for the NET/ROM Routes page.
struct NetRomRoutesView: View {
    @StateObject private var viewModel: NetRomRoutesViewModel
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var connectCoordinator: ConnectCoordinator
    private weak var packetEngine: PacketEngine?

    @State private var showingClearConfirmation = false
    @State private var clearFeedback: String?

    init(
        integration: NetRomIntegration?,
        packetEngine: PacketEngine? = nil,
        settings: AppSettingsStore,
        connectCoordinator: ConnectCoordinator
    ) {
        self.settings = settings
        self.packetEngine = packetEngine
        self.connectCoordinator = connectCoordinator
        _viewModel = StateObject(wrappedValue: NetRomRoutesViewModel(integration: integration, packetEngine: packetEngine, settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            //
            // Scrolled sideways on a handheld. The controls carry fixed widths
            // sized for a Mac window (340 + 160 + 180 plus a toggle and four
            // buttons), and an HStack cannot shrink below its content — so on
            // an 834pt iPad it forced the whole VStack wider than the screen
            // and dragged the table's leftmost column, the callsign, off the
            // edge with it. Scrolling keeps every control reachable instead of
            // silently clipping the one that matters most.
            #if os(iOS)
            ScrollView(.horizontal, showsIndicators: false) {
                routesToolbar
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #else
            routesToolbar
            #endif

            Divider()

            // Content based on selected tab
            tabContent
        }
        .background(Color(platform: .platformWindowBackground))
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
                switch viewModel.selectedTab {
                case .routes:
                    Text("Classic Routes").tag(NetRomRoutingMode.classic)
                    Text("Inferred Routes").tag(NetRomRoutingMode.inference)
                    Text("All Routes").tag(NetRomRoutingMode.hybrid)
                case .neighbors:
                    Text("Classic Neighbors").tag(NetRomRoutingMode.classic)
                    Text("Inferred Neighbors").tag(NetRomRoutingMode.inference)
                    Text("All Neighbors").tag(NetRomRoutingMode.hybrid)
                case .linkQuality:
                    Text("Classic Links").tag(NetRomRoutingMode.classic)
                    Text("Inferred Links").tag(NetRomRoutingMode.inference)
                    Text("All Links").tag(NetRomRoutingMode.hybrid)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
            .help(modePickerTooltip)

            // Hide expired toggle
            Toggle("Hide expired", isOn: $settings.hideExpiredRoutes)
                .platformCheckboxToggle()
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

#if os(iOS)
    // MARK: - Touch presentations

    /// Routes as stacked rows.
    ///
    /// Nine side-by-side columns fit a 900pt Mac window and not an 834pt
    /// iPad, where the destination callsign — the field the whole view exists
    /// for — truncated to `KB5YZB…` while `Hops` kept a column to itself.
    ///
    /// Tooltips move to `.explain()`: `.help()` renders nothing on iOS, so
    /// every derivation CLAUDE.md requires was silently absent here.
    private var routesTouchList: some View {
        List(viewModel.filteredRoutes) { route in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(NetRomTouchRow.headline(
                        destination: route.destination, nextHop: route.nextHop))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    QualityBadge(quality: route.quality, percent: route.qualityPercent)
                }

                if NetRomTouchRow.shouldShowPath(route.pathSummary, nextHop: route.nextHop) {
                    Text(route.pathSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .explain("Connect path: \(route.pathSummary)", showsIndicator: false)
                }

                HStack(spacing: 6) {
                    SourceTypeBadge(sourceType: route.sourceType)
                    Text(NetRomTouchRow.detail(
                        hops: route.hopCountKnown ? route.hopCount : nil,
                        updated: route.lastUpdatedRelative,
                        freshness: route.freshnessDisplayString))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .explain(RouteDisplayInfo.freshnessTooltip, showsIndicator: false)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Connect (NET/ROM)") { requestRouteConnect(route, action: .netrom) }
                Button("Connect Direct (AX.25)") { requestRouteConnect(route, action: .ax25Direct) }
                Button("Connect via Digi (AX.25)") { requestRouteConnect(route, action: .ax25ViaDigi) }
            }
        }
        .listStyle(.plain)
    }

    /// Link quality as stacked rows.
    ///
    /// df, dr, ETX and dups are the metrics CLAUDE.md requires an explanation
    /// for, and at 50pt per column on a handheld they were unreadable even
    /// where they rendered. A dash means *no observation yet*, which is not
    /// the same claim as a measured zero.
    private var linkQualityTouchList: some View {
        List(viewModel.filteredLinkStats) { stat in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(NetRomTouchRow.headline(destination: stat.fromCall, nextHop: stat.toCall))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    QualityBadge(quality: stat.quality, percent: stat.qualityPercent,
                                 detailTooltip: stat.qualityTooltip)
                }

                HStack(spacing: 10) {
                    metricLabel("df", NetRomTouchRow.metric(stat.dfEstimate, decimals: 2))
                        .explain("Forward delivery probability (0–1): how often a frame sent this way arrives.")
                    metricLabel("dr", NetRomTouchRow.metric(stat.drEstimate, decimals: 2))
                        .explain("Reverse delivery probability (0–1): how often the reply comes back.")
                    metricLabel("ETX", NetRomTouchRow.metric(stat.etx, decimals: 1))
                        .explain("Expected transmissions per delivered frame. 1.0 is a perfect link; above 3 is poor.")
                    metricLabel("dups", "\(stat.duplicateCount)")
                        .explain("Duplicate or retried frames observed. A high count usually means retries.")
                }
                .font(.caption2)

                Text(NetRomTouchRow.detail(
                    hops: nil, updated: stat.lastUpdatedRelative,
                    freshness: stat.freshnessDisplayString))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .explain(LinkStatDisplayInfo.freshnessTooltip, showsIndicator: false)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NetRomTouchRow.spokenLink(
                from: stat.fromCall, to: stat.toCall,
                df: stat.dfEstimate, dr: stat.drEstimate))
        }
        .listStyle(.plain)
    }

    /// A metric and its name, so a bare number is never on its own.
    private func metricLabel(_ name: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(name).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
#endif

    // MARK: - Actions

    private var modePickerTooltip: String {
        switch viewModel.selectedTab {
        case .routes:
            return "Filter routes: Classic (from explicit NET/ROM broadcasts), Inferred (deduced from packet observation), or All"
        case .neighbors:
            return "Filter neighbors: Classic (heard directly), Inferred (deduced from traffic), or All"
        case .linkQuality:
            return "Filter link quality stats by the type of neighbor they involve (Classic vs Inferred)"
        }
    }

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
                            .onTapGesture(count: 2) {
                                requestNeighborConnect(neighbor)
                            }
                            .contextMenu {
                                Button("Connect (AX.25)") {
                                    requestNeighborConnect(neighbor)
                                }
                            }
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
                .platformInsetTable()
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
                #if os(iOS)
                routesTouchList
                #else
                Table(viewModel.filteredRoutes) {
                    TableColumn("Destination") { route in
                        Text(route.destination)
                            .fontWeight(.medium)
                            .onTapGesture(count: 2) {
                                requestRouteConnect(route, action: .netrom)
                            }
                            .contextMenu {
                                Button("Connect (NET/ROM)") {
                                    requestRouteConnect(route, action: .netrom)
                                }
                                .help("Connects to the next-hop node and drives its "
                                      + "command prompt — the proven path on this network.")
                                Button("Connect Direct (AX.25)") {
                                    requestRouteConnect(route, action: .ax25Direct)
                                }
                                Button("Connect via Digi (AX.25)") {
                                    requestRouteConnect(route, action: .ax25ViaDigi)
                                }
                                Divider()
                                Button("Open NET/ROM Circuit (native)") {
                                    openNativeCircuit(to: route.destination)
                                }
                                Button("Auto-try Every Known Route") {
                                    autoTryCircuit(to: route.destination)
                                }
                                .help("Opens a NET/ROM circuit through the best route, and "
                                      + "if that one goes unanswered, tries the next-best "
                                      + "automatically. A station that answers 'no' ends it.")
                                .help("Speaks the NET/ROM transport itself — one connect "
                                      + "request the network routes, instead of typing at a "
                                      + "node's prompt. New; not yet proven against these nodes.")
                            }
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
                        Text(route.hopCountKnown ? "\(route.hopCount)" : "—")
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
                .platformInsetTable()
                #endif
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
                #if os(iOS)
                linkQualityTouchList
                #else
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
                        QualityBadge(quality: stat.quality, percent: stat.qualityPercent, detailTooltip: stat.qualityTooltip)
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
                .platformInsetTable()
                #endif
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
        ClipboardWriter.copy(text)
    }

    private func requestNeighborConnect(_ neighbor: NeighborDisplayInfo) {
        connectCoordinator.activeContext = .neighbors
        let intent = ConnectIntent(
            kind: .ax25Direct,
            to: neighbor.callsign,
            sourceContext: .neighbors,
            suggestedRoutePreview: nil,
            validationErrors: [],
            routeHint: nil,
            note: nil
        )
        connectCoordinator.requestConnect(
            ConnectRequest(intent: intent, mode: .ax25, executeImmediately: true)
        )
    }

    /// Open a native NET/ROM circuit. Distinct from `requestRouteConnect`
    /// with `.netrom`, which drives a node's *command prompt* — this
    /// speaks the transport nodes speak to each other, and the network
    /// does the routing. See Docs/NetRomTransport.md.
    private func openNativeCircuit(to destination: String) {
        guard let coordinator = SessionCoordinator.shared else { return }
        let target = CallsignNormalizer.toAddress(destination)
        if case let .failure(reason) = coordinator.netRomDriver.openCircuit(to: target) {
            coordinator.packetEngine?.appendSystemNotification(reason.operatorText)
        }
    }

    /// Walk every known route to a destination until one comes up.
    private func autoTryCircuit(to destination: String) {
        guard let coordinator = SessionCoordinator.shared else { return }
        let target = CallsignNormalizer.toAddress(destination)
        if case let .failure(reason) = coordinator.netRomDriver.autoConnect(to: target) {
            coordinator.packetEngine?.appendSystemNotification(reason.operatorText)
        }
    }

    private func requestRouteConnect(_ route: RouteDisplayInfo, action: RouteConnectAction) {
        connectCoordinator.activeContext = .routes
        switch action {
        case .netrom:
            let hint = NetRomRouteHint(
                nextHop: route.nextHop,
                heardAs: route.heardPath.first,
                path: route.path,
                hops: route.hopCount
            )
            let intent = ConnectIntent(
                kind: .netrom(nextHopOverride: nil),
                to: route.destination,
                sourceContext: .routes,
                suggestedRoutePreview: route.hopCountKnown
                    ? "\(route.pathSummary) (\(route.hopCount) hops)"
                    : route.pathSummary,
                validationErrors: [],
                routeHint: hint,
                note: nil
            )
            connectCoordinator.requestConnect(
                ConnectRequest(intent: intent, mode: .netrom, executeImmediately: true)
            )
        case .ax25Direct:
            let target = ConnectPrefillLogic.ax25DirectTarget(
                destination: route.destination,
                heardAs: route.heardPath.first
            )
            let intent = ConnectIntent(
                kind: .ax25Direct,
                to: target.to,
                sourceContext: .routes,
                suggestedRoutePreview: nil,
                validationErrors: [],
                routeHint: nil,
                note: target.note
            )
            connectCoordinator.requestConnect(
                ConnectRequest(intent: intent, mode: .ax25, executeImmediately: true)
            )
        case .ax25ViaDigi:
            let digis = route.heardPath.compactMap { Callsign($0) }
            let intent = ConnectIntent(
                kind: .ax25ViaDigis(digis),
                to: route.destination,
                sourceContext: .routes,
                suggestedRoutePreview: nil,
                validationErrors: [],
                routeHint: nil,
                note: nil
            )
            connectCoordinator.requestConnect(
                ConnectRequest(intent: intent, mode: .ax25ViaDigi, executeImmediately: true)
            )
        }
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
    var detailTooltip: String? = nil

    private var color: Color {
        if percent >= 80 { return .green }
        if percent >= 50 { return .yellow }
        if percent >= 25 { return .orange }
        return .red
    }

    private var roundedPercent: Int { Int(percent.rounded()) }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(quality)")
                .fontWeight(.medium)
            Text("(\(roundedPercent)%)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .help(detailTooltip ?? "Quality estimates how reliably packets travel in each direction. Lower values indicate retries or weak acknowledgement evidence.")
        .accessibilityLabel("Quality \(quality) of 255, \(roundedPercent) percent.")
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
        case "harvested": return "Harvested"
        default: return sourceType.capitalized
        }
    }

    private var icon: String {
        switch sourceType.lowercased() {
        case "classic": return "radio"
        case "inferred": return "wand.and.stars"
        case "broadcast": return "megaphone"
        case "harvested": return "tray.and.arrow.down"
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
        case "harvested":
            return "Harvested: Read from a node's own ROUTES table during a session. Second-hand — used for this station's routing, never advertised."
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
    NetRomRoutesView(
        integration: nil,
        packetEngine: nil,
        settings: AppSettingsStore(),
        connectCoordinator: ConnectCoordinator()
    )
        .frame(width: 900, height: 500)
}
