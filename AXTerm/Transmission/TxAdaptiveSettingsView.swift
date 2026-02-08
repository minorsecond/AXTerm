//
//  TxAdaptiveSettingsView.swift
//  AXTerm
//
//  SwiftUI views for adaptive transmission settings.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4.1
//
//  Settings UX requirement (from spec):
//  - Mode: Auto / Manual per parameter
//  - If Manual: value picker enabled
//  - If Auto: show "Current" + "Suggested" + "Reason"
//

import SwiftUI

// MARK: - Adaptive Setting Row

/// Row for displaying/editing a single adaptive setting (Int)
struct AdaptiveSettingIntRow: View {
    let title: String
    let setting: AdaptiveSetting<Int>
    let onModeToggle: () -> Void
    let onValueChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                // Mode toggle
                Picker("Mode", selection: Binding(
                    get: { setting.mode },
                    set: { _ in onModeToggle() }
                )) {
                    Text("Auto").tag(AdaptiveMode.auto)
                    Text("Manual").tag(AdaptiveMode.manual)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            if setting.mode == .auto {
                // Auto mode: show current + reason
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(setting.currentAdaptive)")
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                    }

                    Spacer()

                    if let reason = setting.adaptiveReason {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Reason")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
            } else {
                // Manual mode: show value picker
                if let range = setting.range {
                    HStack {
                        Text("Value:")
                            .foregroundStyle(.secondary)

                        TextField("", value: Binding(
                            get: { setting.manualValue },
                            set: { onValueChange($0) }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)

                        Stepper("", value: Binding(
                            get: { setting.manualValue },
                            set: { onValueChange($0) }
                        ), in: range)
                        .labelsHidden()

                        Spacer()

                        Text("Range: \(range.lowerBound)-\(range.upperBound)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Row for displaying/editing a single adaptive setting (Double)
struct AdaptiveSettingDoubleRow: View {
    let title: String
    let setting: AdaptiveSetting<Double>
    let unit: String
    let onModeToggle: () -> Void
    let onValueChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                // Mode toggle
                Picker("Mode", selection: Binding(
                    get: { setting.mode },
                    set: { _ in onModeToggle() }
                )) {
                    Text("Auto").tag(AdaptiveMode.auto)
                    Text("Manual").tag(AdaptiveMode.manual)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            if setting.mode == .auto {
                // Auto mode: show current + reason
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f%@", setting.currentAdaptive, unit))
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                    }

                    Spacer()

                    if let reason = setting.adaptiveReason {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Reason")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
            } else {
                // Manual mode: show value slider
                if let range = setting.range {
                    HStack {
                        Text("Value:")
                            .foregroundStyle(.secondary)

                        Slider(
                            value: Binding(
                                get: { setting.manualValue },
                                set: { onValueChange($0) }
                            ),
                            in: range,
                            step: 0.5
                        )

                        Text(String(format: "%.1f%@", setting.manualValue, unit))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Main Settings View

/// Main view for TX adaptive settings
struct TxAdaptiveSettingsView: View {
    @Binding var settings: TxAdaptiveSettings

    var body: some View {
        Form {
            // Traffic Shaping Section
            Section("Traffic Shaping") {
                AdaptiveSettingIntRow(
                    title: "Packet Length",
                    setting: settings.paclen,
                    onModeToggle: {
                        settings.paclen.mode = settings.paclen.mode == .auto ? .manual : .auto
                    },
                    onValueChange: { settings.paclen.manualValue = $0 }
                )

                AdaptiveSettingIntRow(
                    title: "Window Size (K)",
                    setting: settings.windowSize,
                    onModeToggle: {
                        settings.windowSize.mode = settings.windowSize.mode == .auto ? .manual : .auto
                    },
                    onValueChange: { settings.windowSize.manualValue = $0 }
                )

                AdaptiveSettingIntRow(
                    title: "Max Retries (N2)",
                    setting: settings.maxRetries,
                    onModeToggle: {
                        settings.maxRetries.mode = settings.maxRetries.mode == .auto ? .manual : .auto
                    },
                    onValueChange: { settings.maxRetries.manualValue = $0 }
                )
            }

            // RTO Section
            Section("Retransmission Timeout") {
                AdaptiveSettingDoubleRow(
                    title: "Min RTO",
                    setting: settings.rtoMin,
                    unit: "s",
                    onModeToggle: {
                        settings.rtoMin.mode = settings.rtoMin.mode == .auto ? .manual : .auto
                    },
                    onValueChange: { settings.rtoMin.manualValue = $0 }
                )

                AdaptiveSettingDoubleRow(
                    title: "Max RTO",
                    setting: settings.rtoMax,
                    unit: "s",
                    onModeToggle: {
                        settings.rtoMax.mode = settings.rtoMax.mode == .auto ? .manual : .auto
                    },
                    onValueChange: { settings.rtoMax.manualValue = $0 }
                )
            }

            // AXDP Section
            Section("AXDP Protocol") {
                Toggle("Enable AXDP Extensions", isOn: $settings.axdpExtensionsEnabled)

                Toggle("Auto-negotiate Capabilities", isOn: $settings.autoNegotiateCapabilities)
                    .disabled(!settings.axdpExtensionsEnabled)

                Toggle("Enable Compression", isOn: $settings.compressionEnabled)
                    .disabled(!settings.axdpExtensionsEnabled)

                if settings.compressionEnabled && settings.axdpExtensionsEnabled {
                    Picker("Compression Algorithm", selection: $settings.compressionAlgorithm) {
                        Text("LZ4 (fast)").tag(AXDPCompression.Algorithm.lz4)
                        Text("Deflate (better ratio)").tag(AXDPCompression.Algorithm.deflate)
                    }
                }
            }

            // Debug Section
            Section("Debug") {
                Toggle("Show AXDP decode details", isOn: $settings.showAXDPDecodeDetails)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Compact Settings Summary

/// Compact summary view for adaptive settings (for use in toolbar or status bar)
struct TxAdaptiveSettingsSummary: View {
    let settings: TxAdaptiveSettings

    var body: some View {
        HStack(spacing: 12) {
            // Paclen indicator
            HStack(spacing: 4) {
                Image(systemName: settings.paclen.mode == .auto ? "gearshape" : "hand.raised")
                    .font(.caption)
                    .foregroundStyle(settings.paclen.mode == .auto ? .blue : .orange)
                Text("P:\(settings.paclen.effectiveValue)")
                    .font(.system(.caption, design: .monospaced))
            }
            .help(paclenTooltip)

            // Window indicator
            HStack(spacing: 4) {
                Image(systemName: settings.windowSize.mode == .auto ? "gearshape" : "hand.raised")
                    .font(.caption)
                    .foregroundStyle(settings.windowSize.mode == .auto ? .blue : .orange)
                Text("K:\(settings.windowSize.effectiveValue)")
                    .font(.system(.caption, design: .monospaced))
            }
            .help(windowTooltip)

            // Compression indicator
            if settings.compressionEnabled {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(compressionLabel)
                        .font(.caption)
                }
                .help("Compression enabled")
            }
        }
    }

    private var paclenTooltip: String {
        var tip = "Packet Length: \(settings.paclen.effectiveValue) bytes"
        if settings.paclen.mode == .auto {
            tip += " (Auto)"
            if let reason = settings.paclen.adaptiveReason {
                tip += "\n\(reason)"
            }
        } else {
            tip += " (Manual)"
        }
        return tip
    }

    private var windowTooltip: String {
        var tip = "Window Size: \(settings.windowSize.effectiveValue) frames"
        if settings.windowSize.mode == .auto {
            tip += " (Auto)"
            if let reason = settings.windowSize.adaptiveReason {
                tip += "\n\(reason)"
            }
        } else {
            tip += " (Manual)"
        }
        return tip
    }

    private var compressionLabel: String {
        switch settings.compressionAlgorithm {
        case .none: return "None"
        case .lz4: return "LZ4"
        case .zstd: return "ZSTD"
        case .deflate: return "Defl"
        }
    }
}

// MARK: - Preview

#Preview("Adaptive Settings") {
    struct PreviewWrapper: View {
        @State private var settings = TxAdaptiveSettings()

        var body: some View {
            TxAdaptiveSettingsView(settings: $settings)
                .frame(width: 500, height: 600)
        }
    }
    return PreviewWrapper()
}

#Preview("Settings Summary") {
    TxAdaptiveSettingsSummary(settings: TxAdaptiveSettings())
        .padding()
}
