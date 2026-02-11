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
    var isConnected: Bool = false

    /// AXDP capability for this station (nil if not known)
    var capability: AXDPCapability?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(station.call)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .help("Station callsign")

                    if isConnected {
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                            .help("Connected session")
                    }

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
        .background(
            Group {
                if isConnected {
                    Color.green.opacity(0.10)
                } else if isSelected {
                    Color.accentColor.opacity(0.10)
                } else {
                    Color.clear
                }
            }
        )
        .cornerRadius(4)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 8) {
        StationRowView(
            station: Station(call: "N0CALL", lastHeard: Date(), heardCount: 15, lastVia: ["WIDE1-1"]),
            isSelected: false,
            capability: .defaultLocal()
        )

        StationRowView(
            station: Station(call: "K0ABC-5", lastHeard: Date(), heardCount: 3, lastVia: []),
            isSelected: true,
            capability: nil
        )

        StationRowView(
            station: Station(call: "W0XYZ", lastHeard: Date(), heardCount: 42, lastVia: ["RELAY", "DIGI"]),
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
