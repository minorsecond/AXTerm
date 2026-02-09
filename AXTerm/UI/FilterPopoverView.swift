//
//  FilterPopoverView.swift
//  AXTerm
//
//  Filter popover for consolidated global packet filtering controls.
//  Replaces individual pill buttons with a single organized menu.
//

import SwiftUI

/// Popover view for packet filtering controls
/// Consolidates frame type filters and additional filters into a single, organized interface
struct FilterPopoverView: View {
    @Binding var filters: PacketFilters
    var hasPackets: Bool
    var hasPinnedPackets: Bool
    var onReset: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Frame Type section
            VStack(alignment: .leading, spacing: 8) {
                Text("Frame Types")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Toggle("UI Frames", isOn: $filters.showUI)
                    .disabled(!hasPackets)
                Toggle("I Frames", isOn: $filters.showI)
                    .disabled(!hasPackets)
                Toggle("S Frames", isOn: $filters.showS)
                    .disabled(!hasPackets)
                Toggle("U Frames", isOn: $filters.showU)
                    .disabled(!hasPackets)
            }
            
            Divider()
            
            // Additional Filters section
            VStack(alignment: .leading, spacing: 8) {
                Text("Additional Filters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Toggle("Payload Only", isOn: $filters.payloadOnly)
                    .disabled(!hasPackets)
                    .help("Show only I frames and UI frames with payload")
                Toggle("Pinned Only", isOn: $filters.onlyPinned)
                    .disabled(!hasPinnedPackets)
                    .help("Show only pinned packets")
            }
            
            Divider()
            
            // Reset button
            Button("Reset Filters") {
                onReset()
            }
            .disabled(filters == PacketFilters())
            .help("Reset all filters to default values")
        }
        .padding(12)
        .frame(width: 220)
    }
}

#Preview {
    FilterPopoverView(
        filters: .constant(PacketFilters()),
        hasPackets: true,
        hasPinnedPackets: true,
        onReset: {}
    )
}
