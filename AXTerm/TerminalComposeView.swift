//
//  TerminalComposeView.swift
//  AXTerm
//
//  Terminal TX compose view with message input and queue status.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.5
//

import SwiftUI
#if os(macOS)
import AppKit
#endif
import Combine

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
        .background(Color(platform: .platformCardBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(platform: .platformSeparator), lineWidth: 0.5)
        )
        // Two words that must stay two words. Squeezed by a narrow row this
        // wrapped to "Bro adc ast" over three lines and took the bar with it.
        .fixedSize()
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
                         // Simple dot to indicate AXDP active.
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
                .stroke(Color(platform: .platformSeparator).opacity(0.4), lineWidth: 0.5)
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
            return "Connected"  // Removed "to <callsign>" text - will be shown in header
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
            return "No answer to the AXDP check, so AXDP is off for this peer."
        }
    }
}

// MARK: - Routing Popover Helpers

#if os(macOS)

/// Manages a manually-created NSPopover so we can set .applicationModal behavior,
/// which prevents the popover from auto-dismissing when a TextField inside steals
/// first-responder focus. An NSEvent local monitor handles outside-click dismissal.
private final class RoutingPopoverManager: ObservableObject {
    @Published private(set) var isShown = false
    private var nsPopover: NSPopover?
    private var eventMonitor: Any?

    func open<Content: View>(content: Content, anchor: NSView) {
        guard !isShown else { return }
        let hostingController = NSHostingController(rootView: content)
        let popover = NSPopover()
        popover.contentViewController = hostingController
        // applicationDefined: never auto-closes. We dismiss explicitly on outside clicks.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        nsPopover = popover
        isShown = true

        // Dismiss when the user clicks anywhere outside the popover's window.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self, weak popover] event in
            guard let self, let popover, popover.isShown else { return event }
            if let popoverWindow = popover.contentViewController?.view.window,
               event.window == popoverWindow {
                return event   // Click is inside the popover — let it through.
            }
            DispatchQueue.main.async { self.close() }
            return event
        }
    }

    func close() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        nsPopover?.close()
        nsPopover = nil
        isShown = false
    }

    deinit { close() }
}

