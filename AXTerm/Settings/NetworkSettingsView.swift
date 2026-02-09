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

    var body: some View {
        Form {
            PreferencesSection("Routes") {
                Toggle("Hide expired routes from list", isOn: $settings.hideExpiredRoutes)
                
                Text("When enabled, routes with 0% freshness are hidden from the Routes page. All routes are still kept in the database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
