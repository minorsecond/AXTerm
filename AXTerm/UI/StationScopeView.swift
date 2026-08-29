import SwiftUI

/// Renders a `StationScope`: this station at the centre, everything else
/// plotted by true bearing and range.
///
/// Reusable by construction — it knows nothing about Winlink, gateways or
/// mail. Anything that can produce a `StationScope` (RMS gateways,
/// NET/ROM neighbours, heard stations) gets this rendering for free.
struct StationScopeView: View {

    let scope: StationScope
    @Binding var selection: String?
    var legend: MapLegend.Kind = .recency
    /// Distances read in the operator's unit; miles when unset.
    var distanceInMiles: Bool = true

    private let rimInset: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = max(10, side / 2 - rimInset)
            ZStack {
                plot(radius: radius)
                    .frame(width: side, height: side)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(backdrop)
        .overlay(alignment: .bottomLeading) {
            MapLegend(kind: legend).padding(10)
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        RadialGradient(
            colors: [Color.accentColor.opacity(0.10), Color.clear],
            center: .center, startRadius: 0, endRadius: 420)
        .background(.background)
    }

    // MARK: - Plot

    private func plot(radius: CGFloat) -> some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                drawRings(in: context, center: center, radius: radius)
                drawSpokes(in: context, center: center, radius: radius)
                drawSelectionRay(in: context, center: center, radius: radius)
            }
            .allowsHitTesting(false)

            ForEach(scope.sites) { site in
                marker(for: site, radius: radius)
            }
            centreMarker
            cardinalLabels(radius: radius)
            rangeLabels(radius: radius)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
    }

    private func drawRings(in context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        // Outer rim, drawn heavier — it is the scale's edge.
        let rim = Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
        context.fill(rim, with: .color(.primary.opacity(0.03)))
        context.stroke(rim, with: .color(.secondary.opacity(0.45)), lineWidth: 1.2)

        for ring in scope.rings {
            let scaled = radius * ring / scope.maxRange
            let path = Path(ellipseIn: CGRect(
                x: center.x - scaled, y: center.y - scaled,
                width: scaled * 2, height: scaled * 2))
            context.stroke(
                path,
                with: .color(.secondary.opacity(0.22)),
                style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
        }
    }

    private func drawSpokes(in context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        for bearing in stride(from: 0, to: 360, by: 30) {
            let radians = CGFloat(bearing) * .pi / 180
            // Cardinals get a full spoke; the rest are tick marks, so the
            // plot reads as a compass rather than a spiderweb.
            let isCardinal = bearing % 90 == 0
            let inner: CGFloat = isCardinal ? 0.0 : 0.94
            let start = CGPoint(
                x: center.x + radius * inner * sin(radians),
                y: center.y - radius * inner * cos(radians))
            let end = CGPoint(
                x: center.x + radius * sin(radians),
                y: center.y - radius * cos(radians))
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(
                path,
                with: .color(.secondary.opacity(isCardinal ? 0.18 : 0.35)),
                lineWidth: isCardinal ? 0.7 : 1)
        }
    }

    /// A ray to the selected station — the antenna heading, made obvious.
    private func drawSelectionRay(in context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        guard let site = selectedSite else { return }
        let radians = CGFloat(site.bearingDegrees) * .pi / 180
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(
            x: center.x + radius * sin(radians),
            y: center.y - radius * cos(radians)))
        context.stroke(
            path,
            with: .color(.accentColor.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }

    // MARK: - Markers

    private var selectedSite: StationScope.Site? {
        scope.sites.first { $0.id == selection }
    }

    /// Fixed footprint, for the same reason as the map: the marker is
    /// centred on its offset, so any size change shifts it. Selection
    /// changes only what is drawn inside.
    private func marker(for site: StationScope.Site, radius: CGFloat) -> some View {
        let point = site.unitPoint(maxRange: scope.maxRange)
        let isSelected = site.id == selection
        let tint = color(for: site.signal)

        return VStack(spacing: 2) {
            ZStack {
                if site.signal == .good && !site.isStale && !site.isApproximate {
                    Circle()
                        .fill(tint.opacity(0.22))
                        .frame(width: 22, height: 22)
                        .blur(radius: 3)
                }
                if site.isApproximate {
                    Circle()
                        .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [2, 1.5]))
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(tint)
                        .frame(width: 9, height: 9)
                }
                Circle()
                    .stroke(isSelected ? Color.primary : .clear, lineWidth: 1.5)
                    .frame(width: 17, height: 17)
            }
            .frame(width: 24, height: 24)

            Text(site.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(site.isStale ? .secondary : .primary)
                .fixedSize()
        }
        .opacity(site.isStale ? 0.55 : 1)
        .offset(x: point.x * radius, y: point.y * radius)
        .help(site.detail)
        .onTapGesture { selection = isSelected ? nil : site.id }
    }

    private var centreMarker: some View {
        VStack(spacing: 2) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.tint)
            Text(scope.observerLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .help("Your station — everything is plotted by true bearing and range from here.")
    }

    private func cardinalLabels(radius: CGFloat) -> some View {
        ForEach([("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)], id: \.0) { name, bearing in
            let radians = bearing * .pi / 180
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(name == "N" ? Color.accentColor : .secondary)
                .offset(x: (radius + 15) * sin(radians), y: -(radius + 15) * cos(radians))
        }
    }

    /// Ring distances, written up the north-east diagonal where they are
    /// least likely to collide with a station label.
    private func rangeLabels(radius: CGFloat) -> some View {
        ForEach(scope.rings + [scope.maxRange], id: \.self) { ring in
            let scaled = radius * ring / scope.maxRange
            let radians = 45.0 * .pi / 180
            Text(rangeText(ring))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)
                .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 2))
                .offset(x: scaled * sin(radians), y: -scaled * cos(radians))
        }
    }

    private func rangeText(_ kilometres: Double) -> String {
        let value = DistanceDisplay.value(kilometres: kilometres, inMiles: distanceInMiles)
        return DistanceDisplay.string(
            kilometres: kilometres, inMiles: distanceInMiles,
            format: value < 10 ? "%.1f" : "%.0f")
    }

    private func color(for signal: StationScope.Signal) -> Color {
        switch signal {
        case .good: .green
        case .fair: .yellow
        case .poor: .orange
        case .unknown: .secondary
        }
    }
}
