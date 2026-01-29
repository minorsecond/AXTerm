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
    let onInspectSelection: () -> Void
    let onCopyInfo: (Packet) -> Void
    let onCopyRawHex: (Packet) -> Void

    var body: some View {
        Table(packets, selection: $selection) {
            TableColumn("Time") { pkt in
                PacketTableCell(
                    packet: pkt,
                    selection: $selection,
                    onInspectSelection: onInspectSelection,
                    onCopyInfo: onCopyInfo,
                    onCopyRawHex: onCopyRawHex
                ) {
                    Text(pkt.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 80)

            TableColumn("From") { pkt in
                PacketTableCell(
                    packet: pkt,
                    selection: $selection,
                    onInspectSelection: onInspectSelection,
                    onCopyInfo: onCopyInfo,
                    onCopyRawHex: onCopyRawHex
                ) {
                    Text(pkt.fromDisplay)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(rowForeground(pkt))
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn("To") { pkt in
                PacketTableCell(
                    packet: pkt,
                    selection: $selection,
                    onInspectSelection: onInspectSelection,
                    onCopyInfo: onCopyInfo,
                    onCopyRawHex: onCopyRawHex
                ) {
                    Text(pkt.toDisplay)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(rowForeground(pkt))
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn("Via") { pkt in
                PacketTableCell(
                    packet: pkt,
                    selection: $selection,
                    onInspectSelection: onInspectSelection,
                    onCopyInfo: onCopyInfo,
                    onCopyRawHex: onCopyRawHex
                ) {
                    Text(pkt.viaDisplay.isEmpty ? "" : pkt.viaDisplay)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 60, ideal: 120)

            TableColumn("Type") { pkt in
                PacketTableCell(
                    packet: pkt,
                    selection: $selection,
                    onInspectSelection: onInspectSelection,
                    onCopyInfo: onCopyInfo,
                    onCopyRawHex: onCopyRawHex,
                    alignment: .center
                ) {
                    Text(pkt.frameType.icon)
                        .font(.system(.body))
                        .foregroundStyle(rowForeground(pkt))
                        .help(pkt.frameType.displayName)
                }
            }
            .width(min: 40, ideal: 50)

            TableColumn("Info") { pkt in
                PacketTableCell(
                    packet: pkt,
                    selection: $selection,
                    onInspectSelection: onInspectSelection,
                    onCopyInfo: onCopyInfo,
                    onCopyRawHex: onCopyRawHex
                ) {
                    Text(pkt.infoPreview)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(pkt.isLowSignal ? .secondary : .primary)
                        .help(pkt.infoTooltip)
                }
            }
        }
        .focusable(true)
        .background(
            Button(action: onInspectSelection) {
                EmptyView()
            }
            .keyboardShortcut(.defaultAction)
            .hidden()
        )
    }

    private func rowForeground(_ packet: Packet) -> Color {
        packet.isLowSignal ? .secondary : .primary
    }
}

private struct PacketTableCell<Content: View>: View {
    let packet: Packet
    @Binding var selection: Set<Packet.ID>
    let onInspectSelection: () -> Void
    let onCopyInfo: (Packet) -> Void
    let onCopyRawHex: (Packet) -> Void
    var alignment: Alignment = .leading
    let content: Content

    init(
        packet: Packet,
        selection: Binding<Set<Packet.ID>>,
        onInspectSelection: @escaping () -> Void,
        onCopyInfo: @escaping (Packet) -> Void,
        onCopyRawHex: @escaping (Packet) -> Void,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) {
        self.packet = packet
        self._selection = selection
        self.onInspectSelection = onInspectSelection
        self.onCopyInfo = onCopyInfo
        self.onCopyRawHex = onCopyRawHex
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
            .background(debugHitTestOverlay)
            .contextMenu {
                Button("Inspect Packet") {
                    selection = [packet.id]
                    onInspectSelection()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Copy Info") {
                    selection = [packet.id]
                    onCopyInfo(packet)
                }

                Button("Copy Raw Hex") {
                    selection = [packet.id]
                    onCopyRawHex(packet)
                }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                selection = [packet.id]
                onInspectSelection()
            })
    }

    @ViewBuilder
    private var debugHitTestOverlay: some View {
        if Self.debugHitTesting {
            Rectangle()
                .strokeBorder(.pink.opacity(0.6), lineWidth: 1)
                .background(Color.pink.opacity(0.1))
                .allowsHitTesting(false)
        } else {
            EmptyView()
        }
    }

    private static let debugHitTesting = false
}
