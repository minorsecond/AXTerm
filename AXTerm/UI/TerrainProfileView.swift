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

    /// What the missing tiles would cost. Nil hides the offer rather than
    /// promising a download the caller cannot perform.
    var estimate: ElevationStorage.Estimate?
    /// When a connection to this station last completed over this path with
    /// no digipeater in it. The one thing in the log that can settle whether
    /// the forecast is too pessimistic here.
    var lastDirectConnection: Date?
    /// What the whole area around this station would cost. Offered as the
    /// quieter second option: someone thinking about terrain is often about
    /// to go somewhere without a network, and this is where that occurs to
    /// them.
    var areaEstimate: ElevationStorage.Estimate?
    /// False when no elevation source covers this path, so the card says so
    /// rather than offering a download that would return nothing.
    var sourceHasCoverage: Bool = true
    /// Set when the station is too far away for a terrain profile to mean
    /// anything, in kilometres.
    var beyondRadioRange: Double?
    var isDownloading: Bool = false
    var onDownload: (() -> Void)?
    var onDownloadArea: (() -> Void)?

    @AppStorage(WinlinkSettings.heightUnitIsFeetKey) private var heightUnitIsFeet = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let kilometres = beyondRadioRange {
                outOfRange(kilometres)
            } else if profile.samples.isEmpty || profile.severity == .unknown {
                missingData
            } else {
                chart
                    .frame(minHeight: 180)
                endpoints
                // Said plainly and quietly. A coloured banner on a chart
                // that is already coloured reads as an error the operator
                // caused, and shouting that our own forecast is wrong is a
                // strange way to be trusted.
                if TerrainCalibration.outcome(
                    severity: profile.severity,
                    hasCompletedDirectConnection: lastDirectConnection != nil) == .contradicted {
                    Text(TerrainCalibration.note(callsign: destinationLabel,
                                                 lastConnected: lastDirectConnection))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caveat = profile.lossCaveat {
                    Label(caveat, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                Text(profile.headline)
                    .font(.headline)
                // The geometry under the consequence, not instead of it: how
                // far above the line and how far out is what an antenna
                // change acts on, once you know whether it is worth acting.
                Text([profile.geometryNote,
                      "\(originLabel) \u{2192} \(destinationLabel) \u{b7} \(distanceText)"]
                        .compactMap { $0 }.joined(separator: " \u{b7} "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .explain(profile.verdict.explanation(profile: profile))
    }

    private var icon: String {
        switch profile.severity {
        case .negligible: "checkmark.circle.fill"
        case .noticeable: "exclamationmark.circle.fill"
        case .severe: "exclamationmark.triangle.fill"
        case .blocking: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    /// Coloured by what the terrain costs, not by whether anything is
    /// geometrically in the way. A ridge 4 m above the line was drawn in the
    /// same red as one that ends the path, and they are not the same news.
    private var tint: Color {
        switch profile.severity {
        case .negligible: .green
        case .noticeable: .yellow
        case .severe: .orange
        case .blocking: .red
        case .unknown: .secondary
        }
    }

    private var distanceText: String {
        String(format: "%.1f km", profile.totalMetres / 1000)
    }

    /// Radius of the antenna markers, and the inset that keeps them whole.
    private static let markerRadius: Double = 4

    // MARK: - Too far for the question to mean anything

    /// A profile over a thousand kilometres draws the planet, not the ground.
    ///
    /// The earth's own curvature puts tens of kilometres between two stations
    /// that far apart, so the chart is a smooth parabola and the verdict is
    /// "blocked by 78 km of terrain" — arithmetically true, and no use to
    /// anybody. Worse, it buries the thing actually worth saying: a station
    /// heard on VHF cannot be where this position claims, so the position is
    /// what is wrong.
    private func outOfRange(_ kilometres: Double) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "location.slash")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("Too far for a terrain profile")
                .font(.headline)
            Text("This position puts \(destinationLabel) \(Int(kilometres.rounded())) km away. "
                 + "At that range the earth's curvature alone stands tens of kilometres above "
                 + "the line, so a profile would only tell you the planet is in the way. "
                 + "If you are hearing this station on VHF, the position is likely a licence "
                 + "address rather than where the radio is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 160)
    }

    // MARK: - Nothing to draw yet

    /// What to do about it, in the place the absence is noticed.
    ///
    /// The old empty state explained that data was missing and stopped there,
    /// leaving the operator to work out that the fix lived behind a menu on a
    /// different page. A path is one or two tiles; asking for them belongs
    /// here.
    @ViewBuilder
    private var missingData: some View {
        VStack(spacing: 10) {
            Image(systemName: "mountain.2")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No terrain for this path")
                .font(.headline)
            Text(profile.verdict.explanation(profile: profile))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if !sourceHasCoverage {
                // Offering a download here would fetch a tile of NaN and
                // charge the operator for it.
                Text("The elevation source covers the United States and its "
                     + "territories. It has nothing for this path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            } else if isDownloading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading\u{2026}").font(.callout)
                }
            } else if let onDownload, let estimate, estimate.tileCount > 0 {
                VStack(spacing: 4) {
                    Button {
                        onDownload()
                    } label: {
                        Text("Download terrain for this path "
                             + "(\(estimate.tileCount) tile"
                             + "\(estimate.tileCount == 1 ? "" : "s"), \(estimate.sizeDescription))")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Fetches elevation for the ground between these two stations from "
                          + "the USGS. Kept on this device, and it works offline afterwards.")

                    if let onDownloadArea, let areaEstimate, areaEstimate.tileCount > 0 {
                        Button("\u{2026}or the whole area around you "
                               + "(\(areaEstimate.sizeDescription))") {
                            onDownloadArea()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help("Every path from here in one go, instead of a couple of tiles "
                              + "each time you open a station. Worth doing before going "
                              + "somewhere with no network.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180)
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
            // The endpoints carry a marker with width, and drawing them on the
            // canvas boundary clipped half of each away — the two things the
            // chart most needs to identify were the two things cut in half.
            let inset = Self.markerRadius + 2
            let plot = CGSize(width: max(size.width - inset * 2, 1),
                              height: max(size.height - inset, 1))
            func x(_ metres: Double) -> Double {
                inset + plot.width * (metres / max(profile.totalMetres, 1))
            }
            func y(_ elevation: Double) -> Double {
                let span = max(bounds.top - bounds.bottom, 1)
                return inset + plot.height * (1 - (elevation - bounds.bottom) / span)
            }

            // Terrain, as a filled silhouette — the shape an operator reads
            // first.
            var ground = Path()
            ground.move(to: CGPoint(x: 0, y: size.height))
            ground.addLine(to: CGPoint(x: 0, y: y(profile.samples[0].effectiveElevation)))
            for sample in profile.samples {
                ground.addLine(to: CGPoint(x: x(sample.distanceMetres),
                                           y: y(sample.effectiveElevation)))
            }
            // Carried flat to the frame so the ground reads as ground rather
            // than as a slab that stops short of the edge.
            ground.addLine(to: CGPoint(x: size.width,
                                       y: y(profile.samples[profile.samples.count - 1].effectiveElevation)))
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
            // Outlined rather than washed. Filled at any weight that reads
            // in both appearances, the band covered the ridge line it exists
            // to be compared against.
            context.fill(envelope, with: .color(tint.opacity(0.07)))
            context.stroke(envelope, with: .color(tint.opacity(0.65)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

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
                    let px = x(sample.distanceMetres)
                    var mast = Path()
                    mast.move(to: CGPoint(x: px, y: y(sample.effectiveElevation)))
                    mast.addLine(to: CGPoint(x: px, y: y(sample.lineHeight)))
                    context.stroke(mast, with: .color(.primary.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                    // Our end is a ring, theirs is solid — the same two glyphs
                    // appear beside the callsigns underneath, so which end of
                    // the chart is this station takes no working out.
                    let top = CGPoint(x: px, y: y(sample.lineHeight))
                    let r = Self.markerRadius
                    let disc = Path(ellipseIn: CGRect(x: top.x - r, y: top.y - r,
                                                      width: r * 2, height: r * 2))
                    if atOrigin {
                        context.fill(disc, with: .color(Color(platform: .platformCardBackground)))
                        context.stroke(disc, with: .color(.primary.opacity(0.75)), lineWidth: 2)
                    } else {
                        context.fill(disc, with: .color(.primary.opacity(0.75)))
                    }
                }
            }

            // Every obstruction, with the governing one drawn in full.
            //
            // The caption counts them, so marking only the worst left an
            // operator told about "2 separate obstructions" hunting for the
            // second with no idea where it was. The lesser ones are a tick on
            // the ground: enough to find, quiet enough not to compete with the
            // one the verdict came from.
            let governing = worstSample()
            for obstruction in profile.obstructions {
                let px = x(obstruction.distanceMetres)
                let onTerrain = CGPoint(x: px, y: y(obstruction.effectiveElevation))
                let isGoverning = obstruction.distanceMetres == governing?.distanceMetres

                if isGoverning {
                    // The intrusion drawn as the measurement it is. At this
                    // scale a few metres of terrain and the line simply touch,
                    // and the whole story is in those pixels.
                    let onLine = CGPoint(x: px, y: y(obstruction.lineHeight))
                    var gap = Path()
                    gap.move(to: onLine)
                    gap.addLine(to: onTerrain)
                    context.stroke(gap, with: .color(tint),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                    for end in [onTerrain, onLine] {
                        var tick = Path()
                        tick.move(to: CGPoint(x: end.x - 4, y: end.y))
                        tick.addLine(to: CGPoint(x: end.x + 4, y: end.y))
                        context.stroke(tick, with: .color(tint), lineWidth: 1.5)
                    }
                    context.stroke(
                        Path(ellipseIn: CGRect(x: onTerrain.x - 4, y: onTerrain.y - 4,
                                               width: 8, height: 8)),
                        with: .color(tint), lineWidth: 2)
                } else {
                    var tick = Path()
                    tick.move(to: CGPoint(x: px, y: onTerrain.y - 5))
                    tick.addLine(to: CGPoint(x: px, y: onTerrain.y + 1))
                    context.stroke(tick, with: .color(tint.opacity(0.55)), lineWidth: 1.5)
                }
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
        // The glyph is the whole point of this row: it is what ties a name to
        // one of the two antennas on the chart. Hollow for this station,
        // solid for the far one, drawn exactly as the chart draws them.
        let marker = Circle()
            .strokeBorder(.primary.opacity(0.75), lineWidth: 2)
            .background(Circle().fill(alignment == .leading
                                      ? Color.clear : .primary.opacity(0.75)))
            .frame(width: 8, height: 8)
        return VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 4) {
                if alignment == .trailing { Text(callsign).font(.caption.weight(.medium)) }
                marker
                if alignment == .leading { Text(callsign).font(.caption.weight(.medium)) }
            }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                // Each key draws the way the chart draws it. Three identical
                // bars in three colours told you nothing about which mark on
                // the chart was which, and after the Fresnel band became a
                // dashed outline the solid bar was simply wrong.
                key(.filled(.secondary.opacity(0.6)), "Terrain")
                    .explain("Ground elevation plus the earth's curvature, which is what the signal actually has to clear. The bulge uses the standard 4/3 effective-radius factor, which is why a long path over flat ground can still be blocked.")
                key(.line(tint), "Line of sight")
                    .explain("The straight line between the two antennas, at their stated heights above ground.")
                key(.dashed(tint.opacity(0.65)), "Fresnel zone")
                    .explain("60% of the first Fresnel zone. Terrain inside it costs signal even when the line of sight is open, which is what a path that connects and struggles looks like.")
                Spacer(minLength: 0)
            }
            // Answers the question the term raises, where it is raised. A
            // tooltip only helps someone who already suspects there is
            // something to hover over.
            Text("Radio needs room around the line of sight, not just a clear view. "
                 + "Terrain inside the Fresnel zone costs signal even when nothing "
                 + "blocks the line itself.")
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
    }

    /// How a thing is drawn on the chart, so its key can be drawn the same.
    private enum KeyStyle {
        case filled(Color)
        case line(Color)
        case dashed(Color)
    }

    private func key(_ style: KeyStyle, _ text: String) -> some View {
        HStack(spacing: 4) {
            Group {
                switch style {
                case .filled(let colour):
                    RoundedRectangle(cornerRadius: 1).fill(colour)
                        .frame(width: 12, height: 8)
                case .line(let colour):
                    RoundedRectangle(cornerRadius: 1).fill(colour)
                        .frame(width: 12, height: 2)
                case .dashed(let colour):
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 1))
                        path.addLine(to: CGPoint(x: 12, y: 1))
                    }
                    .stroke(colour, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 12, height: 2)
                }
            }
            .frame(width: 12, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
