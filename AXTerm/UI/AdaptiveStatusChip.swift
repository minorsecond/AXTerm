//
//  AdaptiveStatusChip.swift
//  AXTerm
//
//  Created for Terminal Chin Redesign
//

import SwiftUI

/// A compact status chip for displaying and configuring Adaptive Transmission parameters
struct AdaptiveStatusChip: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var sessionCoordinator: SessionCoordinator

    /// Active session destination (nil when not connected) — used to resolve per-route settings.
    var activeDestination: String? = nil
    /// Active session digi path (nil when not connected).
    var activePath: String? = nil

    @State private var showSettingsPopover = false

    /// Effective settings for display, resolving per-route cache when connected.
    private var displaySettings: TxAdaptiveSettings {
        sessionCoordinator.effectiveAdaptiveSettings(
            destination: activeDestination,
            path: activePath
        )
    }

    var body: some View {
        Button {
            showSettingsPopover.toggle()
        } label: {
            content
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSettingsPopover) {
            popoverContent
        }
        .help("Adaptive Transmission Settings")
    }

    private var hasManualOverrides: Bool {
        let a = displaySettings
        return a.windowSize.mode == .manual
            || a.paclen.mode == .manual
            || a.maxRetries.mode == .manual
    }

    @ViewBuilder
    private var content: some View {
        if !settings.tncCapabilities.supportsLinkTuning {
            // TNC manages link layer
            HStack(spacing: 6) {
                Image(systemName: "lock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("TNC Managed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        } else if settings.adaptiveTransmissionEnabled {
            if hasManualOverrides {
                // Manual overrides active
                chipBody(
                    icon: "hand.raised",
                    label: "Manual",
                    accentColor: .orange
                )
            } else {
                // Fully adaptive
                chipBody(
                    icon: "chart.line.uptrend.xyaxis",
                    label: "Adaptive",
                    accentColor: .green
                )
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("Adaptive Off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func chipBody(icon: String, label: String, accentColor: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(accentColor)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)

            Text("\u{00B7}")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(kValueString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(pValueString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(n2ValueString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(accentColor.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(accentColor.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var kValueString: String {
        "K\(displaySettings.windowSize.effectiveValue)"
    }

    private var pValueString: String {
        "P\(displaySettings.paclen.effectiveValue)"
    }

    private var n2ValueString: String {
        "N2 \(displaySettings.maxRetries.effectiveValue)"
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adaptive Transmission")
                .font(.headline)

            Text("Optimizes window size (K), packet length (P), retries (N2), and retransmit timeout (RTO) based on link quality.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 220, alignment: .leading)

            Divider()

            if !settings.tncCapabilities.supportsLinkTuning {
                Text("Link-layer parameters are managed by the TNC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Enable Adaptive", isOn: $settings.adaptiveTransmissionEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                if settings.adaptiveTransmissionEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Parameters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        HStack {
                            Text("Window (K):")
                            Spacer()
                            Text("\(displaySettings.windowSize.effectiveValue)")
                                .monospaced()
                        }
                        .font(.caption)

                        HStack {
                            Text("Packet Size (P):")
                            Spacer()
                            Text("\(displaySettings.paclen.effectiveValue)")
                                .monospaced()
                        }
                        .font(.caption)

                        HStack {
                            Text("Max Retries (N2):")
                            Spacer()
                            Text("\(displaySettings.maxRetries.effectiveValue)")
                                .monospaced()
                        }
                        .font(.caption)

                        HStack {
                            Text("Retransmit Timeout:")
                            Spacer()
                            if let rto = displaySettings.currentRto {
                                Text(String(format: "%.1fs", rto))
                                    .monospaced()
                            } else {
                                Text("—")
                                    .monospaced()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(6)
                }
            }

            if #available(macOS 14.0, *) {
                AdaptiveConfigureButton14(showPopover: $showSettingsPopover)
            } else {
                Button("Configure\u{2026}") {
                    showSettingsPopover = false
                    SettingsRouter.shared.navigate(to: .transmission, section: .linkLayer)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .frame(width: 260)
    }
}

@available(macOS 14.0, *)
fileprivate struct AdaptiveConfigureButton14: View {
    @Environment(\.openSettings) private var openSettings
    @Binding var showPopover: Bool

    var body: some View {
        Button("Configure\u{2026}") {
            showPopover = false
            SettingsRouter.shared.selectedTab = .transmission
            SettingsRouter.shared.highlightSection = .linkLayer

            openSettings()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
