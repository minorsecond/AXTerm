//
//  TerminalComposeView.swift
//  AXTerm
//
//  Terminal TX compose view with message input and queue status.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.5
//

import SwiftUI

/// Compose box for terminal TX functionality
struct TerminalComposeView: View {
    @Binding var destinationCall: String
    @Binding var digiPath: String
    @Binding var composeText: String

    let sourceCall: String
    let canSend: Bool
    let characterCount: Int
    let queueDepth: Int
    let isConnected: Bool

    let onSend: () -> Void
    let onClear: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            // Address bar
            HStack(spacing: 8) {
                // From (source) - display only
                HStack(spacing: 4) {
                    Text("From:")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(sourceCall.isEmpty ? "NOCALL" : sourceCall)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                }

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                // Destination callsign
                HStack(spacing: 4) {
                    Text("To:")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Callsign", text: $destinationCall)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 80)
                        .textCase(.uppercase)
                }

                // Digi path
                HStack(spacing: 4) {
                    Text("Via:")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Path", text: $digiPath)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 120)
                        .textCase(.uppercase)
                }

                Spacer()

                // Queue depth indicator
                if queueDepth > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.full")
                            .foregroundStyle(.orange)
                        Text("\(queueDepth)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help("Frames queued for transmission")
                }

                // Character count
                Text("\(characterCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("Character count")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Message input
            HStack(spacing: 8) {
                TextField("Message...", text: $composeText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...3)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        if canSend {
                            onSend()
                        }
                    }
                    .disabled(!isConnected)

                // Action buttons
                VStack(spacing: 4) {
                    Button(action: onSend) {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canSend || !isConnected)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send message (Cmd+Return)")

                    Button(action: onClear) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(composeText.isEmpty)
                    .help("Clear message")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background)
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

#Preview("Compose View") {
    TerminalComposeView(
        destinationCall: .constant("N0CALL"),
        digiPath: .constant("WIDE1-1"),
        composeText: .constant("Hello World"),
        sourceCall: "MYCALL",
        canSend: true,
        characterCount: 11,
        queueDepth: 2,
        isConnected: true,
        onSend: {},
        onClear: {}
    )
    .frame(width: 600)
}
