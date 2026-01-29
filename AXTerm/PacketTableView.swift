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
    @State private var isAtTop = true
    @State private var followNewest = true
    @State private var pendingNewPackets = 0
    @State private var lastTopPacketID: Packet.ID?
    @State private var scrollToTopToken = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PacketNSTableView(
                packets: packets,
                selection: $selection,
                isAtTop: $isAtTop,
                followNewest: $followNewest,
                scrollToTopToken: scrollToTopToken,
                onInspectSelection: onInspectSelection,
                onCopyInfo: onCopyInfo,
                onCopyRawHex: onCopyRawHex
            )
            .focusable(true)
            .background(
                Button(action: onInspectSelection) {
                    EmptyView()
                }
                .keyboardShortcut(.defaultAction)
                .hidden()
                .allowsHitTesting(false)
            )

            if pendingNewPackets > 0 {
                Button {
                    followNewest = true
                    pendingNewPackets = 0
                    scrollToTopToken += 1
                } label: {
                    Label("New packets (\(pendingNewPackets))", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding([.top, .trailing], 12)
            }
        }
        .onChange(of: packets) { _, newValue in
            guard !newValue.isEmpty else {
                pendingNewPackets = 0
                lastTopPacketID = nil
                return
            }

            if isAtTop || followNewest {
                pendingNewPackets = 0
                lastTopPacketID = newValue.first?.id
            } else {
                let nextCount = countNewPackets(previousTopID: lastTopPacketID, packets: newValue)
                if nextCount > 0 {
                    pendingNewPackets += nextCount
                }
                lastTopPacketID = newValue.first?.id
            }
        }
        .onChange(of: isAtTop) { _, newValue in
            if newValue {
                pendingNewPackets = 0
                followNewest = true
                lastTopPacketID = packets.first?.id
            } else {
                followNewest = false
            }
        }
    }

    private func countNewPackets(previousTopID: Packet.ID?, packets: [Packet]) -> Int {
        guard let previousTopID else {
            return packets.count
        }
        if let index = packets.firstIndex(where: { $0.id == previousTopID }) {
            return index
        }
        return packets.count
    }
}
