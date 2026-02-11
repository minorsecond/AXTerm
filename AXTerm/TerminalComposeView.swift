//
//  TerminalComposeView.swift
//  AXTerm
//
//  Terminal TX compose view with message input and queue status.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.5
//

import SwiftUI

struct AutoPathSuggestionItem: Identifiable, Hashable {
    let id: String
    let pathInput: String
    let pathDisplay: String
    let quality: Int
    let freshnessPercent: Int
    let hops: Int
    let sourceLabel: String
}

// MARK: - Connection Mode Toggle

/// A Mac-native toggle for switching between datagram and connected modes
struct ConnectionModeToggle: View {
    @Binding var mode: TxConnectionMode
    let sessionState: AX25SessionState?
    let onDisconnect: () -> Void
    let onForceDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Datagram mode button
            Button {
                mode = .datagram
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11))
                    Text("Broadcast")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(mode == .datagram ? Color.accentColor : Color.clear)
                .foregroundStyle(mode == .datagram ? .white : .primary)
            }
            .buttonStyle(.plain)

            // Connected mode button
            Button {
                mode = .connected
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                    Text("Session")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(mode == .connected ? Color.accentColor : Color.clear)
                .foregroundStyle(mode == .connected ? .white : .primary)
            }
            .buttonStyle(.plain)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help(mode.description)
    }
}

// MARK: - Session Status Badge

/// Shows current session state with visual indicator and optional AXDP status
struct SessionStatusBadge: View {
    let state: AX25SessionState?
    let destinationCall: String
    let onDisconnect: () -> Void
    let onForceDisconnect: () -> Void
    /// Optional AXDP capability for the remote station
    var peerCapability: AXDPCapability?
    /// AXDP capability negotiation status for this peer
    var capabilityStatus: SessionCoordinator.CapabilityStatus = .unknown

