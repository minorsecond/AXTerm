import MapKit
import SwiftUI

// The look shared by first-run setup and the Add Radio sheet: a compact
// window sized to its content, a step strip, cards for the fields, and
// read-outs set in monospace so callsigns, coordinates and locators read
// the way an operator writes them in a log.

/// The frame around a setup step: header, step strip, content and buttons.
///
/// The sheet takes the height its content needs, so a short step makes a
/// short sheet; past a limit the content scrolls. On the Mac that is the
/// window resized to fit. On iOS it is a height detent on a phone and a
/// form sheet fitted to the content on an iPad. A full-height sheet left a
/// large empty area under the cards of every step.
struct SetupFrame<Content: View, Buttons: View>: View {
    let title: String
    let subtitle: String
    let steps: [String]
    let current: Int
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    /// The content's own height, measured, so the sheet can follow it from
    /// step to step. A sheet sized once when it opens kept the first step's
    /// height and clipped the header and buttons of a taller one.
    @State private var contentHeight: CGFloat = 0
    #if os(iOS)
    /// The header's and the button row's heights, which with the content's
    /// make the height the sheet asks for.
    @State private var chromeHeights = SetupChromeHeights()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
                #if os(iOS)
                .background(heightReader { chromeHeights.header = $0 })
                #endif
            Divider()
            #if os(macOS)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: SetupContentHeightKey.self, value: proxy.size.height)
                    })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), SetupSheetResizer.maxContentHeight))
            .onPreferenceChange(SetupContentHeightKey.self) { contentHeight = $0 }
            #else
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: SetupContentHeightKey.self, value: proxy.size.height)
                    })
            }
            .scrollBounceBehavior(.basedOnSize)
            // At most the content's height, and less when the keyboard or a
            // short screen leaves less: then it scrolls.
            .frame(idealHeight: max(contentHeight, 1), maxHeight: max(contentHeight, 1))
            .onPreferenceChange(SetupContentHeightKey.self) { contentHeight = $0 }
            #endif
            Divider()
            HStack(spacing: 8) { buttons }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                #if os(iOS)
                .background(heightReader { chromeHeights.buttons = $0 })
                #endif
        }
        #if os(macOS)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(SetupSheetResizer(contentHeight: contentHeight))
        #else
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents(horizontalSizeClass == .compact ? [.height(sheetHeight)] : [.large])
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        #endif
        .animation(.snappy(duration: 0.25), value: current)
    }

    #if os(iOS)
    /// Header, content, buttons and the two rules between them.
    private var sheetHeight: CGFloat {
        SetupSheetHeight.fitting(header: chromeHeights.header, content: contentHeight,
                                 buttons: chromeHeights.buttons)
    }

    private func heightReader(_ update: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { update(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in update(height) }
        }
    }
    #endif

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SetupGlyph()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            SetupStepStrip(steps: steps, current: current)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

private struct SetupContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The measured heights around the content of a setup sheet on iOS.
struct SetupChromeHeights: Equatable {
    var header: CGFloat = 0
    var buttons: CGFloat = 0
}

/// The height a setup sheet asks for on a phone.
nonisolated enum SetupSheetHeight {
    /// Before anything has been measured the sheet opens at this height
    /// rather than at zero.
    static let unmeasured: CGFloat = 420

    /// Header, content and buttons, plus the two one-point rules between
    /// them. Taller than the screen is fine: the system holds a detent to
    /// the height it has, and the content scrolls.
    static func fitting(header: CGFloat, content: CGFloat, buttons: CGFloat) -> CGFloat {
        guard header > 0, content > 0, buttons > 0 else { return unmeasured }
        return (header + content + buttons + 2).rounded(.up)
    }
}

#if os(macOS)

/// Resizes the sheet's window to fit its content whenever the content's
/// height changes, keeping the top edge where it is so the sheet grows
/// downward from under the title bar.
struct SetupSheetResizer: NSViewRepresentable {
    /// Beyond this the content scrolls instead of the sheet growing.
    static let maxContentHeight: CGFloat = 620

    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, let hosting = window.contentView else { return }
            let fitting = hosting.fittingSize
            guard fitting.height > 0, abs(window.frame.height - window.frameRect(
                forContentRect: NSRect(origin: .zero, size: fitting)).height) > 1 else { return }
            var frame = window.frame
            let newHeight = window.frameRect(forContentRect: NSRect(origin: .zero, size: fitting)).height
            frame.origin.y += frame.height - newHeight
            frame.size.height = newHeight
            window.setFrame(frame, display: true, animate: true)
        }
    }
}
#endif

