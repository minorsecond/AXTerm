//
//  LinkLayerSettingsView.swift
//  AXTerm
//
//  Capability-gated Link Layer settings for AX.25 connected mode.
//  Shows tunable parameters when TNC mode supports it (KISS),
//  or a disabled info block when TNC manages the link layer (host mode).
//

import SwiftUI

struct LinkLayerSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @Binding var txAdaptiveSettings: TxAdaptiveSettings
    let syncToCoordinator: () -> Void

    var body: some View {
        if settings.tncCapabilities.supportsLinkTuning {
            supportedContent
        } else {
            unsupportedContent
        }
    }

    @ViewBuilder
    private var supportedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            adaptiveSettingRow(
                title: "Packet Length (PACLEN)",
                setting: txAdaptiveSettings.paclen,
                onToggle: {
                    txAdaptiveSettings.paclen.mode = txAdaptiveSettings.paclen.mode == .auto ? .manual : .auto
                    syncToCoordinator()
                },
                onValueChange: {
                    txAdaptiveSettings.paclen.manualValue = $0
                    syncToCoordinator()
                }
            )

            adaptiveSettingRow(
                title: "Window Size (K)",
                setting: txAdaptiveSettings.windowSize,
                onToggle: {
                    txAdaptiveSettings.windowSize.mode = txAdaptiveSettings.windowSize.mode == .auto ? .manual : .auto
                    syncToCoordinator()
                },
                onValueChange: {
                    txAdaptiveSettings.windowSize.manualValue = $0
                    syncToCoordinator()
                }
            )

            adaptiveSettingRow(
                title: "Max Retries (N2)",
                setting: txAdaptiveSettings.maxRetries,
                onToggle: {
                    txAdaptiveSettings.maxRetries.mode = txAdaptiveSettings.maxRetries.mode == .auto ? .manual : .auto
                    syncToCoordinator()
                },
                onValueChange: {
                    txAdaptiveSettings.maxRetries.manualValue = $0
                    syncToCoordinator()
                }
            )
        }
        .padding(.vertical, 4)

        Text("In KISS mode, AXTerm manages the AX.25 link layer. Parameters update automatically when Adaptive is enabled, or use Manual to set fixed values.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var unsupportedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("This TNC manages AX.25 link settings internally.")
                    .foregroundStyle(.secondary)
            }

            Text("PACLEN, window size, and retry parameters are controlled by the TNC in host mode. Switch to KISS mode to tune these from AXTerm.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Open Connection Settings\u{2026}") {
                SettingsRouter.shared.navigate(to: .network)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func adaptiveSettingRow(
        title: String,
        setting: AdaptiveSetting<Int>,
        onToggle: @escaping () -> Void,
        onValueChange: @escaping (Int) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Picker("Mode", selection: Binding(
                    get: { setting.mode },
                    set: { _ in onToggle() }
                )) {
                    Text("Auto").tag(AdaptiveMode.auto)
                    Text("Manual").tag(AdaptiveMode.manual)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .labelsHidden()

                if setting.mode == .auto {
                    Text("\(setting.currentAdaptive)")
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .frame(width: 50, alignment: .trailing)
                } else {
                    TextField("", value: Binding(
                        get: { setting.manualValue },
                        set: { onValueChange($0) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                }
            }
        }
    }
}