    var body: some View {
        HStack(spacing: 0) {
            // Status Capsule
            HStack(spacing: 6) {
                // Status indicator dot
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)

                // Status text
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(stateColor == .green ? .primary : .secondary)

                // AXDP negotiation / capability indicators (connected sessions only)
                if state == .connected {
                    switch capabilityStatus {
                    case .pending:
                        // Subtle spinner-style indicator while negotiating
                        ProgressView()
                            .scaleEffect(0.5)
                            .controlSize(.mini)
                            .help(axdpStatusHelp)
                    case .confirmed:
                         // Simple dot to indicate AXDP active (details in Adaptive chip or tooltip)
                        Circle()
                            .fill(.blue)
                            .frame(width: 4, height: 4)
                            .help(axdpStatusHelp)
                    case .notSupported, .unknown:
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stateBackgroundColor)
            
            // Integrated Action Button (Disconnect/Cancel)
            if shouldShowAction {
                Divider()
                    .frame(height: 12)
                
                Button {
                    if state == .connected {
                        onDisconnect()
                    } else {
                        onForceDisconnect()
                    }
                } label: {
                    Image(systemName: actionIcon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .help(actionHelp)
                .contextMenu {
                    if state == .connected {
                        Button("Disconnect Immediately", role: .destructive) {
                            onForceDisconnect()
                        }
                    }
                }
            }
        }
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
        .fixedSize()
        .help(stateHelp)
        .animation(.snappy, value: state)
    }

    private var stateBackgroundColor: Color {
        switch state {
        case .connected: return Color.green.opacity(0.05)
        case .connecting, .disconnecting: return Color.orange.opacity(0.05)
        case .error: return Color.red.opacity(0.05)
        default: return .clear
        }
    }

    private var stateColor: Color {
        switch state {
        case .disconnected, nil: return .secondary
        case .connecting, .disconnecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }
    
    private var statusLabel: String {
        switch state {
        case .disconnected, nil:
            return "Not Connected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return destinationCall.isEmpty ? "Connected" : "Connected to \(destinationCall)"
        case .disconnecting:
            return "Disconnecting..."
        case .error:
            return "Error"
        }
    }
    
    private var shouldShowAction: Bool {
        state == .connected || state == .connecting || state == .disconnecting
    }
    
    private var actionIcon: String {
        switch state {
        case .connected: return "xmark"
        case .connecting, .disconnecting: return "stop.fill"
        default: return ""
        }
    }
    
    private var actionHelp: String {
        switch state {
        case .connected: return "Disconnect"
        case .connecting, .disconnecting: return "Stop immediately"
        default: return ""
        }
    }

    private var stateHelp: String {
        switch state {
        case .disconnected, nil:
            return "No active session"
        case .connecting:
            return "Sending SABM, waiting for UA..."
        case .connected:
            return "Session active with \(destinationCall)"
        case .disconnecting:
            return "Sending DISC, waiting for UA..."
        case .error:
            return "Session error - try reconnecting"
        }
    }

    private var axdpStatusHelp: String {
        switch capabilityStatus {
        case .unknown:
            return "AXDP negotiation has not started for this peer."
        case .pending:
            return "Negotiating AXDP capabilities… waiting for PONG reply."
        case .confirmed:
            if let caps = peerCapability {
                return "AXDP enabled: v\(caps.protoMin)-\(caps.protoMax)."
            } else {
                return "AXDP enabled for this peer."
            }
        case .notSupported:
            return "AXDP not supported."
        }
    }
}

private struct AdaptiveTelemetryChip: View {
    let telemetry: AdaptiveTelemetry?
    @State private var showDetails = false

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 10))
                Text("Adaptive")
                    .font(.system(size: 10, weight: .semibold))
                if let telemetry {
                    Text(telemetry.compactLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.12), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.green.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Adaptive Link Telemetry")
                    .font(.headline)
                if let telemetry {
                    Group {
                        Text("Window (K): \(telemetry.k)")
                        Text("Packet (P): \(telemetry.p)")
                        Text("Retries (N2): \(telemetry.n2)")
                        Text("RTO min: \(String(format: "%.1fs", telemetry.rtoSeconds))")
                        Text("Status: \(telemetry.qualityLabel)")
                    }
                    .font(.system(size: 11))
                } else {
                    Text("No adaptive telemetry available.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(minWidth: 240)
        }
    }
}

private struct RoutingCapsuleButton: View {
    @ObservedObject var viewModel: ConnectBarViewModel
    let onAutoConnect: () -> Void
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(summaryText)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            RoutingPopoverContent(
                viewModel: viewModel,
                onAutoConnect: onAutoConnect
            )
        }
    }

    private var summaryText: String {
        switch viewModel.mode {
        case .ax25:
            return "Routing: AX.25 Direct"
        case .ax25ViaDigi:
            if viewModel.viaDigipeaters.isEmpty {
                return "Routing: AX.25 via Digi (Direct)"
            }
            let compactPath = viewModel.viaDigipeaters.prefix(2).joined(separator: " → ")
            return "Routing: AX.25 via Digi (\(compactPath))"
        case .netrom:
            if viewModel.nextHopSelection == ConnectBarViewModel.autoNextHopID {
                return "Routing: NET/ROM (Auto)"
            }
            return "Routing: NET/ROM (Next Hop: \(viewModel.nextHopSelection))"
        }
    }
}

private struct RoutingPopoverContent: View {
    @ObservedObject var viewModel: ConnectBarViewModel
    let onAutoConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Protocol")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Protocol", selection: modeBinding) {
                    Text("AX.25 Direct").tag(ConnectBarMode.ax25)
                    Text("AX.25 via Digi").tag(ConnectBarMode.ax25ViaDigi)
                    Text("NET/ROM").tag(ConnectBarMode.netrom)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            switch viewModel.mode {
            case .ax25:
                Text("Direct AX.25 uses no digipeater path overrides.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

            case .ax25ViaDigi:
                viaEditorSection
                recommendedDigiSection

            case .netrom:
                netRomSection
            }

            if let note = viewModel.inlineNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 480)
    }

    private var modeBinding: Binding<ConnectBarMode> {
        Binding(
            get: { viewModel.mode },
            set: { viewModel.setMode($0, for: nil) }
        )
    }

