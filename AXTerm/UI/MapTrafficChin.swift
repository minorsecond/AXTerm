import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One radio the traffic strip can show, named for its tab.
struct MapTrafficRadio: Identifiable, Equatable {
    let id: RadioID
    let name: String
}

/// A collapsible strip of live traffic along the bottom of the map.
///
/// The map answers *where*; the Terminal answers *what was said*. Watching a
/// channel needs both at once, and switching pages to read one frame loses the
/// map's context every time. This is the smallest thing that closes that gap:
/// the newest frames, one line each, under the map rather than instead of it.
///
/// **Scoped to a radio, always.** A station with an APRS radio and a packet
/// radio is watching two different channels, and a strip that pooled them
/// attributed frames to a channel they never appeared on — the operator hid
/// the AX.25 radio on the map and its traffic kept scrolling past anyway.
/// With one radio the strip names it and shows only its frames; with several
/// there is a tab each, and an All tab for the pooled view that used to be
/// the only one.
///
/// Deliberately not a second Terminal. There is no search, no selection state
/// and no scrollback beyond `MapTrafficFeed.capacity` — the Packets and
/// Terminal pages exist and are better at all of that.
struct MapTrafficChin: View {

    @ObservedObject var feed: MapTrafficFeed
    /// The radios the operator has enabled and left visible. Order is the
    /// settings order, so the tabs read the same as the radio list.
    var radios: [MapTrafficRadio]
    /// Kept by the caller so the strip stays as the operator left it.
    @Binding var isExpanded: Bool
    /// Selecting a line selects that station on the map, which is the reason
    /// to have the two together at all.
    var onSelect: (String) -> Void

    private static let rowHeight: CGFloat = 16
    /// Opening height: enough to see a short exchange without the map becoming
    /// a footnote to its own traffic log.
    static let defaultHeight: Double = Double(rowHeight) * 5
    /// Two rows is the smallest that still reads as a list rather than a
    /// clipped line; past about a third of a laptop screen the strip stops
    /// being a strip, and the Packets page is the better tool by then.
    static let heightLimit: ClosedRange<Double> = Double(rowHeight) * 2 ... 320

    /// Height after dragging the top edge by `translation`.
    ///
    /// Dragging *up* makes it taller, which is why the translation is
    /// subtracted: the edge being dragged is the strip's top, so moving it
    /// toward the top of the screen grows the strip downward-anchored.
    static func resized(_ height: Double, by translation: CGFloat) -> Double {
        min(max(height - Double(translation), heightLimit.lowerBound), heightLimit.upperBound)
    }

    /// The operator's chosen height, kept across launches.
    @AppStorage("map.traffic.height") private var height: Double = MapTrafficChin.defaultHeight
    /// The chosen tab, by radio id; empty means All.
    @AppStorage("map.traffic.radio") private var selectedRadioRaw: String = ""
    /// The height being previewed mid-drag.
    ///
    /// The committed height is only written on release, and that is the whole
    /// point: the strip is a sibling of the map, so every intermediate height
    /// resized the map view — MapKit re-projects, re-anchors every annotation
    /// and re-fits its camera on each one, and the map and everything on it
    /// visibly lurched for the length of the drag. Dragging now moves a line
    /// drawn *over* the map, which costs the map nothing, and the resize
    /// happens once when the operator lets go.
    @State private var dragHeight: Double?

    private var visibleIDs: Set<RadioID> { Set(radios.map(\.id)) }

    /// The radio whose traffic is showing, or nil for all of them.
    ///
    /// With a single radio there is nothing to choose: the strip is scoped to
    /// it whatever is stored, so hiding the other radio takes effect without
    /// the operator also having to pick a tab.
    private var selectedRadio: RadioID? {
        if radios.count == 1 { return radios[0].id }
        guard !selectedRadioRaw.isEmpty else { return nil }
        let id = RadioID(rawValue: selectedRadioRaw)
        return visibleIDs.contains(id) ? id : nil
    }

