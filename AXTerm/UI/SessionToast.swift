//
//  SessionToast.swift
//  AXTerm
//
//  Centralized toast-like notifications for session events.
//  Use this module when adding or changing session notification behavior.
//

import SwiftUI

// MARK: - Session Notification

/// Notification model for session state changes and peer actions.
/// Add new cases in NotificationType when introducing new toast variants.
nonisolated struct SessionNotification: Identifiable, Equatable {
    let id = UUID()
    let type: NotificationType
    let peer: String
    let message: String

    enum NotificationType {
        case connected
        case disconnected
        case error
        case peerAxdpEnabled           // Peer enabled – show Enable button to turn on
        case peerAxdpEnabledAlreadyUsing  // Peer enabled – we already have it on, no button
        case peerAxdpDisabled
    }

    var icon: String {
        switch type {
        case .connected: return "link.circle.fill"
        case .disconnected: return "link.badge.xmark"
        case .error: return "exclamationmark.triangle.fill"
        case .peerAxdpEnabled, .peerAxdpEnabledAlreadyUsing: return "bolt.fill"
        case .peerAxdpDisabled: return "bolt.slash.fill"
        }
    }

    var color: Color {
        switch type {
        case .connected: return .green
        case .disconnected: return .orange
        case .error: return .red
        case .peerAxdpEnabled, .peerAxdpEnabledAlreadyUsing: return .blue
        case .peerAxdpDisabled: return .gray
        }
    }

    /// Whether this notification type supports a primary action button (e.g. "Enable")
    var supportsPrimaryAction: Bool {
        switch type {
        case .peerAxdpEnabled: return true
        default: return false
        }
    }

    /// Default primary action label when supportsPrimaryAction is true
    var defaultPrimaryActionLabel: String? {
        switch type {
        case .peerAxdpEnabled: return "Enable"
        default: return nil
        }
    }
}

// MARK: - Session Toast View

/// Toast view for session notifications.
/// Change styling and layout here to update all session toasts app-wide.
struct SessionNotificationToast: View {
    let notification: SessionNotification
    let onDismiss: () -> Void
    /// Optional primary action (e.g. "Enable" for peerAxdpEnabled). When nil, no action button is shown.
    var primaryActionLabel: String? = nil
    var onPrimaryAction: (() -> Void)? = nil

    private var effectivePrimaryLabel: String? {
        primaryActionLabel ?? notification.defaultPrimaryActionLabel
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notification.icon)
                .font(.system(size: 20))
                .foregroundStyle(notification.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.peer)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(notification.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let label = effectivePrimaryLabel, let action = onPrimaryAction {
                Button(label) {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(notification.color.opacity(0.1))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(notification.color.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}

#Preview("Session Toast - Peer AXDP Enabled") {
    SessionNotificationToast(
        notification: SessionNotification(
            type: .peerAxdpEnabled,
            peer: "TEST-1",
            message: "has enabled AXDP – turn it on for enhanced features?"
        ),
        onDismiss: {},
        primaryActionLabel: "Enable",
        onPrimaryAction: {}
    )
    .frame(width: 380)
    .padding()
}

#Preview("Session Toast - Peer AXDP Enabled Already Using") {
    SessionNotificationToast(
        notification: SessionNotification(
            type: .peerAxdpEnabledAlreadyUsing,
            peer: "TEST-1",
            message: "has enabled AXDP – you're both using it"
        ),
        onDismiss: {}
    )
    .frame(width: 380)
    .padding()
}

#Preview("Session Toast - Peer AXDP Disabled") {
    SessionNotificationToast(
        notification: SessionNotification(
            type: .peerAxdpDisabled,
            peer: "TEST-1",
            message: "has disabled AXDP"
        ),
        onDismiss: {}
    )
    .frame(width: 380)
    .padding()
}
