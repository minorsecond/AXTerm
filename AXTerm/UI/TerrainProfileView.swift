import SwiftUI

/// The terrain between this station and another, drawn.
///
/// A number ("blocked by 180 m") tells an operator the answer; the picture
/// tells them *where* and *what shape*, which is what decides whether a
/// digipeater on a particular hill would help. Both are shown.
struct TerrainProfileView: View {

    let profile: TerrainProfile
    let originLabel: String
    let destinationLabel: String
    /// True when the far antenna height is the global assumption rather than
    /// something recorded for this station. Said out loud, because it is the
    /// number the verdict is most sensitive to and the one most likely to be
    /// wrong — a node on a tower reads as blocked at a default of 6 m.
    var destinationHeightIsAssumed: Bool = false

    @AppStorage(WinlinkSettings.heightUnitIsFeetKey) private var heightUnitIsFeet = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if profile.samples.isEmpty {
                ContentUnavailableView(
                    "No terrain data",
                    systemImage: "mountain.2",
                    description: Text(profile.verdict.explanation(profile: profile)))
                    .frame(minHeight: 180)
            } else {
                chart
                    .frame(minHeight: 180)
                endpoints
                legend
            }
        }
        .padding(12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.verdict.summary)
                    .font(.headline)
                Text("\(originLabel) → \(destinationLabel) · \(distanceText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .explain(profile.verdict.explanation(profile: profile))
    }

    private var icon: String {
        switch profile.verdict {
        case .clear: "checkmark.circle.fill"
        case .marginal: "exclamationmark.triangle.fill"
        case .obstructed: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch profile.verdict {
        case .clear: .green
        case .marginal: .orange
        case .obstructed: .red
        case .unknown: .secondary
        }
    }

    private var distanceText: String {
        String(format: "%.1f km", profile.totalMetres / 1000)
    }

    // MARK: - Chart

    /// Drawn with Canvas rather than Swift Charts: this is four series over a
    /// few hundred points that redraw together, and the shaded Fresnel
    /// envelope is a filled band between two curves, which Charts makes
    /// awkward and Canvas makes obvious.
    private var chart: some View {
        Canvas { context, size in
            guard profile.samples.count > 1 else { return }

            let bounds = verticalBounds()
            func x(_ metres: Double) -> Double {
                size.width * (metres / max(profile.totalMetres, 1))
            }
            func y(_ elevation: Double) -> Double {
                let span = max(bounds.top - bounds.bottom, 1)
                return size.height * (1 - (elevation - bounds.bottom) / span)
            }

            // Terrain, as a filled silhouette — the shape an operator reads
            // first.
            var ground = Path()
            ground.move(to: CGPoint(x: 0, y: size.height))
            for sample in profile.samples {
                ground.addLine(to: CGPoint(x: x(sample.distanceMetres),
                                           y: y(sample.effectiveElevation)))
            }
            ground.addLine(to: CGPoint(x: size.width, y: size.height))
            ground.closeSubpath()
            context.fill(ground, with: .color(.secondary.opacity(0.35)))

            // The Fresnel envelope, as a band around the line. Where the
            // terrain enters it, the path suffers — which is the thing a
            // straight line on a map cannot show.
            var envelope = Path()
            for sample in profile.samples {
                let lower = sample.lineHeight
                    - sample.fresnelRadius * TerrainProfile.fresnelClearanceThreshold
                envelope.addLine(to: CGPoint(x: x(sample.distanceMetres), y: y(lower)))
                if sample.distanceMetres == 0 {
                    envelope.move(to: CGPoint(x: 0, y: y(lower)))
                }
            }
            for sample in profile.samples.reversed() {
                let upper = sample.lineHeight
                    + sample.fresnelRadius * TerrainProfile.fresnelClearanceThreshold
                envelope.addLine(to: CGPoint(x: x(sample.distanceMetres), y: y(upper)))
            }
            envelope.closeSubpath()
            context.fill(envelope, with: .color(tint.opacity(0.15)))

            // The straight line between the antennas.
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(profile.samples[0].lineHeight)))
            for sample in profile.samples {
                line.addLine(to: CGPoint(x: x(sample.distanceMetres), y: y(sample.lineHeight)))
            }
            context.stroke(line, with: .color(tint), lineWidth: 1.5)

            // The two antennas, drawn as masts standing on their own ground.
            // Without them the line of sight begins and ends in mid-air, and
            // the picture says nothing about which end is which or how much
            // of the clearance is mast rather than hill.
            if let first = profile.samples.first, let last = profile.samples.last {
                for (sample, atOrigin) in [(first, true), (last, false)] {
                    // Half a point in from the edge, or a 1.5pt stroke centred
                    // on the boundary loses half its width to the clip.
                    let px = atOrigin ? 1.0 : size.width - 1.0
                    var mast = Path()
                    mast.move(to: CGPoint(x: px, y: y(sample.effectiveElevation)))
                    mast.addLine(to: CGPoint(x: px, y: y(sample.lineHeight)))
                    context.stroke(mast, with: .color(.primary.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    let top = CGPoint(x: px, y: y(sample.lineHeight))
                    context.fill(
                        Path(ellipseIn: CGRect(x: top.x - 3, y: top.y - 3, width: 6, height: 6)),
                        with: .color(.primary.opacity(0.65)))
                }
            }

            // The worst point, marked — where to look, and where a relay
            // would have to go.
            if let worst = worstSample() {
                let point = CGPoint(x: x(worst.distanceMetres), y: y(worst.effectiveElevation))
                context.stroke(
                    Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                    with: .color(tint), lineWidth: 2)
            }
        }
        .background(Color(platform: .platformCardBackground),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// Which end is which, and how high each antenna is standing.
    ///
    /// Under the chart rather than inside it: two callsigns drawn into a
    /// 180pt canvas either overlap the terrain or push the useful area down,
    /// and the ends of the x axis are unambiguous without a leader line.
    private var endpoints: some View {
        HStack(alignment: .top, spacing: 8) {
            endpoint(originLabel, height: profile.originHeight,
                     assumed: false, alignment: .leading)
            Spacer(minLength: 8)
            endpoint(destinationLabel, height: profile.destinationHeight,
                     assumed: destinationHeightIsAssumed, alignment: .trailing)
        }
    }

    private func endpoint(_ callsign: String, height: Double,
                          assumed: Bool,
                          alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(callsign)
                .font(.caption.weight(.medium))
            Text(assumed ? "\(describe(height)) assumed" : describe(height))
                .font(.caption2)
                .foregroundStyle(assumed ? .orange : .secondary)
        }
        .help(assumed
              ? "No antenna height recorded for \(callsign), so the forecast uses the "
                + "assumed height from Settings. This is the number the verdict is most "
                + "sensitive to \u{2014} a node on a tower reads as blocked at a default "
                + "height. Record one on this page to sharpen it."
              : "Antenna height above ground for \(callsign).")
    }

    /// A height in whichever unit the operator entered theirs in.
    private func describe(_ metres: Double) -> String {
        heightUnitIsFeet
            ? String(format: "%.0f ft", metres / 0.3048)
            : String(format: "%.0f m", metres)
    }

    /// Vertical range, padded so the line and its envelope are not clipped.
    private func verticalBounds() -> (bottom: Double, top: Double) {
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        for sample in profile.samples {
            lowest = min(lowest, sample.effectiveElevation,
                         sample.lineHeight - sample.fresnelRadius)
            highest = max(highest, sample.effectiveElevation,
                          sample.lineHeight + sample.fresnelRadius)
        }
        guard lowest < highest else { return (0, 1) }
        let padding = (highest - lowest) * 0.08
        return (lowest - padding, highest + padding)
    }

    private func worstSample() -> TerrainProfile.Sample? {
        profile.samples.dropFirst().dropLast().min { $0.fresnelRatio < $1.fresnelRatio }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 14) {
            label(colour: .secondary.opacity(0.6), text: "Terrain")
                .explain("Ground elevation plus the earth's curvature — what the signal actually has to clear. The bulge is applied with the standard 4/3 effective-radius factor, which is why a long path over flat ground can still be blocked.")
            label(colour: tint, text: "Line of sight")
                .explain("The straight line between the two antennas, at their stated heights above ground.")
            label(colour: tint.opacity(0.3), text: "Fresnel zone")
                .explain("The band that must stay clear for the path to behave like a clear one — 60% of the first Fresnel zone. Terrain inside it costs signal even when there is line of sight, which is what a path that connects and struggles looks like.")
            Spacer(minLength: 0)
        }
        .font(.caption2)
    }

    private func label(colour: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(colour)
                .frame(width: 12, height: 3)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
