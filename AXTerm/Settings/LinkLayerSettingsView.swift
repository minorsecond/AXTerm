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
        VStack(alignment: .leading, spacing: 14) {
            t1TimeoutContent
            if settings.tncCapabilities.supportsLinkTuning {
                supportedContent
            } else {
                unsupportedContent
            }
        }
    }

    @ViewBuilder
    private var t1TimeoutContent: some View {
        LabeledContent("T1 Retransmit Timeout") {
            HStack(spacing: 8) {
                TextField(
                    "",
                    value: $settings.ax25T1TimeoutSeconds,
                    format: .number.precision(.fractionLength(1))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .onChange(of: settings.ax25T1TimeoutSeconds) { _, _ in
                    syncToCoordinator()
                }

                Text("s")
                    .foregroundStyle(.secondary)

                Stepper(
                    "",
                    value: $settings.ax25T1TimeoutSeconds,
                    in: AppSettingsStore.minAX25T1TimeoutSeconds...AppSettingsStore.maxAX25T1TimeoutSeconds,
                    step: 0.5
                )
                .labelsHidden()
                .onChange(of: settings.ax25T1TimeoutSeconds) { _, _ in
                    syncToCoordinator()
                }
            }
        }

        Text("Guardrails: \(Int(AppSettingsStore.minAX25T1TimeoutSeconds))-\(Int(AppSettingsStore.maxAX25T1TimeoutSeconds)) seconds. Larger values reduce premature retransmits on slow links; smaller values retry faster.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Negotiate AX.25 2.2 (XID / selective reject)", isOn: $settings.ax25NegotiateV22)
            .help("Before the first connect to an unknown station, offer AX.25 2.2 "
                  + "parameters via XID. A 2.2 peer agrees to selective reject "
                  + "(retransmit only the lost frame instead of the whole window) and "
                  + "exchanges packet-length and window limits. Older stations answer "
                  + "FRMR or stay silent — either way the connect proceeds classically, "
                  + "and the answer is remembered so the one-time timeout is never paid "
                  + "twice. Turn off only if a node misbehaves when it sees XID.")

        Text("Selective reject pays off on lossy paths: with plain REJ, one lost frame costs retransmitting every frame after it.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
