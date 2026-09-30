import MapKit
import SwiftUI

// The look shared by first-run setup and the Add Radio sheet: a compact
// window sized to its content, a step strip, cards for the fields, and
// read-outs set in monospace so callsigns, coordinates and locators read
// the way an operator writes them in a log.

/// The frame around a setup step: header, step strip, content and buttons.
///
/// On the Mac the window takes the height its content needs, so a short
/// step makes a short sheet. iOS gets a scroll view, since its sheets are
/// full height anyway.
struct SetupFrame<Content: View, Buttons: View>: View {
    let title: String
    let subtitle: String
    let steps: [String]
    let current: Int
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            #if os(macOS)
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            #else
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(16)
            }
            #endif
            Divider()
            HStack(spacing: 8) { buttons }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        #if os(macOS)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .presentationSizing(.fitted)
        #endif
        .animation(.snappy(duration: 0.25), value: current)
    }

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
struct SetupStepStrip: View {
    let steps: [String]
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 5) {
                    marker(index)
                    Text(title)
                        .font(.caption.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index <= current ? .primary : .secondary)
                        .lineLimit(1)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index < current ? Color.accentColor : Color(platform: .platformSeparator))
                        .frame(height: 1)
                        .frame(minWidth: 8, maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps.count): \(steps.indices.contains(current) ? steps[current] : "")")
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
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(SetupSurface(highlighted: selected))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
