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
    let consoleStore: ConsoleStore?
    let rawStore: RawStore?
    let eventLogger: EventLogger?

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
                        Text("Packet retention")
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Console retention")
                        Spacer()
                        Text("\(settings.consoleRetentionLimit) lines")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.consoleRetentionLimit,
                            format: .number
                        )
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Console retention")

                        Stepper(
                            "",
                            value: $settings.consoleRetentionLimit,
                            in: AppSettingsStore.minLogRetention...AppSettingsStore.maxLogRetention,
                            step: retentionStep
                        )
                        .labelsHidden()
                    }

                    Text("Console history includes system messages and packet summaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.persistHistory)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Raw retention")
                        Spacer()
                        Text("\(settings.rawRetentionLimit) chunks")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.rawRetentionLimit,
                            format: .number
                        )
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Raw retention")

                        Stepper(
                            "",
                            value: $settings.rawRetentionLimit,
                            in: AppSettingsStore.minLogRetention...AppSettingsStore.maxLogRetention,
                            step: retentionStep
                        )
                        .labelsHidden()
                    }

                    Text("Raw history stores KISS byte streams and parse errors.")
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

            Section("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Event retention")
                        Spacer()
                        Text("\(settings.eventRetentionLimit) events")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.eventRetentionLimit,
                            format: .number
                        )
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Event retention")

                        Stepper(
                            "",
                            value: $settings.eventRetentionLimit,
                            in: AppSettingsStore.minLogRetention...AppSettingsStore.maxLogRetention,
                            step: retentionStep
                        )
                        .labelsHidden()
                    }

                    Text("Diagnostics entries are retained separately from packet history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Display") {
                Toggle("Console day separators", isOn: $settings.showConsoleDaySeparators)
                Toggle("Raw day separators", isOn: $settings.showRawDaySeparators)
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
            Text("This removes persisted packets, console history, and raw history. Live data will continue to appear.")
        }
        .onChange(of: settings.retentionLimit) { _, newValue in
            eventLogger?.log(
                level: .info,
                category: .settings,
                message: "Packet retention set to \(newValue)",
                metadata: ["retention": "\(newValue)"]
            )
        }
        .onChange(of: settings.consoleRetentionLimit) { _, newValue in
            eventLogger?.log(
                level: .info,
                category: .settings,
                message: "Console retention set to \(newValue)",
                metadata: ["retention": "\(newValue)"]
            )
        }
        .onChange(of: settings.rawRetentionLimit) { _, newValue in
            eventLogger?.log(
                level: .info,
                category: .settings,
                message: "Raw retention set to \(newValue)",
                metadata: ["retention": "\(newValue)"]
            )
        }
        .onChange(of: settings.eventRetentionLimit) { _, newValue in
            eventLogger?.log(
                level: .info,
                category: .settings,
                message: "Event retention set to \(newValue)",
                metadata: ["retention": "\(newValue)"]
            )
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
        DispatchQueue.global(qos: .utility).async { [packetStore, consoleStore, rawStore] in
            do {
                try packetStore?.deleteAll()
                try consoleStore?.deleteAll()
                try rawStore?.deleteAll()
            } catch {
                return
            }
            DispatchQueue.main.async {
                client.clearPackets()
                client.clearStations()
                client.clearConsole(clearPersisted: false)
                client.clearRaw(clearPersisted: false)
                clearFeedback = "Cleared"
                eventLogger?.log(level: .info, category: .ui, message: "Cleared history", metadata: nil)
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
        packetStore: nil,
        consoleStore: nil,
        rawStore: nil,
        eventLogger: nil
    )
}
