//
//  AdvancedSettingsView.swift
//  AXTerm
//
//  Restored by Settings Redesign on 2/8/26.
//

import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    let packetStore: PacketStore?
    let consoleStore: ConsoleStore?
    let rawStore: RawStore?
    let eventLogger: EventLogger?

    @State private var showingClearConfirmation = false
    @State private var clearFeedback: String?
    @State private var retentionStep = 1000

    var body: some View {
        Form {
            Section("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Event retention")
                        Spacer()
                        Text("\(settings.eventRetentionLimit) events")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        GuardedRetentionInput(
                            value: $settings.eventRetentionLimit,
                            min: AppSettingsStore.minLogRetention,
                            max: AppSettingsStore.maxLogRetention,
                            step: retentionStep
                        )
                        .accessibilityLabel("Event retention")
                    }

                    Text("Controls how many application usage events are kept in the Diagnostics tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HistorySettingsView(
                settings: settings,
                onClearHistory: clearHistory,
                clearFeedback: clearFeedback
            )
            
            Section("Sentry") {
                Toggle("Enable Sentry reporting", isOn: $settings.sentryEnabled)
                Toggle("Send connection details", isOn: $settings.sentrySendConnectionDetails)
                    .disabled(!settings.sentryEnabled)
                Toggle("Send packet contents", isOn: $settings.sentrySendPacketContents)
                    .disabled(!settings.sentryEnabled)
                
                Text(SentryConfiguration.load(settings: settings).dsn == nil ? "DSN: Not configured" : "DSN: Configured")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onChange(of: settings.sentryEnabled) { _, _ in SentryManager.shared.startIfEnabled(settings: settings) }
        .onChange(of: settings.sentrySendPacketContents) { _, _ in SentryManager.shared.startIfEnabled(settings: settings) }
        .onChange(of: settings.sentrySendConnectionDetails) { _, _ in SentryManager.shared.startIfEnabled(settings: settings) }
    }
    
    private func clearHistory() {
        clearFeedback = nil
        DispatchQueue.global(qos: .utility).async { [packetStore, consoleStore, rawStore] in
            do {
                try packetStore?.deleteAll()
                try consoleStore?.deleteAll()
                try rawStore?.deleteAll()
            } catch { return }
            
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

struct HistorySettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @State private var showingClearConfirmation = false
    
    // Pass clear closure from parent
    var onClearHistory: () -> Void
    var clearFeedback: String?
    
    private let retentionStep = 1_000
    
    @State private var pendingRetentionChange: AppSettingsStore.HistoryRetentionDuration?
    @State private var showingRetentionWarning = false

    private var retentionBinding: Binding<AppSettingsStore.HistoryRetentionDuration> {
        Binding(
            get: { settings.retentionDuration },
            set: { newDuration in
                
                let newPacketLimit = newDuration.packetLimit
                let currentPacketLimit = settings.retentionLimit
                
                // If new limit is LOWER than current, warn user
                // (Unless switching to Custom, which retains current values initially, so no data loss immediately)
                if newDuration != .custom && newPacketLimit < currentPacketLimit {
                    pendingRetentionChange = newDuration
                    showingRetentionWarning = true
                } else {
                    settings.retentionDuration = newDuration
                }
            }
        )
    }

    var body: some View {
        Section {
            Toggle("Persist history", isOn: $settings.persistHistory)
            
            if settings.persistHistory {
                VStack(alignment: .leading, spacing: 12) {
                    // Primary Control
                    HStack {
                        Text("Keep history for:")
                        Spacer()
                        Picker("", selection: retentionBinding) {
                            ForEach(AppSettingsStore.HistoryRetentionDuration.allCases) { duration in
                                Text(duration.rawValue).tag(duration)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 150)
                    }
                    
                    // Status Line
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text(storageEstimateText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    

                    
                    // Custom Limits Section
                    if settings.retentionDuration == .custom {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Custom Limits")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            
                            // Packet Retention
                            advancedRetentionRow(
                                title: "Packet Limit",
                                value: $settings.retentionLimit,
                                suffix: "packets",
                                min: AppSettingsStore.minRetention
                            )
                            
                            // Console Retention
                            advancedRetentionRow(
                                title: "Console Limit",
                                value: $settings.consoleRetentionLimit,
                                suffix: "lines",
                                min: AppSettingsStore.minLogRetention
                            )
                            
                            // Raw Retention
                            advancedRetentionRow(
                                title: "Raw Limit",
                                value: $settings.rawRetentionLimit,
                                suffix: "chunks",
                                min: AppSettingsStore.minLogRetention
                            )
                        }
                        .padding(.top, 8)
                        .transition(.opacity)
                    }
                }
                
                // Clear History Action
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
                .padding(.top, 8)
            }
        } header: {
            Text("History")
        }
        .confirmationDialog(
            "Clear all stored packet history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                onClearHistory()
            }
        } message: {
            Text("This removes persisted packets, console history, and raw history. Live data will continue to appear.")
        }
        .confirmationDialog(
             "Reduce History Retention?",
             isPresented: $showingRetentionWarning,
             titleVisibility: .visible
         ) {
             Button("Reduce Retention", role: .destructive) {
                 if let newDuration = pendingRetentionChange {
                     settings.retentionDuration = newDuration
                 }
             }
             Button("Cancel", role: .cancel) {
                 pendingRetentionChange = nil
             }
         } message: {
             if let newDuration = pendingRetentionChange {
                 Text("You are reducing retention to \(newDuration.rawValue). Older history exceeding this limit will be permanently deleted.")
             } else {
                 Text("This action will permanently delete older history.")
             }
         }
    }
    
    // MARK: - Helpers
    
    private var storageEstimateText: String {
        if settings.retentionDuration == .forever {
            return "History will grow indefinitely until disk is full."
        }
        
        let packetBytes = settings.retentionLimit * AppSettingsStore.estimatedBytesPerPacket
        let consoleBytes = settings.consoleRetentionLimit * AppSettingsStore.estimatedBytesPerConsoleLine
        let rawBytes = settings.rawRetentionLimit * AppSettingsStore.estimatedBytesPerRawChunk
        
        let totalBytes = Double(packetBytes + consoleBytes + rawBytes)
        let mb = totalBytes / 1_000_000.0
        
        let sizeStr = String(format: "%.1f MB", mb)
        
        // Coverage estimate
        if settings.retentionDuration == .custom {
            // Estimate based on packet limit
            let days = settings.retentionLimit / AppSettingsStore.estimatedPacketsPerDay
            let durationStr = "~" + (days < 1 ? "<1 day" : "\(days) days")
            return "Max usage: \(sizeStr) • Estimated coverage: \(durationStr)"
        }
        
        // Use simpler text if it's a fixed duration
        return "Max usage: \(sizeStr)"
    }
    
    @ViewBuilder
    private func advancedRetentionRow(title: String, value: Binding<Int>, suffix: String, min: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    Spacer()
                if value.wrappedValue == Int.max {
                    Text("Unlimited")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    Text("\(value.wrappedValue) \(suffix)")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
            
            HStack {
                // We use our GuardedRetentionInput here for safety, logic still holds
                // (It accepts Int.max but stepper might be weird with it, so careful)
                GuardedRetentionInput(
                    value: value,
                    min: min,
                    max: Int.max, // Allow up to max
                    step: retentionStep
                )
            }
        }
    }
}
