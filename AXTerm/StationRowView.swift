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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(station.call)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(isSelected ? .semibold : .regular)
                    .help("Station callsign")

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
