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

    /// The station's other name, when the network has published one.
    ///
    /// A row holds whatever the AX.25 address field carried, which for a node
    /// is often the tactical alias. `DRLNOD` alone is unplaceable — it is not a
    /// licence and no directory has it — and `N0HI-7` alone is unrecognisable
    /// to an operator who only ever sees SOLBPQ in node tables. Showing both
    /// costs one dim word and removes the need to go and look it up.
    var alsoKnownAs: String?

    /// The node this station is a dial-out leg of, when it is one.
    ///
    /// A node asked to connect onward dials as the *operator*, under a free
    /// SSID of their own callsign — so `K0EPI-6` appears in this list looking
    /// like a stranger transmitting under the operator's licence, when it is
    /// DRLNOD carrying their own session (field question 2026-08-28 18:53).
    var relayLegOf: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(station.call)
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .help("Station callsign")

                    if let alsoKnownAs, !alsoKnownAs.isEmpty {
                        Text(alsoKnownAs)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .help("\(station.call) is also known as \(alsoKnownAs) — "
                                  + "one of the two is a tactical node alias, the other the "
                                  + "licence behind it. Learned from node tables and beacons; "
                                  + "see Nodes for who announced it.")
                    }

                    if isConnected {
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .help("Connected session")
                    }

                    // AXDP capability badge
                    if capability != nil {
                        AXDPCapabilityBadge(capability: capability, compact: true)
                    }
                }

                Text(station.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Packet count and last heard time")

                if !station.lastViaDisplay.isEmpty {
                    Text("Via \(station.lastViaDisplay)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Last heard digipeater path")
                }

                if let relayLegOf, !relayLegOf.isEmpty {
                    Label("\(relayLegOf) dialing out as you", systemImage: "arrow.uturn.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .help("This is not another station: \(relayLegOf) connects "
                              + "onward on your behalf using a spare SSID of your own "
                              + "callsign. Its traffic is your session's downstream leg.")
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            Group {
                if isConnected {
                    Color.green.opacity(0.10)
                } else if isSelected {
                    Color.accentColor.opacity(0.15)
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
