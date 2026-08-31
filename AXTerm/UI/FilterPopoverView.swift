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
                    .help("Unnumbered information — beacons, IDs, APRS. Where most of the readable traffic on a channel is.")
                Toggle("I Frames", isOn: $filters.showI)
                    .disabled(!hasPackets)
                    .help("Information frames inside a connected session: the actual conversation with a BBS or node.")
                Toggle("S Frames", isOn: $filters.showS)
                    // Payload-only already excludes these, so leaving the
                    // switch live would let it be set to something it is not
                    // doing.
                    .disabled(!hasPackets || !filters.frameTypeSwitchesApply)
                    .help(filters.frameTypeSwitchesApply
                          ? "Supervisory frames — RR, RNR, REJ. No payload, and about two thirds of a busy channel, but they are how a stalled or retrying link shows itself."
                          : "Payload Only already excludes supervisory frames.")
                Toggle("U Frames", isOn: $filters.showU)
                    .disabled(!hasPackets || !filters.frameTypeSwitchesApply)
                    .help(filters.frameTypeSwitchesApply
                          ? "Unnumbered control — SABM, UA, DM, DISC. The handshakes that open and close a connection."
                          : "Payload Only already excludes unnumbered control frames.")
            }
            
            Divider()
            
            // Additional Filters section
            VStack(alignment: .leading, spacing: 8) {
                Text("Additional Filters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Toggle("Payload Only", isOn: $filters.payloadOnly)
                    .disabled(!hasPackets)
                    .help("Only frames that carry something to read: I frames, and UI frames with text. Overrides the S and U switches above.")
                Toggle("Pinned Only", isOn: $filters.onlyPinned)
                    .disabled(!hasPinnedPackets)
                    .help("Show only pinned packets")
            }
            
            Divider()
            
            // A combination that can only ever draw an empty table is a
            // mistake in this popover, not a quiet channel, and the two look
            // identical from outside.
            if filters.admitsNothing {
                Label("These settings hide every frame.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Show Everything") {
                onReset()
            }
            .disabled(filters.isDefault)
            .help("Turn every filter off, so the table shows every frame received.")
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
