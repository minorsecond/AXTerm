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
        PacketTableNSTableView(
            packets: packets,
            selection: $selection,
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
    }
}
