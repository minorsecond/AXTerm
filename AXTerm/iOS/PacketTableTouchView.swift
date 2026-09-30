#if os(iOS)
import SwiftUI

/// The packet stream on a touch screen.
///
/// Not the Mac's table transplanted. `PacketNSTableView` exists because
/// AppKit's `NSTableView` is the only thing on macOS that stays smooth with a
/// live stream tens of thousands of rows long; `List` gives the same
/// virtualization on iOS for free, so wrapping the AppKit table would buy
/// nothing and cost a second implementation.
///
/// What is preserved exactly is the *behavior* the Mac table has and a naive
/// list does not: it follows the newest packet while the operator is at the
/// bottom, stops following the moment they scroll away to read something, and
/// says so with a button back. A monitor that yanks the view out from under
/// somebody mid-read is worse than one that does not scroll at all.
struct PacketTableTouchView: View {

    let packets: [Packet]
    /// Radio names by id; empty with one radio, and then no row names one.
    var radioNames: [RadioID: String] = [:]
    @Binding var selection: Set<Packet.ID>
    let onInspectSelection: () -> Void
    let onCopyInfo: (Packet) -> Void
    let onCopyRawHex: (Packet) -> Void

    /// True while the newest packet is on screen. Following resumes on its
    /// own when the operator scrolls back down, which is what they mean by
    /// scrolling back down.
    @State private var isFollowing = true
    @State private var scrollPosition: Packet.ID?

    private var rows: [PacketRowViewModel] {
        let duplicates = PacketDuplicates.marks(for: packets)
        return packets.map {
            PacketRowViewModel.fromPacket($0, radioNames: radioNames, duplicate: duplicates[$0.id])
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            list

            if !isFollowing {
                Button {
                    isFollowing = true
                    scrollToNewest()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .resizable()
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .padding([.bottom, .trailing], 18)
                .accessibilityLabel("Jump to newest packet")
                .explain("Scrolls back to the newest packet and resumes following the stream. Following stopped because you scrolled away to read something, and the list will not move the view out from under you.",
                         showsIndicator: false)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFollowing)
    }

    private var list: some View {
        // A tap opens the packet, as a click does on the Mac. With list
        // selection a tap only highlighted the row, and the inspector was
        // reachable only from the long-press menu.
        List {
            ForEach(rows) { row in
                Button {
                    selection = [row.id]
                    onInspectSelection()
                } label: {
                    PacketRow(row: row)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the packet's decoded fields and raw bytes")
                    .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                    .contextMenu {
                        if let packet = packets.first(where: { $0.id == row.id }) {
                            Button("Inspect") {
                                selection = [row.id]
                                onInspectSelection()
                            }
                            Button("Copy Info") { onCopyInfo(packet) }
                            Button("Copy Raw Hex") { onCopyRawHex(packet) }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 34)
        .scrollPosition(id: $scrollPosition, anchor: .bottom)
        .onChange(of: packets.count) { _, _ in
            guard isFollowing else { return }
            scrollToNewest()
        }
        .onChange(of: scrollPosition) { _, position in
            // The operator scrolling away is the signal to stop following.
            // Comparing against the newest id rather than a scroll offset
            // keeps this correct as rows are appended underneath.
            guard let position, let newest = rows.last?.id else { return }
            isFollowing = position == newest
        }
        .onAppear(perform: scrollToNewest)
    }

    private func scrollToNewest() {
        scrollPosition = rows.last?.id
    }
}

/// One packet, laid out for a narrow screen.
///
/// The Mac shows six columns because it has the width. Here the same fields
/// are stacked in the order an operator reads them: who to who, then what
/// kind of frame, then the payload — with time and via kept small because
/// they are context rather than the answer to "what just happened".
private struct PacketRow: View {
    let row: PacketRowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.fromText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(row.toText)
                    .font(.system(size: 12, design: .monospaced))
                Spacer(minLength: 4)
                duplicateBadge
                Text(row.typeLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .explain(row.typeTooltip, showsIndicator: false)
            }

            if !row.infoText.isEmpty {
                Text(row.infoText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(row.isLowSignal || isCopy ? .tertiary : .primary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Text(row.timeText)
                    .font(.system(size: 9, design: .monospaced))
                if !row.viaText.isEmpty {
                    Text("via \(row.viaText)")
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                }
                if let radio = row.radioName {
                    Text("\u{b7} \(radio)")
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .explain("Decoded by \(radio): the radio that heard it, not the one the sender used.", showsIndicator: false)
                }
            }
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var isCopy: Bool {
        if case .copy = row.duplicate { return true }
        return false
    }

    /// The terminal's "+1" on the first sighting, and "copy" on the later
    /// ones, which the terminal folds away but a packet list shows.
    @ViewBuilder
    private var duplicateBadge: some View {
        switch row.duplicate {
        case .heardAgain(let count):
            Text("+\(count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.purple)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                .explain("Heard \(CountPhrase.of(count + 1, "time")), by different paths. The later copies are marked below.",
                         showsIndicator: false)
                .accessibilityLabel("Heard \(CountPhrase.of(count, "more time")) by other paths")
        case .copy:
            Text("copy")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.purple)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.purple.opacity(0.5), lineWidth: 0.5))
                .explain("The same frame heard again a moment later by another path, usually a digipeater repeating it.",
                         showsIndicator: false)
                .accessibilityLabel("Copy of an earlier frame, heard by another path")
        case nil:
            EmptyView()
        }
    }
}
#endif
