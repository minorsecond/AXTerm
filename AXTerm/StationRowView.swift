//
//  StationRowView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

struct StationRowView: View {
    let station: Station
    let isSelected: Bool

    /// AXDP capability for this station (nil if not known)
    var capability: AXDPCapability?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(station.stationID.display)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .help("Station callsign")

                    // AXDP capability badge
                    if capability != nil {
                        AXDPCapabilityBadge(capability: capability, compact: true)
                    }
                }

                Text(station.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Packet count and last heard time")

                if !station.lastViaDisplay.isEmpty {
                    Text("Via \(station.lastViaDisplay)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Last heard digipeater path")
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 8) {
        StationRowView(
            station: Station(stationID: StationID("N0CALL"), lastHeard: Date(), heardCount: 15, lastVia: ["WIDE1-1"]),
            isSelected: false,
            capability: .defaultLocal()
        )

        StationRowView(
            station: Station(stationID: StationID("K0ABC-5"), lastHeard: Date(), heardCount: 3, lastVia: []),
            isSelected: true,
            capability: nil
        )

        StationRowView(
            station: Station(stationID: StationID("W0XYZ"), lastHeard: Date(), heardCount: 42, lastVia: ["RELAY", "DIGI"]),
            isSelected: false,
            capability: AXDPCapability(
                protoMin: 1, protoMax: 1,
                features: [.sack],
                compressionAlgos: [],
                maxDecompressedLen: 4096,
                maxChunkLen: 128
            )
        )
    }
    .padding()
    .frame(width: 250)
}