/// Embeds an invisible NSView so we have an AppKit anchor for NSPopover.show().
private struct PopoverAnchorView: NSViewRepresentable {
    let onAnchor: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onAnchor(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

#endif

// MARK: - RoutingCapsuleButton

private struct RoutingCapsuleButton: View {
    @ObservedObject var viewModel: ConnectBarViewModel
    let onAutoConnect: () -> Void
    var isLocked: Bool = false
    var onRequestChange: (() -> Void)?
    #if os(macOS)
    @StateObject private var popoverManager = RoutingPopoverManager()
    @State private var anchorView: NSView?
    #else
    /// SwiftUI's own popover is used on iOS. The AppKit workaround above
    /// exists because a `TextField` taking first responder inside a SwiftUI
    /// popover dismisses it on macOS; UIKit has no such behavior, so the
    /// plain modifier is correct here — and on iPhone it adapts to a sheet,
    /// which is the right shape for a form that narrow.
    @State private var isShowingRouting = false
    #endif

    var body: some View {
        Button {
            #if os(macOS)
            if popoverManager.isShown {
                popoverManager.close()
            } else {
                guard let anchor = anchorView else { return }
                popoverManager.open(
                    content: RoutingPopoverContent(
                        viewModel: viewModel,
                        onAutoConnect: onAutoConnect,
                        isLocked: isLocked,
                        onRequestChange: onRequestChange.map { action in
                            { [weak popovers = popoverManager] in
                                popovers?.close()
                                action()
                            }
                        }
                    ),
                    anchor: anchor
                )
            }
            #else
            isShowingRouting.toggle()
            #endif
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
                    .stroke(Color(platform: .platformSeparator).opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connectBar.routingButton")
        #if os(macOS)
        .background(PopoverAnchorView { view in anchorView = view })
        #else
        .popover(isPresented: $isShowingRouting) {
            RoutingPopoverContent(
                viewModel: viewModel,
                onAutoConnect: onAutoConnect,
                isLocked: isLocked,
                onRequestChange: onRequestChange.map { action in
                    { isShowingRouting = false; action() }
                })
                .frame(minWidth: 320)
                .presentationCompactAdaptation(.sheet)
        }
        #endif
    }

    private var summaryText: String {
        switch viewModel.mode {
        case .ax25:
            return "AX.25 \u{00B7} Direct"
        case .ax25ViaDigi:
            if viewModel.viaDigipeaters.isEmpty {
                return "AX.25 \u{00B7} Digi \u{00B7} Auto"
            }
            let compactPath = viewModel.viaDigipeaters.prefix(2).joined(separator: " \u{2192} ")
            return "AX.25 \u{00B7} Digi: \(compactPath)"
        case .netrom:
            if viewModel.nextHopSelection == ConnectBarViewModel.autoNextHopID {
                return "NET/ROM \u{00B7} Auto"
            }
            return "NET/ROM \u{00B7} \(viewModel.nextHopSelection)"
        }
    }
}

private enum DigiInputMode {
    case auto
    case manual
}

private struct RoutingPopoverContent: View {
    @ObservedObject var viewModel: ConnectBarViewModel
    let onAutoConnect: () -> Void
    var isLocked: Bool = false
    var onRequestChange: (() -> Void)?
    @State private var digiInputMode: DigiInputMode = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Protocol")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Protocol", selection: modeBinding) {
                    Text("AX.25 Direct").tag(ConnectBarMode.ax25)
                    Text("AX.25 via Digi").tag(ConnectBarMode.ax25ViaDigi)
                    Text("NET/ROM").tag(ConnectBarMode.netrom)
                }
                .platformRadioGroup()
                .labelsHidden()
                .disabled(isLocked)
            }

            protocolInfoCard

            ConnectBarRadioRow(viewModel: viewModel, isLocked: isLocked)

            switch viewModel.mode {
            case .ax25:
                EmptyView()

            case .ax25ViaDigi:
                viaDigiProgressiveSection

            case .netrom:
                netRomSection
            }

            if let note = viewModel.inlineNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if isLocked, let onRequestChange {
                Divider()
                Button("Change\u{2026}") {
                    onRequestChange()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: viewModel.mode == .ax25 ? 360 : 480)
        .onAppear {
            digiInputMode = viewModel.viaDigipeaters.isEmpty ? .auto : .manual
        }
        .onChange(of: digiInputMode) { _, newMode in
            guard !isLocked else { return }
            if newMode == .auto, !viewModel.viaDigipeaters.isEmpty {
                viewModel.applyPathPreset([])
            }
        }
    }

    private var protocolInfoCard: some View {
        let description: String

        switch viewModel.mode {
        case .ax25:
            description = "Sends frames directly to the destination without digipeater path overrides. Uses only the destination callsign for routing."
        case .ax25ViaDigi:
            description = "Routes via a specified digipeater path (e.g. DRLNODE). Auto selects a recommended path, or use Manual to pin hops."
        case .netrom:
            description = "Connects using node-to-node routing, not digipeater paths. AXTerm selects the next hop based on learned routes and link quality."
        }

        return ProtocolInfoCallout(description: description)
            .padding(.top, 2)
    }

    @ViewBuilder
    private var viaDigiProgressiveSection: some View {
        if isLocked {
            // Read-only summary when connected
            VStack(alignment: .leading, spacing: 6) {
                Text("Digi path")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if viewModel.viaDigipeaters.isEmpty {
                    Text("Direct (no digipeaters)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(viewModel.viaDigipeaters.joined(separator: " \u{2192} "))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        } else {
            // Auto/Manual toggle
            VStack(alignment: .leading, spacing: 8) {
                Picker("Path mode", selection: $digiInputMode) {
                    Text("Auto (recommended)").tag(DigiInputMode.auto)
                    Text("Manual").tag(DigiInputMode.manual)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)

                if digiInputMode == .auto {
                    Text("AXTerm will select the best path automatically.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    viaEditorSection
                    recommendedDigiSection
                }
            }
        }
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
                            .background(Capsule().fill(Color(platform: .platformQuaternaryLabel).opacity(0.08)))
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
                        .background(Capsule().fill(Color(platform: .platformWindowBackground)))
                        .overlay(
                            Capsule()
                                .stroke(Color(platform: .platformSeparator).opacity(0.35), lineWidth: 0.5)
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add digis (comma or space separated)", text: $viewModel.pendingViaTokenInput)
                    .callsignInput($viewModel.pendingViaTokenInput)
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
                .disabled(!viewModel.canAddPendingDigipeaters)
            }

            if let duplicateError = viewModel.pendingViaDuplicateError ?? viewModel.viaInputError {
                Text(duplicateError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(1)
            }

            Text(CountPhrase.of(viewModel.viaHopCount, "hop"))
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
                    let selected = isPathSelected(candidate.digis)
                    let unavailable = viewModel.isSuggestedPathUnavailable(candidate.digis) && !selected
                    Button(pathLabel(for: candidate.digis, allowEllipsis: false)) {
                        viewModel.applyPathPreset(candidate.digis)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(selected ? .accentColor : .secondary)
                    .disabled(unavailable)
                    .opacity(unavailable ? 0.55 : 1.0)
                    .help(unavailable ? "Already uses a digi in your current path" : "")
                    .accessibilityIdentifier("connectBar.recommendedPathChip.\(idx)")
                }

                Spacer(minLength: 0)

                Menu("More…") {
                    ForEach(viewModel.moreDigiPathSections) { section in
                        Section(section.title) {
                            ForEach(section.paths, id: \.self) { path in
                                let unavailable = viewModel.isSuggestedPathUnavailable(path.digis)
                                Button(pathLabel(for: path.digis, allowEllipsis: true)) {
                                    viewModel.applyPathPreset(path.digis)
                                }
                                .disabled(unavailable)
                            }
                        }
                    }
                    if !viewModel.knownDigiPresets.isEmpty {
                        Section("Known digis") {
                            ForEach(Array(viewModel.knownDigiPresets.prefix(10)), id: \.self) { digi in
                                let inPath = viewModel.isDigipeaterUnavailableInCurrentPath(digi)
                                Button {
                                    viewModel.appendDigipeaters([digi])
                                } label: {
                                    HStack {
                                        Text(digi)
                                        Spacer()
                                        if inPath {
                                            Label("In path", systemImage: "checkmark")
                                                .accessibilityIdentifier("connectBar.knownDigiInPath.\(digi)")
                                        }
                                    }
                                }
                                .disabled(inPath)
                                .opacity(inPath ? 0.45 : 1.0)
                                .accessibilityIdentifier("connectBar.knownDigi.\(digi)")
                            }
                        }
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("connectBar.morePathsButton")
            }

            if let note = viewModel.inlineNote, note == "Removed duplicate digis from path." {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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

    private func isPathSelected(_ digis: [String]) -> Bool {
        let lhs = viewModel.viaDigipeaters.map(DigipeaterListParser.normalizeForComparison)
            .filter { !$0.isEmpty }
        let rhs = digis.map(DigipeaterListParser.normalizeForComparison)
            .filter { !$0.isEmpty }
        return lhs == rhs
    }
}

private struct ProtocolInfoCallout: View {
    let description: String

    var body: some View {
        Text(description)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .accessibilityLabel(description)
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
                .fill(Color(platform: .platformCardBackground).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(platform: .platformSeparator).opacity(0.35), lineWidth: 0.5)
        )
        .onAppear {
            viewModel.applyContext(context)
        }
    }
}

/// Lets one segmented control be intrinsically sized on a wide bar and
/// row-filling on a narrow one, without writing the picker out twice.
private struct SegmentedWidth: ViewModifier {
    let fillsRow: Bool

    func body(content: Content) -> some View {
        if fillsRow {
            content.frame(maxWidth: .infinity)
        } else {
            content.fixedSize()
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
                uppercases: true,
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

/// Which radio the call leaves on. Present only when there are two radios
/// to choose between; Auto is the default and says what it would do.
private struct ConnectBarRadioRow: View {
    @ObservedObject var viewModel: ConnectBarViewModel
    var isLocked: Bool = false

    var body: some View {
        if viewModel.radioOptions.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Radio")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Radio", selection: $viewModel.radioSelection) {
                    Text("Auto").tag(RadioID?.none)
                    ForEach(viewModel.radioOptions) { option in
                        Text(option.name).tag(RadioID?.some(option.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 200, alignment: .leading)
                .disabled(isLocked)
                .help(viewModel.radioSelection == nil
                      ? viewModel.autoRadioHelp
                      : "Chosen by you. The session stays on this radio once it opens; Auto would pick by evidence.")
                if viewModel.radioSelection == nil {
                    // Auto's reasoning, in the words the coordinator gives,
                    // so the operator can see why before pressing Connect.
                    Text(viewModel.autoRadioHelp)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
                ConnectBarRadioRow(viewModel: viewModel)

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
                                Capsule().fill(Color(platform: .platformQuaternaryLabel).opacity(0.08))
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
                        .background(Capsule().fill(Color(platform: .platformWindowBackground)))
                        .overlay(
                            Capsule()
                                .stroke(Color(platform: .platformSeparator).opacity(0.35), lineWidth: 0.5)
                        )
                    }
                }
            }
            .frame(maxWidth: 340)

            TextField("Add digis (comma or space separated)", text: $viewModel.pendingViaTokenInput)
                .callsignInput($viewModel.pendingViaTokenInput)
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
            .disabled(!viewModel.canAddPendingDigipeaters)

            if let duplicateError = viewModel.pendingViaDuplicateError ?? viewModel.viaInputError {
                Text(duplicateError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(1)
            }

            Text(CountPhrase.of(viewModel.viaHopCount, "hop"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(viewModel.viaHopCount > 2 ? .orange : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(platform: .platformWindowBackground)))
                .overlay(
                    Capsule()
                        .stroke(Color(platform: .platformSeparator).opacity(0.35), lineWidth: 0.5)
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
                        let unavailable = viewModel.isSuggestedPathUnavailable(candidate.digis)
                        Button(pathLabel(for: candidate.digis, allowEllipsis: false)) {
                            viewModel.applyPathPreset(candidate.digis)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(unavailable)
                        .opacity(unavailable ? 0.55 : 1.0)
                        .help(unavailable ? "Already uses a digi in your current path" : "")
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
                                let unavailable = viewModel.isSuggestedPathUnavailable(path.digis)
                                Button(pathLabel(for: path.digis, allowEllipsis: true)) {
                                    viewModel.applyPathPreset(path.digis)
                                }
                                .disabled(unavailable)
                            }
                        }
                    }
                    if !viewModel.knownDigiPresets.isEmpty {
                        Section("Known digis") {
                            ForEach(Array(viewModel.knownDigiPresets.prefix(10)), id: \.self) { digi in
                                let inPath = viewModel.isDigipeaterUnavailableInCurrentPath(digi)
                                Button {
                                    viewModel.appendDigipeaters([digi])
                                } label: {
                                    HStack {
                                        Text(digi)
                                        Spacer()
                                        if inPath {
                                            Label("In path", systemImage: "checkmark")
                                                .accessibilityIdentifier("connectBar.knownDigiInPath.\(digi)")
                                        }
                                    }
                                }
                                .disabled(inPath)
                                .opacity(inPath ? 0.45 : 1.0)
                                .accessibilityIdentifier("connectBar.knownDigi.\(digi)")
                            }
                        }
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("connectBar.morePathsButton")
            }

            if let note = viewModel.inlineNote, note == "Removed duplicate digis from path." {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
                .fill(Color(platform: .platformCardBackground).opacity(0.45))
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
                .fill(Color(platform: .platformCardBackground).opacity(0.35))
        )
    }
}

/// Compose box for terminal TX functionality
struct TerminalComposeView: View {
    #if os(iOS)
    /// Drives the setup row's one-line/two-line split. Compact means a
    /// phone, where the single-line bar does not fit and never did.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Binding var destinationCall: String
    @Binding var digiPath: String
    @Binding var composeText: String
    @Binding var connectionMode: TxConnectionMode
    @Binding var useAXDP: Bool
    
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
    /// Far end of an established NET/ROM circuit, when one is up.
    ///
    /// The connect bar holds the next hop while a relay runs — right for the
    /// link, wrong as a name for whoever is on the other end of it.
    var relayDestination: String?
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
    var onReconnectWithNewRouting: (() -> Void)?
    /// Appends the operator's position stamp to the compose text (GPS or
    /// grid-square fallback). Nil hides the button.
    var onInsertPosition: (() -> Void)?
    /// Whether Capture is on for the session on screen.
    var isCapturing: Bool = false
    /// Turns Capture on or off for the session on screen. Nil hides the button.
    var onToggleCapture: (() -> Void)?
    /// Line or Raw (Docs/TerminalInputModes.md).
    var inputMode: Binding<TerminalInputMode> = .constant(.line)
    /// The far end's line so far, shown in the raw field.
    var rawPrompt: String = ""
    /// The keys typed on the current raw line.
    var rawEcho: String = ""
    /// Takes keys typed in Raw mode. Nil hides the Line/Raw switch.
    var onRawKey: ((RawKeyCoalescer.Key) -> Void)?
    /// Sends one control byte now. Nil hides the control-character menu.
    var onSendControl: ((UInt8) -> Void)?

    @FocusState private var isTextFieldFocused: Bool
    /// Off for a far end that echoes what it receives.
    @AppStorage("terminalRawLocalEcho") private var rawLocalEcho = true
    @State private var showRoutingChangeConfirmation = false
    @StateObject private var destinationPickerViewModel = DestinationPickerViewModel()

    private var routingChoiceBinding: Binding<ConnectRoutingChoice> {
        Binding(
            get: { connectBarViewModel.routingChoice },
            set: { connectBarViewModel.setRoutingChoice($0, for: connectContext) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if sourceCall.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Set your callsign before transmitting.")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Set Up\u{2026}") {
                        // No callsign means a station that has not been set
                        // up, so this opens first-run setup: the callsign,
                        // where the station is, and its radio.
                        SettingsRouter.shared.presentSetup()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.15))
            }

            VStack(alignment: .leading, spacing: 6) {
                // Row 0 — setup. The mode toggle, then (Session) the routing
                // switch + destination + Connect, or (Broadcast) the unproto
                // pill.
                //
                // One line on a Mac window or an iPad; two on a phone. These
                // controls want about 700 points and an iPhone offers 402,
                // and an HStack that cannot fit does not shrink — it
                // overflows, and SwiftUI centers the overflow. That widened
                // the whole terminal VStack past the screen, so the tab
                // strip, the connection line and the message field were all
                // clipped at both edges by a bar three views away. Splitting
                // only at a compact width costs the desktop nothing: it is
                // the one width where a single line was never possible.
                if isCompactWidth {
                    twoLineSetupRow
                } else {
                    #if os(iOS)
                    // An iPad in portrait is a regular width but not a wide
                    // one: on a mini the single line squeezed the callsign
                    // field to "Calls…" and wrapped "Auto Connect". It takes
                    // the phone's two lines whenever one does not fit.
                    ViewThatFits(in: .horizontal) {
                        singleLineSetupRow
                        twoLineSetupRow
                    }
                    #else
                    singleLineSetupRow
                    #endif
                }

                // Row 1 — compose. The message/broadcast field + Send.
                HStack(spacing: 8) {
                    if composeRows.accessoriesInMenu {
                        // A phone: one button for everything that is not
                        // the message, so the field gets the row (issue 106).
                        if hasComposeAccessories {
                            composeAccessoryMenu
                        }
                    } else if showsInputModeSwitch {
                        Picker("Input", selection: inputMode) {
                            ForEach(TerminalInputMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("Line: edit a line and send it with Return. "
                              + "Raw: each key goes to the station as you type, for prompts, menus and control keys.")
                        .accessibilityIdentifier("terminalInputModePicker")
                    }

                    if isRawMode {
                        RawTerminalField(
                            prompt: rawPrompt,
                            echo: rawLocalEcho ? rawEcho : "",
                            isEnabled: isConnected && sessionIsUp,
                            onKey: { onRawKey?($0) })
                    } else {
                        TextField(connectionMode == .connected ? "Message" : "Broadcast message", text: $composeText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("terminalComposeField")
                            .focused($isTextFieldFocused)
                            .onSubmit {
                                if canSendMessage {
                                    send()
                                }
                            }
                            #if os(iOS)
                            // A hardware keyboard's Return: the field takes it
                            // itself, or on iPadOS it did not send (issue 111).
                            .onKeyPress(.return, phases: .down) { press in
                                guard ComposeReturnKey.sends(modifiers: press.modifiers,
                                                             canSend: canSendMessage) else { return .ignored }
                                send()
                                return .handled
                            }
                            #endif
                            .disabled(!isConnected || !canTypeMessage)
                    }

                    if !composeRows.accessoriesInMenu, let onSendControl, connectionMode == .connected {
                        controlCharacterMenu(onSendControl)
                    }

                    if !composeRows.accessoriesInMenu, let onInsertPosition, !isRawMode {
                        Button {
                            onInsertPosition()
                        } label: {
                            Image(systemName: "location")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!isConnected || !canTypeMessage)
                        .help("Insert your position (GPS when available, otherwise your grid square) into the message.")
                        .accessibilityIdentifier("terminalInsertPosition")
                    }

                    // Capture: keep what the station sends as a text file.
                    // Offered while a session is up, and kept on screen while
                    // a capture runs so it can always be turned off.
                    if !composeRows.accessoriesInMenu, let onToggleCapture,
                       isCapturing || (connectionMode == .connected && sessionState == .connected) {
                        Button {
                            onToggleCapture()
                        } label: {
                            Image(systemName: isCapturing ? "record.circle.fill" : "record.circle")
                                .foregroundStyle(isCapturing ? Color.red : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(isCapturing
                              ? "Stop capturing and save what this station sent as a text file in \(ReceivedFileStore.folderName)."
                              : "Capture everything this station sends to a text file in \(ReceivedFileStore.folderName). Your own lines are not included.")
                        .accessibilityLabel(isCapturing ? "Stop Capture" : "Capture")
                        .accessibilityIdentifier("terminalCaptureToggle")
                    }

                    if !composeText.isEmpty && !isRawMode {
                        Text("\(characterCount)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .monospacedDigit()
                    }

                    if queueDepth > 0 {
                        Label("\(queueDepth)", systemImage: "tray.full")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    // Raw mode sends as keys are pressed, and Return is a
                    // key there: a Send button would take it.
                    if !isRawMode {
                        Button("Send") {
                            send()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(!canSendMessage || !isConnected)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }
            }
            .padding(.horizontal, 14)
            #if os(iOS)
            .padding(.top, 12)
            #else
            .padding(.top, 10)
            #endif
            // A Mac window ends where the padding ends; a handheld has a home
            // indicator below it. 10pt put the message field and the Send
            // button hard against that edge, where the system gesture area
            // starts and a thumb reaching for Send finds the app switcher.
            #if os(iOS)
            .padding(.bottom, 18)
            #else
            .padding(.bottom, 10)
            #endif
            .background(Color(platform: .platformWindowBackground))
            // Reads as a bar rather than as the last of the log lines.
            .overlay(alignment: .top) { Divider() }
            .alert("Change Routing?", isPresented: $showRoutingChangeConfirmation) {
                Button("Reconnect with New Routing") {
                    onReconnectWithNewRouting?()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Changing routing will disconnect the current session and reconnect with new settings.")
            }
        }
    }

    // MARK: Setup row pieces

    /// The setup row on one line: a Mac window or a wide iPad.
    private var singleLineSetupRow: some View {
        HStack(spacing: 8) {
            connectionModeToggle
            if connectionMode == .connected {
                destinationControl
                routingPicker
                routingCapsule
                Spacer(minLength: 8)
                connectStatusText
                sessionActionButton
            } else {
                broadcastStrip
                Spacer(minLength: 8)
            }
        }
    }

    /// The setup row on two lines, for a phone or a narrow iPad.
    private var twoLineSetupRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                connectionModeToggle
                Spacer(minLength: 8)
                if connectionMode == .connected {
                    connectStatusText
                    sessionActionButton
                } else {
                    broadcastStrip
                }
            }
            // On a phone a link that is up drops both rows: the station is
            // in the session header and the route is fixed (issue 106).
            if composeRows.destination {
                HStack(spacing: 8) {
                    destinationControl
                    routingCapsule
                }
            }
            if composeRows.routingPicker {
                // Full width rather than intrinsic: four segments
                // across a phone is 90 points each, which is a
                // readable control. Intrinsic width plus the
                // toggle overflows the row all over again.
                routingPicker
            }
        }
    }

    private var composeRows: CompactTerminalLayout.ComposeRows {
        CompactTerminalLayout.composeRows(compact: isCompactWidth,
                                          sessionMode: connectionMode == .connected,
                                          linkUp: sessionState == .connected)
    }

    // Extracted so the compact and regular arrangements share one definition
    // of each control rather than two that drift apart.

    /// True only on a phone-width screen. The Mac and the iPad both have room
    /// for the single-line bar, and a Mac window has a minimum width.
    #if os(iOS)
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    private var connectionModeToggle: some View {
        ConnectionModeToggle(
            mode: $connectionMode,
            sessionState: sessionState,
            onDisconnect: onDisconnect,
            onForceDisconnect: onForceDisconnect
        )
    }

    /// The primary input: who we are talking to. A locked session shows the
    /// station as text, because it is no longer a choice.
    @ViewBuilder
    private var destinationControl: some View {
        if sessionState == .connected {
            HStack(spacing: 4) {
                Text(relayDestination ?? connectBarViewModel.toCall)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .accessibilityIdentifier("connectBar.lockedDestination")
                if relayDestination == nil {
                    // Lets the operator pick another station without ending
                    // this session, which carries on in the session list.
                    Button {
                        connectBarViewModel.applySuggestedTo("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Choose a different station. This session stays open.")
                    .accessibilityLabel("Choose a different station")
                    .accessibilityIdentifier("connectBar.changeDestination")
                }
            }
        } else {
            DestinationPickerControl(
                viewModel: destinationPickerViewModel,
                externalText: connectBarViewModel.toCall,
                groups: connectBarViewModel.toSuggestionGroups,
                reachableVia: connectBarViewModel.claimedRouteVia,
                disabled: sessionState == .connecting || sessionState == .disconnecting,
                showsInlineError: false,
                onDestinationChanged: { value in
                    connectBarViewModel.applySuggestedTo(value)
                },
                onDestinationCommitted: { value in
                    connectBarViewModel.applySuggestedTo(value)
                    if !primaryActionDisabled {
                        handlePrimaryAction()
                    }
                }
            )
            #if os(iOS)
            // Room for a full callsign-SSID; without a floor the field was
            // the first thing squeezed.
            .frame(minWidth: 170, maxWidth: isCompactWidth ? .infinity : 240)
            #else
            .frame(maxWidth: 240)
            #endif
            .layoutPriority(1)
        }
    }

    /// The visible routing switch — how to reach that station.
    private var routingPicker: some View {
        Picker("Routing", selection: routingChoiceBinding) {
            ForEach(ConnectRoutingChoice.allCases) { choice in
                Text(choice.label).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        // Intrinsic width beside its neighbors on a wide bar; the full row
        // on a phone, where it has the row to itself.
        .modifier(SegmentedWidth(fillsRow: isCompactWidth))
        .disabled(sessionState == .connected)
        .help("Auto tries the best route it knows: direct, then a digipeater, then a NET/ROM circuit, then a node relay. Or force one.")
        .accessibilityIdentifier("connectBar.routingChoice")
    }

    /// Path / next-hop details — only when a protocol that has them is
    /// forced, or while a session is locked in.
    @ViewBuilder
    private var routingCapsule: some View {
        if sessionState == .connected
            || connectBarViewModel.routingChoice == .digi
            || connectBarViewModel.routingChoice == .netrom {
            RoutingCapsuleButton(
                viewModel: connectBarViewModel,
                onAutoConnect: onAutoConnect,
                isLocked: sessionState == .connected,
                onRequestChange: sessionState == .connected ? {
                    showRoutingChangeConfirmation = true
                } : nil
            )
        }
    }

    /// Validation / auto-routing status (subtle, only when relevant).
    @ViewBuilder
    private var connectStatusText: some View {
        if let validation = nonDestinationValidationError,
           sessionState != .connected,
           !connectBarViewModel.isAutoAttemptInProgress {
            Text(validation)
                .font(.system(size: 10))
                .foregroundStyle(.red.opacity(0.7))
                .lineLimit(1)
                .layoutPriority(-1)
        } else if let autoStatus = connectBarViewModel.autoAttemptStatus {
            Text(autoStatus)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
    }

    @ViewBuilder
    private var sessionActionButton: some View {
        if sessionState == .connected {
            Button(sessionActionTitle) {
                handleSessionAction()
            }
            .lineLimit(1)
            .fixedSize()
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("connectBar.disconnectButton")
        } else {
            Button {
                handleSessionAction()
            } label: {
                Text(sessionActionTitle)
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(sessionActionDisabled)
            .accessibilityIdentifier(connectBarViewModel.isAutoAttemptInProgress ? "connectBar.stopAutoButton" : "connectBar.connectButton")
        }
    }

    /// Broadcast — the unproto pill inline, not a separate row.
    @ViewBuilder
    private var broadcastStrip: some View {
        if case let .broadcastComposer(broadcast) = connectBarViewModel.barState {
            BroadcastComposerStrip(unprotoPath: broadcast.unprotoPath)
        }
    }

    // MARK: Session action (Connect/Disconnect/Cancel/Stop) — Row 1

    private var sessionActionTitle: String {
        if connectBarViewModel.isAutoAttemptInProgress {
            return "Stop"
        }
        switch sessionState {
        case .connected:
            return "Disconnect"
        case .connecting, .disconnecting:
            return "Cancel"
        case .disconnected, .error, .none:
            // A phone shows the route choice right under the button, so
            // "Auto" there says what "Auto Connect" said.
            return connectBarViewModel.autoRouting && !isCompactWidth ? "Auto Connect" : "Connect"
        }
    }

    private var sessionActionDisabled: Bool {
        if connectBarViewModel.isAutoAttemptInProgress { return false }
        switch sessionState {
        case .connecting, .disconnecting, .connected:
            return false
        case .disconnected, .error, .none:
            // The destination is judged by what is in the field, which
            // Connect commits; the bar's own copy is stale until then.
            return !isConnected || destinationValidationIsBlocking || nonDestinationValidationError != nil
        }
    }

    private var destinationValidationIsBlocking: Bool {
        switch destinationPickerViewModel.validationState {
        case .empty, .invalid:
            return true
        case .valid:
            return false
        }
    }

    private var nonDestinationValidationError: String? {
        connectBarViewModel.validationErrors.first { !$0.lowercased().contains("destination") }
    }

    private func handleSessionAction() {
        if connectBarViewModel.isAutoAttemptInProgress {
            onStopAutoConnect()
            return
        }
        switch sessionState {
        case .connected:
            onDisconnect()
        case .connecting, .disconnecting:
            onForceDisconnect()
        case .disconnected, .error, .none:
            // Typing commits nothing, so what is in the field becomes the
            // destination now, when the operator asks to connect to it.
            if let typed = destinationPickerViewModel.typedDestination,
               typed != CallsignValidator.normalize(connectBarViewModel.toCall) {
                connectBarViewModel.applySuggestedTo(typed)
            }
            // Auto-routing (the default) runs the cross-family ladder. A forced
            // Digi with no path typed is still ambiguous enough to auto-route.
            if connectBarViewModel.autoRouting
                || (connectBarViewModel.mode == .ax25ViaDigi
                    && connectBarViewModel.viaDigipeaters.isEmpty) {
                onAutoConnect()
            } else {
                onConnectBarConnect()
            }
        }
    }

    // MARK: Legacy primary action (kept for InlineConnectBar compatibility)

    private var primaryActionTitle: String {
        if connectionMode == .datagram { return "Send" }
        return sessionActionTitle
    }

    private var primaryActionDisabled: Bool {
        if connectionMode == .datagram { return !canSendMessage || !isConnected }
        return sessionActionDisabled
    }

    private func handlePrimaryAction() {
        if connectionMode == .datagram {
            send()
            return
        }
        handleSessionAction()
    }

    /// Sends, and if that emptied the box while the field is being edited,
    /// ends the edit and starts a fresh one.
    ///
    /// Return sends with the field still being edited. The send clears the
    /// draft and the text on screen, but the field keeps the line it held as
    /// its value until the edit ends. When the link then dropped and the field
    /// was disabled, the edit was dropped and the field showed the sent line
    /// again over an empty draft: Return did nothing and Send sent a blank
    /// line (smoke run 2026-10-03-1, issue 77). Ending the edit commits the
    /// empty box, and the cursor goes straight back for the next line.
    private func send() {
        onSend()
        guard composeText.isEmpty, isTextFieldFocused else { return }
        isTextFieldFocused = false
        DispatchQueue.main.async { isTextFieldFocused = true }
    }

    private var showsInputModeSwitch: Bool {
        connectionMode == .connected && onRawKey != nil
    }

    /// Raw keys and control bytes need a link to go out on, and nothing
    /// else: unlike Send, they do not depend on what is in the message box.
    private var sessionIsUp: Bool {
        connectionMode == .connected && sessionState == .connected
    }

    private var isRawMode: Bool {
        showsInputModeSwitch && inputMode.wrappedValue == .raw
    }

    /// One control byte, sent at once, in either mode. In Raw mode it goes
    /// through the raw buffer so it follows what was typed before it.
    private func controlCharacterMenu(_ send: @escaping (UInt8) -> Void) -> some View {
        Menu {
            Section("Send Now") {
                Button("Ctrl-C (interrupt)") { send(0x03) }
                Button("Ctrl-D (end of input)") { send(0x04) }
                Button("Ctrl-Z (end of message)") { send(0x1A) }
                Button("Esc") { send(0x1B) }
            }
            if isRawMode {
                Divider()
                Toggle("Local Echo", isOn: $rawLocalEcho)
            }
        } label: {
            Image(systemName: "control")
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .disabled(!isConnected || !sessionIsUp)
        .help(isRawMode
              ? "Send a control character now, or turn Local Echo off for a station that echoes what you type."
              : "Send a control character now, on its own. The message box is left as it is.")
        .accessibilityLabel("Control Characters")
        .accessibilityIdentifier("terminalControlMenu")
    }

    /// Whether the phone's accessory menu has anything in it.
    private var hasComposeAccessories: Bool {
        showsInputModeSwitch
            || (onSendControl != nil && connectionMode == .connected)
            || (onInsertPosition != nil && !isRawMode)
            || (onToggleCapture != nil && (isCapturing || sessionIsUp))
    }

    /// Line/Raw, control keys, position and capture in one button, for a
    /// phone. The label turns red while a capture runs, so it can always be
    /// seen and stopped.
    private var composeAccessoryMenu: some View {
        Menu {
            if showsInputModeSwitch {
                Picker("Input", selection: inputMode) {
                    ForEach(TerminalInputMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }
            if let onSendControl, connectionMode == .connected {
                Section("Send Now") {
                    Button("Ctrl-C (interrupt)") { onSendControl(0x03) }
                    Button("Ctrl-D (end of input)") { onSendControl(0x04) }
                    Button("Ctrl-Z (end of message)") { onSendControl(0x1A) }
                    Button("Esc") { onSendControl(0x1B) }
                }
                .disabled(!isConnected || !sessionIsUp)
                if isRawMode {
                    Toggle("Local Echo", isOn: $rawLocalEcho)
                }
            }
            if let onInsertPosition, !isRawMode {
                Button("Insert Position", systemImage: "location") { onInsertPosition() }
                    .disabled(!isConnected || !canTypeMessage)
            }
            if let onToggleCapture, isCapturing || sessionIsUp {
                Button(isCapturing ? "Stop Capture" : "Capture",
                       systemImage: isCapturing ? "stop.circle" : "record.circle") { onToggleCapture() }
            }
        } label: {
            Image(systemName: isCapturing ? "record.circle.fill" : "plus.circle")
                .font(.title3)
                .foregroundStyle(isCapturing ? Color.red : Color.accentColor)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(isCapturing ? "Message options, capturing" : "Message options")
        .accessibilityIdentifier("terminalComposeOptions")
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
