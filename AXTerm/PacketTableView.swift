//
//  PacketTableView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

struct PacketTableView: View {
    let packets: [Packet]
    /// True while stored history is still being read back.
    var isLoadingHistory = false
    @Binding var selection: Set<Packet.ID>
    let onInspectSelection: () -> Void
    let onCopyInfo: (Packet) -> Void
    let onCopyRawHex: (Packet) -> Void
    
    @State private var isAtBottom = true
    @State private var followNewest = true
    @State private var scrollToBottomToken = 0

    var body: some View {
        table.overlay { emptyState }
    }

    /// What the page says when there are no rows.
    ///
    /// A table with column headers and nothing under them reads as "no
    /// packets" — which was the wrong answer for the several seconds the
    /// stored history took to come back, and no answer at all on a fresh
    /// install. Say which it is.
    @ViewBuilder
    private var emptyState: some View {
        if packets.isEmpty {
            if isLoadingHistory {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Reading stored packets\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                ContentUnavailableView(
                    "No packets yet",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Frames appear here as the radio hears them."))
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var table: some View {
        #if os(macOS)
        appKitTable
        #else
        // AppKit's NSTableView is what keeps a live packet stream smooth on
        // macOS; `List` gives the same virtualisation on iOS, so the touch
        // build gets a view written for a narrow screen rather than a wrapped
        // table with six columns nobody can read.
        PacketTableTouchView(
            packets: packets,
            selection: $selection,
            onInspectSelection: onInspectSelection,
            onCopyInfo: onCopyInfo,
            onCopyRawHex: onCopyRawHex)
        #endif
    }

    #if os(macOS)
    private var appKitTable: some View {
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
        .onAppear {
            // Initial scroll to bottom on load
            scrollToBottomToken += 1
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isAtBottom)
    }
    #endif
}
