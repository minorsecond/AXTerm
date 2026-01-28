//
//  SettingsView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: KISSTcpClient
    let packetStore: PacketStore?

    @State private var showingClearConfirmation = false
    @State private var clearFeedback: String?

    private let retentionStep = 1_000

    var body: some View {
        Form {
            Section("Connection") {
                TextField("KISS Host", text: $settings.host)
                    .textFieldStyle(.roundedBorder)

                TextField("KISS Port", text: $settings.port)
                    .textFieldStyle(.roundedBorder)

                if shouldSuggestReconnect {
                    Text("Reconnect to apply host/port changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("History") {
                Toggle("Persist history", isOn: $settings.persistHistory)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Retention limit")
                        Spacer()
                        Text("\(settings.retentionLimit) packets")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.retentionLimit,
                            format: .number
                        )
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Retention limit")

                        Stepper(
                            "",
                            value: $settings.retentionLimit,
                            in: AppSettingsStore.minRetention...AppSettingsStore.maxRetention,
                            step: retentionStep
                        )
                        .labelsHidden()
                    }

                    Text("Adjust how many packets are retained on disk. Older packets are pruned in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.persistHistory)

                HStack {
                    Button("Clear History…") {
                        showingClearConfirmation = true
                    }

                    if let feedback = clearFeedback {
                        Text(feedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .confirmationDialog(
            "Clear all stored packet history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                clearHistory()
            }
        } message: {
            Text("This removes all persisted packets. Live packets will continue to appear.")
        }
    }

    private var shouldSuggestReconnect: Bool {
        guard client.status == .connected else { return false }
        if let connectedHost = client.connectedHost, connectedHost != settings.host {
            return true
        }
        if let connectedPort = client.connectedPort, connectedPort != settings.portValue {
            return true
        }
        return false
    }

    private func clearHistory() {
        clearFeedback = nil
        DispatchQueue.global(qos: .utility).async { [packetStore] in
            do {
                try packetStore?.deleteAll()
            } catch {
                return
            }
            DispatchQueue.main.async {
                client.clearPackets()
                client.clearStations()
                clearFeedback = "Cleared"
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    clearFeedback = nil
                }
            }
        }
    }
}

#Preview {
    SettingsView(
        settings: AppSettingsStore(),
        client: KISSTcpClient(settings: AppSettingsStore()),
        packetStore: nil
    )
}
