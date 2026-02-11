//
//  NetworkSettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import SwiftUI

struct NetworkSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @EnvironmentObject var router: SettingsRouter

    private let retentionStep = 1_000
    @State private var pendingIgnoredEndpoint = ""

    var body: some View {
        Form {
            PreferencesSection("Routes") {
                Toggle("Hide expired routes from list", isOn: $settings.hideExpiredRoutes)
                
                Text("When enabled, routes with 0% freshness are hidden from the Routes page. All routes are still kept in the database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PreferencesSection("Service Endpoint Filters") {
                Text("Use this list to hide local/regional service endpoints (for example custom beacons, bulletin aliases, gateways) from graph and routing identities.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("Add endpoint (e.g. HORSE, DRLBBS)", text: $pendingIgnoredEndpoint)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let normalized = CallsignValidator.normalize(pendingIgnoredEndpoint)
                        guard !normalized.isEmpty else { return }
                        settings.addIgnoredServiceEndpoint(normalized)
                        pendingIgnoredEndpoint = ""
                    }
                    .disabled(CallsignValidator.normalize(pendingIgnoredEndpoint).isEmpty)
                }

                if settings.ignoredServiceEndpoints.isEmpty {
                    Text("No custom service endpoints ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(settings.ignoredServiceEndpoints, id: \.self) { endpoint in
                            HStack(spacing: 8) {
                                Text(endpoint)
                                    .font(.caption.monospaced())
                                Spacer()
                                Button("Remove") {
                                    settings.removeIgnoredServiceEndpoint(endpoint)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            
            PreferencesSection("Stale Policy") {
                Picker("Mode", selection: $settings.stalePolicyMode) {
                    Text("Adaptive (per-origin)").tag("adaptive")
                    Text("Global (fixed TTL)").tag("global")
                }
                .pickerStyle(.segmented)
                .labelsHidden() // Often clearer in preferences if the section implies the context

                if settings.stalePolicyMode == "adaptive" {
                    Text("Routes are considered stale after missing multiple expected broadcasts from their origin. Each origin's broadcast interval is tracked automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    LabeledContent("Adaptive Threshold") {
                        HStack(spacing: 8) {
                            NumericInput(
                                "Missed",
                                value: $settings.adaptiveStaleMissedBroadcasts,
                                range: AppSettingsStore.minAdaptiveStaleMissedBroadcasts...AppSettingsStore.maxAdaptiveStaleMissedBroadcasts
                            )
                            
                            Text("missed broadcasts")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                     LabeledContent("Stale Threshold") {
                        HStack(spacing: 8) {
                            NumericInput(
                                "Hours",
                                value: $settings.globalStaleTTLHours,
                                range: AppSettingsStore.minGlobalStaleTTLHours...AppSettingsStore.maxGlobalStaleTTLHours
                            )
                            
                            Text("hours")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            PreferencesSection("Thresholds & Retention") {
                LabeledContent("Neighbor Stale Threshold") {
                    HStack(spacing: 8) {
                        NumericInput(
                            "Hours",
                            value: $settings.neighborStaleTTLHours,
                            range: AppSettingsStore.minNeighborStaleTTLHours...AppSettingsStore.maxNeighborStaleTTLHours
                        )
                        Text("hours")
                            .foregroundStyle(.secondary)
                    }
                }
                
                LabeledContent("Link Quality Stale Threshold") {
                    HStack(spacing: 8) {
                        NumericInput(
                            "Hours",
                            value: $settings.linkStatStaleTTLHours,
                            range: AppSettingsStore.minLinkStatStaleTTLHours...AppSettingsStore.maxLinkStatStaleTTLHours
                        )
                        Text("hours")
                            .foregroundStyle(.secondary)
                    }
                }
                

                
                LabeledContent("Route Retention Period") {
                    HStack(spacing: 8) {
                        NumericInput(
                            "Days",
                            value: $settings.routeRetentionDays,
                            range: AppSettingsStore.minRouteRetentionDays...AppSettingsStore.maxRouteRetentionDays,
                            step: 7
                        )
                        Text("days")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onTapGesture {
            // Clear focus when clicking background
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}