/// The app's mark in the setup header.
struct SetupGlyph: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Numbered steps joined by a rule: done ones ticked, the current one
/// filled, the rest outlined.
///
/// A label is never cut short. The rules between steps give up their width
/// first, down to a few points; if the labels still don't fit, only the
/// current step keeps its name and the others show just their numbers.
struct SetupStepStrip: View {
    let steps: [String]
    let current: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(showsAllLabels: true)
            strip(showsAllLabels: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps.count): \(steps.indices.contains(current) ? steps[current] : "")")
    }

    private func strip(showsAllLabels: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 5) {
                    marker(index)
                    if showsAllLabels || index == current {
                        Text(title)
                            .font(.caption.weight(index == current ? .semibold : .regular))
                            .foregroundStyle(index <= current ? .primary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index < current ? Color.accentColor : Color(platform: .platformSeparator))
                        .frame(height: 1)
                        .frame(minWidth: 6, maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ index: Int) -> some View {
        ZStack {
            if index < current {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            } else if index == current {
                Circle().fill(Color.accentColor)
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// A group of fields, with an optional title above and note below.
struct SetupCard<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SetupSurface())
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The rounded panel behind cards, tiles and read-outs.
struct SetupSurface: View {
    var highlighted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape
            .fill(highlighted ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                              : AnyShapeStyle(.background.secondary))
            .overlay(shape.strokeBorder(highlighted ? Color.accentColor
                                                    : Color(platform: .platformSeparator).opacity(0.7),
                                        lineWidth: highlighted ? 1.5 : 0.5))
    }
}

/// Label and value pairs, the value in monospace. For facts the operator
/// reads back: a callsign, a locator, a coordinate, an endpoint.
struct SetupReadout: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.value)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

/// A choice shown as a card: symbol, name and a line about what it is.
struct SetupTile: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(height: 22)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            // Fills the height its row offers, so tiles side by side match
            // (see SetupTileRow).
            .frame(maxWidth: .infinity, minHeight: 84, maxHeight: .infinity, alignment: .topLeading)
            .background(SetupSurface(highlighted: selected))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Tiles side by side, all as tall as the tallest, in rows of `columns`.
/// A short last row keeps the column width, so its tiles line up with the
/// ones above.
struct SetupTileRows<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    var columns = 3
    @ViewBuilder var tile: (Item) -> Tile

    var body: some View {
        let perRow = max(columns, 1)
        let rows = stride(from: 0, to: items.count, by: perRow).map {
            Array(items[$0..<min($0 + perRow, items.count)])
        }
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { tile($0) }
                    ForEach(0..<(perRow - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
                // Measured at the tallest tile's height, then each tile is
                // offered that height and fills it.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small, fixed map of where the station is, with its accuracy drawn as
/// a circle so a grid-square center looks as vague as it is.
struct SetupPositionMap: View {
    let position: StationPosition
    let callsign: String

    var body: some View {
        let centre = CLLocationCoordinate2D(latitude: position.point.latitude,
                                            longitude: position.point.longitude)
        let span = max(position.accuracyMetres * 5, 3_000)
        Map(position: .constant(.region(MKCoordinateRegion(center: centre,
                                                           latitudinalMeters: span,
                                                           longitudinalMeters: span))),
            interactionModes: []) {
            MapCircle(center: centre, radius: position.accuracyMetres)
                .foregroundStyle(Color.accentColor.opacity(0.15))
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
            Marker(callsign.isEmpty ? "Station" : callsign,
                   systemImage: "antenna.radiowaves.left.and.right", coordinate: centre)
                .tint(Color.accentColor)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color(platform: .platformSeparator).opacity(0.7), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// Text for a coordinate the way it is logged: degrees to five places and
/// a hemisphere letter.
enum SetupFormat {
    static func latitude(_ value: Double) -> String {
        String(format: "%.5f\u{00B0} %@", abs(value), value >= 0 ? "N" : "S")
    }

    static func longitude(_ value: Double) -> String {
        String(format: "%.5f\u{00B0} %@", abs(value), value >= 0 ? "E" : "W")
    }

    static func accuracy(_ metres: Double) -> String {
        metres >= 1_000
            ? String(format: "\u{00B1}%.1f km", metres / 1_000)
            : String(format: "\u{00B1}%.0f m", metres)
    }
}
