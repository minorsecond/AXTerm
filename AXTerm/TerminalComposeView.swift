//
//  TerminalComposeView.swift
//  AXTerm
//
//  Terminal TX compose view with message input and queue status.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.5
//

import SwiftUI

// MARK: - Connection Mode Toggle

/// A Mac-native toggle for switching between datagram and connected modes
struct ConnectionModeToggle: View {
    @Binding var mode: TxConnectionMode
    let sessionState: AX25SessionState?
    let onDisconnect: () -> Void

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

/// Shows current session state with visual indicator
struct SessionStatusBadge: View {
    let state: AX25SessionState?
    let destinationCall: String
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Status indicator dot
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)

            // Status text
            Text(stateText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(stateColor == .green ? .primary : .secondary)

            // Disconnect button when connected
            if state == .connected {
                Button {
                    onDisconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Disconnect from \(destinationCall)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(stateColor.opacity(0.1))
        .clipShape(Capsule())
        .help(stateHelp)
    }

    private var stateColor: Color {
        switch state {
        case .disconnected, nil:
            return .secondary
        case .connecting, .disconnecting:
            return .orange
        case .connected:
            return .green
        case .error:
            return .red
        }
    }

    private var stateText: String {
        switch state {
        case .disconnected, nil:
            return "Not Connected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .disconnecting:
            return "Disconnecting..."
        case .error:
            return "Error"
        }
    }

    private var stateHelp: String {
        switch state {
        case .disconnected, nil:
            return "No active session"
        case .connecting:
            return "Sending SABM, waiting for UA..."
        case .connected:
            return "Session active - click × to disconnect"
        case .disconnecting:
            return "Sending DISC, waiting for UA..."
        case .error:
            return "Session error - try reconnecting"
        }
    }
}

/// Compose box for terminal TX functionality
struct TerminalComposeView: View {
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

    let onSend: () -> Void
    let onClear: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            // Address bar
            HStack(spacing: 12) {
                // From (source) - display only
                HStack(spacing: 4) {
                    Text("From:")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Text(sourceCall.isEmpty ? "NOCALL" : sourceCall)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 10))

                // Destination callsign
                HStack(spacing: 4) {
                    Text("To:")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    TextField("Callsign", text: $destinationCall)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 70)
                        .textCase(.uppercase)
                }

                // Digi path
                HStack(spacing: 4) {
                    Text("Via:")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    TextField("Path", text: $digiPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 100)
                        .textCase(.uppercase)
                }

                Spacer()

                // Connection mode toggle
                ConnectionModeToggle(
                    mode: $connectionMode,
                    sessionState: sessionState,
                    onDisconnect: onDisconnect
                )

                // Session status (for connected mode)
                if connectionMode == .connected {
                    SessionStatusBadge(
                        state: sessionState,
                        destinationCall: destinationCall,
                        onDisconnect: onDisconnect
                    )
                }

                // Queue depth indicator
                if queueDepth > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.full")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("\(queueDepth)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .help("Frames queued for transmission")
                }

                // Character count
                Text("\(characterCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .help("Character count")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Message input area
            HStack(spacing: 10) {
                TextField("Message...", text: $composeText)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        if canSendMessage && isConnected {
                            onSend()
                        }
                    }
                    .disabled(!isConnected || !canTypeMessage)

                // Action buttons
                HStack(spacing: 6) {
                    // Clear button
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(composeText.isEmpty)
                    .help("Clear message")
                    .opacity(composeText.isEmpty ? 0.3 : 1)

                    // Send or Connect button
                    if connectionMode == .connected && sessionState != .connected {
                        // Need to connect first
                        Button {
                            onConnect()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                Text("Connect")
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(!isConnected || destinationCall.isEmpty)
                        .help("Establish session with \(destinationCall.isEmpty ? "destination" : destinationCall)")
                    } else {
                        // Can send directly
                        Button {
                            onSend()
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(!canSendMessage || !isConnected)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send message (⌘ Return)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Computed Properties

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
        digiPath: .constant("WIDE1-1"),
        composeText: .constant("Hello World"),
        connectionMode: .constant(.datagram),
        useAXDP: .constant(false),
        sourceCall: "MYCALL",
        canSend: true,
        characterCount: 11,
        queueDepth: 2,
        isConnected: true,
        sessionState: nil,
        onSend: {},
        onClear: {},
        onConnect: {},
        onDisconnect: {}
    )
    .frame(width: 700)
}

#Preview("Compose View - Connected") {
    TerminalComposeView(
        destinationCall: .constant("N0CALL"),
        digiPath: .constant("WIDE1-1"),
        composeText: .constant("Hello World"),
        connectionMode: .constant(.connected),
        useAXDP: .constant(false),
        sourceCall: "MYCALL",
        canSend: true,
        characterCount: 11,
        queueDepth: 0,
        isConnected: true,
        sessionState: .connected,
        onSend: {},
        onClear: {},
        onConnect: {},
        onDisconnect: {}
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
        onSend: {},
        onClear: {},
        onConnect: {},
        onDisconnect: {}
    )
    .frame(width: 700)
}

#Preview("Mode Toggle") {
    VStack(spacing: 20) {
        ConnectionModeToggle(
            mode: .constant(.datagram),
            sessionState: nil,
            onDisconnect: {}
        )

        ConnectionModeToggle(
            mode: .constant(.connected),
            sessionState: .connected,
            onDisconnect: {}
        )
    }
    .padding()
}

#Preview("Session Status Badges") {
    VStack(spacing: 12) {
        SessionStatusBadge(state: nil, destinationCall: "N0CALL", onDisconnect: {})
        SessionStatusBadge(state: .connecting, destinationCall: "N0CALL", onDisconnect: {})
        SessionStatusBadge(state: .connected, destinationCall: "N0CALL", onDisconnect: {})
        SessionStatusBadge(state: .disconnecting, destinationCall: "N0CALL", onDisconnect: {})
        SessionStatusBadge(state: .error, destinationCall: "N0CALL", onDisconnect: {})
    }
    .padding()
}