    private var viaEditorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Digi path")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if viewModel.viaDigipeaters.isEmpty {
                        Text("Direct")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08)))
                    }

                    ForEach(Array(viewModel.viaDigipeaters.enumerated()), id: \.offset) { idx, token in
                        HStack(spacing: 4) {
                            Text(token)
                                .font(.system(size: 10, design: .monospaced))
                            Button {
                                viewModel.moveDigiLeft(at: idx)
                            } label: {
                                Image(systemName: "arrow.left")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx == 0)
                            Button {
                                viewModel.moveDigiRight(at: idx)
                            } label: {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx >= viewModel.viaDigipeaters.count - 1)
                            Button {
                                viewModel.removeDigi(at: idx)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(
                            Capsule()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add digis (comma or space separated)", text: $viewModel.pendingViaTokenInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        viewModel.ingestViaInput()
                    }
                Button("Add") {
                    viewModel.ingestViaInput()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("\(viewModel.viaHopCount) hops")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(viewModel.viaHopCount > 2 ? .orange : .secondary)
        }
    }

    private var recommendedDigiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended paths")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Array(viewModel.recommendedDigiPaths.prefix(4).enumerated()), id: \.offset) { idx, candidate in
                    Button(pathLabel(for: candidate.digis, allowEllipsis: false)) {
                        viewModel.applyPathPreset(candidate.digis)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("connectBar.recommendedPathChip.\(idx)")
                }

                Button("Auto") {
                    onAutoConnect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer(minLength: 0)

                Menu("More…") {
                    ForEach(viewModel.moreDigiPathSections) { section in
                        Section(section.title) {
                            ForEach(section.paths, id: \.self) { path in
                                Button(pathLabel(for: path.digis, allowEllipsis: true)) {
                                    viewModel.applyPathPreset(path.digis)
                                }
                            }
                        }
                    }
                    if !viewModel.knownDigiPresets.isEmpty {
                        Section("Known digis") {
                            ForEach(Array(viewModel.knownDigiPresets.prefix(10)), id: \.self) { digi in
                                Button(digi) {
                                    viewModel.appendDigipeaters([digi])
                                }
                            }
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var netRomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.routePreview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text("Next hop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Picker("Next hop", selection: $viewModel.nextHopSelection) {
                    Text("Auto").tag(ConnectBarViewModel.autoNextHopID)
                    if !viewModel.recommendedNextHopOptions.isEmpty {
                        Divider()
                        Section("Recommended") {
                            ForEach(viewModel.recommendedNextHopOptions, id: \.self) { hop in
                                Text(hop).tag(hop)
                            }
                        }
                    }
                    if !viewModel.fallbackNextHopOptions.isEmpty {
                        Divider()
                        Section("Other neighbors") {
                            ForEach(viewModel.fallbackNextHopOptions, id: \.self) { hop in
                                Text(hop).tag(hop)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 260)
                .controlSize(.small)
                .onChange(of: viewModel.nextHopSelection) { _, _ in
                    viewModel.refreshRoutePreview()
                }

                Button("Auto") {
                    onAutoConnect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let warning = viewModel.routeOverrideWarning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func pathLabel(for digis: [String], allowEllipsis: Bool) -> String {
        switch digis.count {
        case 0:
            return "Direct"
        case 1:
            return digis[0]
        case 2:
            return "\(digis[0]) → \(digis[1])"
        default:
            if allowEllipsis {
                return "\(digis[0]) → \(digis[1]) → …"
            }
            return digis.joined(separator: " → ")
        }
    }
}

private struct InlineConnectBar: View {
    @ObservedObject var viewModel: ConnectBarViewModel
    let context: ConnectSourceContext
    let onConnect: () -> Void
    let onAutoConnect: () -> Void
    let onStopAuto: () -> Void
    let failure: ConnectFailure?
    @State private var isAdvancedExpanded = false
    @State private var requestDestinationFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConnectBarPrimaryRow(
                viewModel: viewModel,
                context: context,
                requestDestinationFocus: $requestDestinationFocus,
                onConnect: onConnect,
                onStopAuto: onStopAuto
            )

            if let failure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(failure.detail ?? "Connection failed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show settings") {
                        isAdvancedExpanded = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let status = viewModel.autoAttemptStatus {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("connectBar.autoAttemptStatus")
                    Spacer()
                }
            }

            ConnectBarAdvancedDisclosure(
                viewModel: viewModel,
                context: context,
                isExpanded: $isAdvancedExpanded,
                onAutoConnect: onAutoConnect
            )

            // Command-L focus affordance for destination field.
            Button("") {
                requestDestinationFocus = true
            }
            .keyboardShortcut("l", modifiers: [.command])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        )
        .onAppear {
            viewModel.applyContext(context)
        }
    }
}

private struct ConnectBarPrimaryRow: View {
    @ObservedObject var viewModel: ConnectBarViewModel
    let context: ConnectSourceContext
    @Binding var requestDestinationFocus: Bool
    let onConnect: () -> Void
    let onStopAuto: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: modeBinding) {
                Text("AX.25").tag(ConnectBarMode.ax25)
                Text("AX.25 via Digi").tag(ConnectBarMode.ax25ViaDigi)
                Text("NET/ROM").tag(ConnectBarMode.netrom)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(width: 160, alignment: .leading)
            .accessibilityIdentifier("connectBar.modePicker")

            EditableComboBox(
                text: toCallBinding,
                placeholder: "Destination (CALL-SSID)",
                items: viewModel.flatToSuggestions,
                groups: viewModel.toSuggestionGroups.map { EditableComboBoxGroup(title: $0.title, items: $0.values) },
                width: 340,
                focusRequested: $requestDestinationFocus,
                accessibilityIdentifier: "connectBar.destinationField",
                onCommit: {
                    if viewModel.validationErrors.isEmpty {
                        onConnect()
                    }
                }
            )
            .frame(width: 350)

            Spacer(minLength: 6)

            Button(viewModel.isAutoAttemptInProgress ? "Stop" : "Connect") {
                if viewModel.isAutoAttemptInProgress {
                    onStopAuto()
                } else {
                    onConnect()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!viewModel.isAutoAttemptInProgress && !viewModel.validationErrors.isEmpty)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityIdentifier(viewModel.isAutoAttemptInProgress ? "connectBar.stopAutoButton" : "connectBar.connectButton")
        }
    }

    private var modeBinding: Binding<ConnectBarMode> {
        Binding(
            get: { viewModel.mode },
            set: { viewModel.setMode($0, for: context) }
        )
    }

    private var toCallBinding: Binding<String> {
        Binding(
            get: { viewModel.toCall },
            set: { viewModel.applySuggestedTo($0) }
        )
    }
}

private struct ConnectBarAdvancedDisclosure: View {
    @ObservedObject var viewModel: ConnectBarViewModel
    let context: ConnectSourceContext
    @Binding var isExpanded: Bool
    let onAutoConnect: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                switch viewModel.mode {
                case .ax25:
                    Text("AX.25 direct connection. No path overrides are needed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .ax25ViaDigi:
                    viaEditor
                    recommendedPathsSection
                case .netrom:
                    netRomEditor
                }

                HStack {
                    if let note = viewModel.inlineNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Draft") {
                        viewModel.setMode(ConnectBarMode.defaultMode(for: context), for: context)
                        viewModel.applySuggestedTo("")
                        viewModel.viaDigipeaters = []
                        viewModel.pendingViaTokenInput = ""
                        viewModel.nextHopSelection = ConnectBarViewModel.autoNextHopID
                        viewModel.applyInlineNote(nil)
                        viewModel.validate()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Advanced")
                .font(.system(size: 12, weight: .medium))
        }
        .controlSize(.small)
        .accessibilityIdentifier("connectBar.advancedDisclosure")
    }

    private var viaEditor: some View {
        HStack(spacing: 8) {
            Label("Via", systemImage: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if viewModel.viaDigipeaters.isEmpty {
                        Text("Direct")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
                            )
                    }

                    ForEach(Array(viewModel.viaDigipeaters.enumerated()), id: \.offset) { idx, token in
                        HStack(spacing: 4) {
                            Text(token)
                                .font(.system(size: 10, design: .monospaced))

                            Button {
                                viewModel.moveDigiLeft(at: idx)
                            } label: {
                                Image(systemName: "arrow.left")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx == 0)

                            Button {
                                viewModel.moveDigiRight(at: idx)
                            } label: {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .disabled(idx >= viewModel.viaDigipeaters.count - 1)

                            Button {
                                viewModel.removeDigi(at: idx)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(
                            Capsule()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                        )
                    }
                }
            }
            .frame(maxWidth: 340)

            TextField("Add digis (comma or space separated)", text: $viewModel.pendingViaTokenInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 220)
                .onSubmit {
                    viewModel.ingestViaInput()
                }

            Button("Add") {
                viewModel.ingestViaInput()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("\(viewModel.viaHopCount) hops")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(viewModel.viaHopCount > 2 ? .orange : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(
                    Capsule()
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                )

            if viewModel.viaHopCount > 2 {
                Text("More than 2 digipeaters may reduce reliability")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer()
        }
        .accessibilityIdentifier("connectBar.viaEditor")
    }

    private var recommendedPathsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text("Recommended paths")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Array(viewModel.recommendedDigiPaths.enumerated()), id: \.offset) { idx, candidate in
                        Button(pathLabel(for: candidate.digis, allowEllipsis: false)) {
                            viewModel.applyPathPreset(candidate.digis)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("connectBar.recommendedPathChip.\(idx)")
                    }

                    Button("Auto") {
                        onAutoConnect()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("connectBar.autoConnectChip")
                }

                Spacer(minLength: 0)

                Menu("More…") {
                    ForEach(viewModel.moreDigiPathSections) { section in
                        Section(section.title) {
                            ForEach(section.paths, id: \.self) { path in
                                Button(pathLabel(for: path.digis, allowEllipsis: true)) {
                                    viewModel.applyPathPreset(path.digis)
                                }
                            }
                        }
                    }
                    if !viewModel.knownDigiPresets.isEmpty {
                        Section("Known digis") {
                            ForEach(Array(viewModel.knownDigiPresets.prefix(10)), id: \.self) { digi in
                                Button(digi) {
                                    viewModel.appendDigipeaters([digi])
                                }
                            }
                        }
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("connectBar.morePathsButton")
            }
        }
    }

    private func pathLabel(for digis: [String], allowEllipsis: Bool) -> String {
        switch digis.count {
        case 0:
            return "Direct"
        case 1:
            return digis[0]
        case 2:
            return "\(digis[0]) → \(digis[1])"
        default:
            if allowEllipsis {
                return "\(digis[0]) → \(digis[1]) → …"
            }
            return digis.joined(separator: " → ")
        }
    }

    private var netRomEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.routePreview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("connectBar.routePreview")

            HStack(spacing: 8) {
                Text("Next hop")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("Next hop", selection: $viewModel.nextHopSelection) {
                    Text("Auto").tag(ConnectBarViewModel.autoNextHopID)
                    if !viewModel.recommendedNextHopOptions.isEmpty {
                        Divider()
                        Section("Recommended") {
                            ForEach(viewModel.recommendedNextHopOptions, id: \.self) { hop in
                                Text(hop).tag(hop)
                            }
                        }
                    }
                    if !viewModel.fallbackNextHopOptions.isEmpty {
                        Divider()
                        Section("Other neighbors") {
                            ForEach(viewModel.fallbackNextHopOptions, id: \.self) { hop in
                                Text(hop).tag(hop)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 240)
                .controlSize(.small)
                .onChange(of: viewModel.nextHopSelection) { _, _ in
                    viewModel.refreshRoutePreview()
                }
                .accessibilityIdentifier("connectBar.nextHopPicker")
                Button("Auto") {
                    onAutoConnect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("connectBar.autoConnectChip")
                Spacer()
            }

            if let warning = viewModel.routeOverrideWarning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("connectBar.overrideWarning")
            }
        }
    }
}

private struct ConnectBarStatusRow: View {
    enum Kind {
        case connecting
        case connected
        case disconnecting
    }

    let kind: Kind
    let statusText: String
    let actionTitle: String?
    let actionIdentifier: String?
    let onAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if kind == .connected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("connectBar.statusText")

            Spacer()

            if let actionTitle, let onAction {
                Button(actionTitle) {
                    onAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(actionIdentifier ?? "connectBar.disconnectButton")
                .keyboardShortcut(actionTitle == "Cancel" ? .escape : .return, modifiers: [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
    }
}

private struct BroadcastComposerStrip: View {
    let unprotoPath: [String]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Broadcast (unproto)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            if !unprotoPath.isEmpty {
                Text("via \(unprotoPath.joined(separator: ","))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        )
    }
}

/// Compose box for terminal TX functionality
struct TerminalComposeView: View {
    @Binding var destinationCall: String
    @Binding var digiPath: String
    @Binding var composeText: String
    @Binding var connectionMode: TxConnectionMode
    @Binding var useAXDP: Bool
    
    // Dependencies needed for AdaptiveStatusChip
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var sessionCoordinator: SessionCoordinator

    let sourceCall: String
    let canSend: Bool
    let characterCount: Int
    let queueDepth: Int
    let isConnected: Bool
    /// Session state for connected mode (nil if not in connected mode)
    let sessionState: AX25SessionState?
    /// AXDP capability for the destination station (if known)
    var destinationCapability: AXDPCapability?
    /// AXDP capability negotiation status for the destination (if known)
    var capabilityStatus: SessionCoordinator.CapabilityStatus = .unknown
    @ObservedObject var connectBarViewModel: ConnectBarViewModel
    let connectContext: ConnectSourceContext
    let autoPathSuggestions: [AutoPathSuggestionItem]
    let onApplyAutoPath: (String) -> Void

    let onSend: () -> Void
    let onClear: () -> Void
    let onConnect: () -> Void
    let onConnectBarConnect: () -> Void
    let onAutoConnect: () -> Void
    let onStopAutoConnect: () -> Void
    let onDisconnect: () -> Void
    let onForceDisconnect: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ConnectionModeToggle(
                        mode: $connectionMode,
                        sessionState: sessionState,
                        onDisconnect: onDisconnect,
                        onForceDisconnect: onForceDisconnect
                    )

                    Spacer()

                    if connectionMode == .connected {
                        RoutingCapsuleButton(
                            viewModel: connectBarViewModel,
                            onAutoConnect: onAutoConnect
                        )
                    }
                }

                if connectionMode == .connected {
                    TextField("Destination (CALL-SSID)", text: destinationBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityIdentifier("connectBar.destinationField")
                        .onSubmit {
                            if !primaryActionDisabled {
                                handlePrimaryAction()
                            }
                        }
                }

                TextField(connectionMode == .connected ? "Message" : "Broadcast message", text: $composeText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("terminalComposeField")
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        if !primaryActionDisabled {
                            handlePrimaryAction()
                        }
                    }
                    .disabled(!isConnected || !canTypeMessage)

                HStack(spacing: 10) {
                    if !composeText.isEmpty {
                        Text("\(characterCount)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .monospacedDigit()
                    }

                    if connectionMode == .connected,
                       let validation = connectBarViewModel.validationErrors.first,
                       !connectBarViewModel.isAutoAttemptInProgress {
                        Text(validation)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let autoStatus = connectBarViewModel.autoAttemptStatus {
                        Text(autoStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if queueDepth > 0 {
                        Label("\(queueDepth)", systemImage: "tray.full")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Button(primaryActionTitle) {
                        handlePrimaryAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(primaryActionDisabled)
                    .accessibilityIdentifier(connectBarViewModel.isAutoAttemptInProgress ? "connectBar.stopAutoButton" : "connectBar.connectButton")
                }

                if connectionMode == .datagram,
                   case let .broadcastComposer(broadcast) = connectBarViewModel.barState {
                    BroadcastComposerStrip(unprotoPath: broadcast.unprotoPath)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - Computed Properties

    private var destinationBinding: Binding<String> {
        Binding(
            get: { connectBarViewModel.toCall },
            set: { connectBarViewModel.applySuggestedTo($0) }
        )
    }

    private var primaryActionTitle: String {
        if connectionMode == .datagram {
            return "Send"
        }
        if connectBarViewModel.isAutoAttemptInProgress {
            return "Stop"
        }
        switch sessionState {
        case .connected:
            return "Send"
        case .connecting, .disconnecting:
            return "Cancel"
        case .disconnected, .error, .none:
            return "Connect"
        }
    }

    private var primaryActionDisabled: Bool {
        if connectionMode == .datagram {
            return !canSendMessage || !isConnected
        }

        if connectBarViewModel.isAutoAttemptInProgress {
            return false
        }

        switch sessionState {
        case .connected:
            return !canSendMessage || !isConnected
        case .connecting, .disconnecting:
            return false
        case .disconnected, .error, .none:
            return !isConnected || !connectBarViewModel.validationErrors.isEmpty
        }
    }

    private func handlePrimaryAction() {
        if connectionMode == .datagram {
            onSend()
            return
        }

        if connectBarViewModel.isAutoAttemptInProgress {
            onStopAutoConnect()
            return
        }

        switch sessionState {
        case .connected:
            onSend()
        case .connecting, .disconnecting:
            onForceDisconnect()
        case .disconnected, .error, .none:
            onConnectBarConnect()
        }
    }

    /// Whether the user can type a message
    private var canTypeMessage: Bool {
        switch connectionMode {
        case .datagram:
            return true  // Can always type in datagram mode
        case .connected:
            // Can type when connected or when there's no session yet
            return sessionState == nil || sessionState == .connected
        }
    }

    /// Whether the send button should be enabled
    private var canSendMessage: Bool {
        guard canSend else { return false }

        switch connectionMode {
        case .datagram:
            return true
        case .connected:
            // Must be connected to send in connected mode
            return sessionState == .connected
        }
    }

    // MARK: - AXDP Toggle

    /// Compact inline toggle for enabling AXDP payload encoding.
    /// Shown only when we have a discovered AXDP capability for the destination.
    private struct AXDPPayloadToggle: View {
        @Binding var isOn: Bool
        let capability: AXDPCapability

        var body: some View {
            Toggle(isOn: $isOn) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("AXDP")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .toggleStyle(.button)
            .controlSize(.mini)
            .help(tooltip)
        }

        private var tooltip: String {
            var parts: [String] = []
            parts.append("AXDP payloads enabled for this destination.")
            parts.append("Peer supports AXDP v\(capability.protoMin)-\(capability.protoMax).")
            if capability.features.contains(.compression) {
                parts.append("Compression may be used for file transfers.")
            }
            parts.append("Disable if the remote behaves unexpectedly.")
            return parts.joined(separator: " ")
        }
    }

}

/// TX queue entry row for displaying pending frames
struct TxQueueEntryRow: View {
    let entry: TxQueueEntry

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            statusIcon
                .font(.caption)

            // Destination
            Text(entry.frame.destination.display)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)

            // Info preview
            if let info = entry.frame.displayInfo {
                Text(info)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            // Timestamp
            Text(entry.frame.createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Retry count
            if entry.state.attempts > 1 {
                Text("×\(entry.state.attempts)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.state.status {
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .sending:
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.blue)
        case .sent:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        case .awaitingAck:
            Image(systemName: "hourglass")
                .foregroundStyle(.orange)
        case .acked:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }
}

/// TX queue view showing pending and recent frames
struct TxQueueView: View {
    let entries: [TxQueueEntry]
    let onCancel: (UUID) -> Void
    let onClearCompleted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("TX Queue")
                    .font(.headline)

                Spacer()

                if hasCompleted {
                    Button("Clear Completed") {
                        onClearCompleted()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Queue entries
            if entries.isEmpty {
                Text("No pending transmissions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            TxQueueEntryRow(entry: entry)
                                .contextMenu {
                                    if entry.state.status == .queued {
                                        Button("Cancel", role: .destructive) {
                                            onCancel(entry.frame.id)
                                        }
                                    }
                                }

                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minHeight: 100, maxHeight: 200)
    }

    private var hasCompleted: Bool {
        entries.contains { entry in
            switch entry.state.status {
            case .acked, .failed, .cancelled:
                return true
            default:
                return false
            }
        }
    }
}

#Preview("Compose View - Datagram") {
    TerminalComposeView(
        destinationCall: .constant("N0CALL"),
        digiPath: .constant("DRL"),
        composeText: .constant("Hello World"),
        connectionMode: .constant(.datagram),
        useAXDP: .constant(false),
        settings: AppSettingsStore(),
        sessionCoordinator: SessionCoordinator(),
        sourceCall: "MYCALL",
        canSend: true,
        characterCount: 11,
        queueDepth: 2,
        isConnected: true,
        sessionState: nil,
        connectBarViewModel: ConnectBarViewModel(),
        connectContext: .terminal,
        autoPathSuggestions: [],
        onApplyAutoPath: { _ in },
        onSend: {},
        onClear: {},
        onConnect: {},
        onConnectBarConnect: {},
        onAutoConnect: {},
        onStopAutoConnect: {},
        onDisconnect: {},
        onForceDisconnect: {}
    )
    .frame(width: 700)
}

#Preview("Compose View - Connected") {
    TerminalComposeView(
        destinationCall: .constant("N0CALL"),
        digiPath: .constant("DRL"),
        composeText: .constant("Hello World"),
        connectionMode: .constant(.connected),
        useAXDP: .constant(false),
        settings: AppSettingsStore(),
        sessionCoordinator: SessionCoordinator(),
        sourceCall: "MYCALL",
        canSend: true,
        characterCount: 11,
        queueDepth: 0,
        isConnected: true,
        sessionState: .connected,
        connectBarViewModel: ConnectBarViewModel(),
        connectContext: .terminal,
        autoPathSuggestions: [],
        onApplyAutoPath: { _ in },
        onSend: {},
        onClear: {},
        onConnect: {},
        onConnectBarConnect: {},
        onAutoConnect: {},
        onStopAutoConnect: {},
        onDisconnect: {},
        onForceDisconnect: {}
    )
    .frame(width: 700)
}

#Preview("Compose View - Connecting") {
    TerminalComposeView(
        destinationCall: .constant("W6ABC"),
        digiPath: .constant(""),
        composeText: .constant(""),
        connectionMode: .constant(.connected),
        useAXDP: .constant(false),
        settings: AppSettingsStore(),
        sessionCoordinator: SessionCoordinator(),
        sourceCall: "MYCALL",
        canSend: true,
        characterCount: 0,
        queueDepth: 0,
        isConnected: true,
        sessionState: .connecting,
        connectBarViewModel: ConnectBarViewModel(),
        connectContext: .terminal,
        autoPathSuggestions: [],
        onApplyAutoPath: { _ in },
        onSend: {},
        onClear: {},
        onConnect: {},
        onConnectBarConnect: {},
        onAutoConnect: {},
        onStopAutoConnect: {},
        onDisconnect: {},
        onForceDisconnect: {}
    )
    .frame(width: 700)
}

#Preview("Mode Toggle") {
    VStack(spacing: 20) {
        ConnectionModeToggle(
            mode: .constant(.datagram),
            sessionState: nil,
            onDisconnect: {},
            onForceDisconnect: {}
        )

        ConnectionModeToggle(
            mode: .constant(.connected),
            sessionState: .connected,
            onDisconnect: {},
            onForceDisconnect: {}
        )
    }
    .padding()
}

#Preview("Session Status Badges") {
    VStack(spacing: 12) {
        SessionStatusBadge(state: nil, destinationCall: "N0CALL", onDisconnect: {}, onForceDisconnect: {})
        SessionStatusBadge(state: .connecting, destinationCall: "N0CALL", onDisconnect: {}, onForceDisconnect: {})
        SessionStatusBadge(state: .connected, destinationCall: "N0CALL", onDisconnect: {}, onForceDisconnect: {}, capabilityStatus: .pending)
        SessionStatusBadge(state: .connected, destinationCall: "N0CALL", onDisconnect: {}, onForceDisconnect: {}, capabilityStatus: .notSupported)
        SessionStatusBadge(state: .error, destinationCall: "N0CALL", onDisconnect: {}, onForceDisconnect: {})
    }
    .padding()
}