    private var shownLines: [MapTrafficFeed.Line] {
        feed.lines(for: selectedRadio, visible: visibleIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                if radios.count > 1 { tabs }
                Divider()
                if shownLines.isEmpty {
                    Text("Nothing heard yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    rows
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { if isExpanded { resizeHandle } }
        // A docked strip, not a floating card. As a card at the map's
        // bottom-left it sat on top of the legend, which lives in that same
        // corner inside `StationMapView` — expanded the legend poked out above
        // and could still be clicked, but collapsed it was completely covered,
        // so minimising the legend made it unreachable. Docking the strip
        // below the map means nothing can hide behind it.
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .top) { dragPreview }
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                Text("Traffic")
                    .font(.caption.weight(.medium))
                // One radio: name it, so the strip never silently shows a
                // channel the operator did not think they were watching.
                if radios.count == 1 {
                    Text("· \(radios[0].name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Closed, the strip still says whether anything is happening,
                // so it does not have to be open to be useful.
                if let newest = shownLines.first {
                    Text("· \(newest.from) → \(newest.to)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded
              ? "Hide the live traffic strip. Drag its top edge to resize it."
              : "Show the last frames heard, newest first.")
    }

    /// One tab per visible radio, plus All.
    private var tabs: some View {
        Picker("Radio", selection: Binding(
            get: { selectedRadioRaw },
            set: { selectedRadioRaw = $0 })) {
            Text("All").tag("")
            ForEach(radios) { radio in
                Text(radio.name).tag(radio.id.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .help("Show only what this radio heard. Each radio is its own channel.")
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(shownLines) { line in
                    row(line)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: height)
    }

    /// The draggable top edge.
    ///
    /// A hair over the divider rather than a visible grabber: the strip is
    /// small and a bar of its own would cost more height than it saves. Six
    /// points is comfortable for a pointer, and the cursor changes on hover so
    /// the affordance is discoverable without drawing anything.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        dragHeight = Self.resized(height, by: value.translation.height)
                    }
                    .onEnded { value in
                        height = Self.resized(height, by: value.translation.height)
                        dragHeight = nil
                    })
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            #endif
            .accessibilityLabel("Resize the traffic strip")
    }

    /// The line the drag is aiming at, drawn over the map so nothing is
    /// re-laid-out until the operator lets go.
    @ViewBuilder
    private var dragPreview: some View {
        if let dragHeight {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .offset(y: -(dragHeight - height))
                .allowsHitTesting(false)
        }
    }

    /// A frame still waiting for the channel is not yet an event on the air,
    /// and one the radio gave up on never was.
    private static func txTint(_ line: MapTrafficFeed.Line) -> Color {
        switch line.transmit {
        case .pending: return .secondary
        case .dropped: return .red
        case .onAir, .none: return .accentColor
        }
    }

    private func row(_ line: MapTrafficFeed.Line) -> some View {
        Button {
            onSelect(line.from)
        } label: {
            HStack(spacing: 6) {
                Text(line.at, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.tertiary)
                // Ours reads apart from received traffic in both directions:
                // an arrow for what we sent, so a beacon going out is visible
                // as an event and not just another callsign in the list.
                // TX is what we put on the air. A frame of ours that arrived
                // is the same frame coming back through a digipeater, which
                // is worth its own mark: it is proof that digipeater heard us.
                Text(line.wasTransmitted ? "TX" : (line.isOurs ? "\u{21BA} " : "  "))
                    .foregroundStyle(Self.txTint(line))
                Text(line.from)
                    .fontWeight(.medium)
                    .foregroundStyle(line.isOurs ? Color.accentColor : .primary)
                Text("→ \(line.to)")
                    .foregroundStyle(line.isForUs ? Color.accentColor : .secondary)
                    .fontWeight(line.isForUs ? .semibold : .regular)
                if !line.via.isEmpty {
                    Text("via \(line.via)")
                        .foregroundStyle(.tertiary)
                }
                Text(line.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Handed to the radio is not on the air: on a busy channel
                // the transmitter waits for a gap, and if none comes it
                // discards what it was holding. Saying so is the difference
                // between "my query went unanswered" and "my query never
                // went out".
                switch line.transmit {
                case .pending:
                    Text("waiting for a clear channel\u{2026}")
                        .foregroundStyle(.tertiary)
                case .dropped:
                    Text("never sent \u{2014} channel stayed busy")
                        .foregroundStyle(.red)
                case .onAir, .none:
                    EmptyView()
                }
                Spacer(minLength: 0)
            }
            .font(.caption2.monospaced())
            .padding(.horizontal, 3)
            // Addressed to us: a tint rather than a badge. On a channel
            // scrolling past, the frame that wants an answer has to be findable
            // without reading every line.
            .background(line.isForUs ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(line.isForUs
              ? "Addressed to this station. Select \(line.from) on the map."
              : "Select \(line.from) on the map.")
    }
}
