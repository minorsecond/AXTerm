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
    
    @State private var showSettingsPopover = false
    
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
    
    @ViewBuilder
    private var content: some View {
        if settings.adaptiveTransmissionEnabled {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.caption2)
                    .foregroundStyle(.green)
                
                Text("Adaptive")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                
                // Separator
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                Text(kValueString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Text(pValueString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.1))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.green.opacity(0.2), lineWidth: 0.5)
            )
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
    
    private var kValueString: String {
        "K\(sessionCoordinator.globalAdaptiveSettings.windowSize.effectiveValue)"
    }
    
    private var pValueString: String {
        "P\(sessionCoordinator.globalAdaptiveSettings.paclen.effectiveValue)"
    }
    
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adaptive Transmission")
                .font(.headline)
            
            Text("Optimizes window size (K) and packet length (P) based on link quality.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 220, alignment: .leading)
            
            Divider()
            
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
                        Text("\(sessionCoordinator.globalAdaptiveSettings.windowSize.effectiveValue)")
                            .monospaced()
                    }
                    .font(.caption)
                    
                    HStack {
                        Text("Packet Size (P):")
                        Spacer()
                        Text("\(sessionCoordinator.globalAdaptiveSettings.paclen.effectiveValue)")
                            .monospaced()
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)
            }
            
            if #available(macOS 14.0, *) {
                AdaptiveConfigureButton14(showPopover: $showSettingsPopover)
            } else {
                Button("Configure…") {
                    showSettingsPopover = false
                    SettingsRouter.shared.navigate(to: .transmission, section: .adaptiveTransmission)
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
        Button("Configure…") {
            showPopover = false
            // Use router to set state before opening
            SettingsRouter.shared.selectedTab = .transmission
            SettingsRouter.shared.highlightSection = .adaptiveTransmission
            
            // Programmatically open settings using the environment action
            Task {
                try? await openSettings()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
