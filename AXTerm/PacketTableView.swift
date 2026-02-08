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
        .onChange(of: packets) { _, newPackets in
            guard !newPackets.isEmpty else {
                pendingNewPackets = 0
                lastTopPacketID = nil
                return
            }

            // Snapshot old top BEFORE we update it
            let previousTopID = lastTopPacketID

            if isAtTop || followNewest {
                // User is following live: no “new packets” badge
                pendingNewPackets = 0
            } else {
                // User is scrolled away: count how many items got inserted above their current top row
                let nextCount = countNewPackets(previousTopID: previousTopID, packets: newPackets)
                if nextCount > 0 {
                    pendingNewPackets += nextCount
                }
            }

            // Update for next change
            lastTopPacketID = newPackets.first?.id
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
        .onAppear {
            if lastTopPacketID == nil {
                lastTopPacketID = packets.first?.id
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
