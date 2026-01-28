//
//  PacketTableView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

struct PacketTableView: View {
    let packets: [Packet]
    @Binding var selection: Set<Packet.ID>
    let onInspect: (Packet) -> Void

    var body: some View {
        Table(packets, selection: $selection) {
            TableColumn("Time") { pkt in
                Text(pkt.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onInspect(pkt)
                    }
            }
            .width(min: 70, ideal: 80)

            TableColumn("From") { pkt in
                Text(pkt.fromDisplay)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(rowForeground(pkt))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onInspect(pkt)
                    }
            }
            .width(min: 80, ideal: 100)

            TableColumn("To") { pkt in
                Text(pkt.toDisplay)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(rowForeground(pkt))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onInspect(pkt)
                    }
            }
            .width(min: 80, ideal: 100)

            TableColumn("Via") { pkt in
                Text(pkt.viaDisplay.isEmpty ? "" : pkt.viaDisplay)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onInspect(pkt)
                    }
            }
            .width(min: 60, ideal: 120)

            TableColumn("Type") { pkt in
                Text(pkt.frameType.icon)
                    .font(.system(.body))
                    .foregroundStyle(rowForeground(pkt))
                    .help(pkt.frameType.displayName)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onInspect(pkt)
                    }
            }
            .width(min: 40, ideal: 50)

            TableColumn("Info") { pkt in
                Text(pkt.infoPreview)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(pkt.isLowSignal ? .secondary : .primary)
                    .help(pkt.infoTooltip)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onInspect(pkt)
                    }
            }
        }
    }

    private func rowForeground(_ packet: Packet) -> Color {
        packet.isLowSignal ? .secondary : .primary
    }
}
