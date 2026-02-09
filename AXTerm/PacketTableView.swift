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
    
    @State private var isAtBottom = true
    @State private var followNewest = true
    @State private var scrollToBottomToken = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PacketNSTableView(
                packets: packets,
                selection: $selection,
                isAtBottom: $isAtBottom, // Corrected binding name
                followNewest: $followNewest,
                scrollToBottomToken: scrollToBottomToken, // Corrected parameter name
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

            // Jump to Bottom Button
            if !isAtBottom {
                Button {
                    isAtBottom = true
                    followNewest = true // Should auto-resume following
                    scrollToBottomToken += 1
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundStyle(.secondary, .regularMaterial)
                        .background(Circle().fill(.background)) // Ensure background for visibility
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .padding([.bottom, .trailing], 20)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .onChange(of: packets) { _, _ in
            if isAtBottom {
                scrollToBottomToken += 1
            }
        }
        .onAppear {
            // Initial scroll to bottom on load
            scrollToBottomToken += 1
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isAtBottom)
    }
}
