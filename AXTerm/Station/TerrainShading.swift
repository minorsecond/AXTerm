import Foundation
import CoreGraphics

/// Turns an elevation grid into pixels.
///
/// The terrain data already decides which paths AXTerm calls blocked, but it
/// is invisible — an operator is told "there is a ridge 40 m above the line"
/// and has to take it on faith. Drawing the same grid the forecaster reads
/// puts the ridge on the map, in the place the verdict is talking about.
///
/// Pure arithmetic on purpose: a hillshade is easy to get subtly wrong —
/// upside down, lit from the wrong side, no-data rendered as sea level — and
/// every one of those looks plausible until you compare it with a real map.
nonisolated enum TerrainShading {

    enum Style: String, CaseIterable, Identifiable, Sendable {
        /// Relief shading. Reads as landscape rather than as data, and shows
        /// ridge lines, which is the feature that actually blocks paths.
        case hillshade
        /// Absolute height as colour, for judging whether a site is high.
        case elevation

        var id: String { rawValue }

        var label: String {
            switch self {
            case .hillshade: return "Hillshade"
            case .elevation: return "Elevation"
            }
        }

        /// How the layer combines with the map underneath.
        ///
        /// MapKit has no overlay level below the roads, so a terrain layer is
        /// always drawn on top of them — painting it opaquely buries the
        /// street grid, the labels and the network lines the map is for.
        /// Multiplying instead of painting is what real cartographic relief
        /// does: it darkens what is already there rather than replacing it,
        /// so roads still read through the shading.
        var blendMode: CGBlendMode {
            switch self {
            case .hillshade: return .multiply
            // A hypsometric tint multiplied goes muddy, and its job is to
            // colour rather than to shade. Kept as a light wash instead.
            case .elevation: return .normal
            }
        }

        /// Layer opacity, applied to the whole tile rather than per pixel so
        /// it can be tuned in one place.
        var opacity: CGFloat {
            switch self {
            case .hillshade: return 0.75
            // Deliberately faint. This is background information about
            // height, not the subject of the map.
            case .elevation: return 0.32
            }
        }
    }

    /// Where the light comes from: north-west, 45° up.
    ///
    /// The cartographic convention, and not an arbitrary one — lit from the
    /// north-west, ridges read as ridges. Lit from the south-east the same
    /// image inverts perceptually and valleys look like hills.
    static let sunAzimuthDegrees: Double = 315
    static let sunAltitudeDegrees: Double = 45

    /// Vertical exaggeration.
    ///
    /// At ~100 m sample spacing, true-scale shading of anything short of a
    /// cliff is nearly flat grey. Ordinary relief needs a nudge to be legible.
    static let verticalExaggeration: Double = 2.0

    /// The range the elevation ramp spans, in metres.
    ///
    /// Fixed rather than per-tile. Normalising each tile against its own
    /// extremes would make neighbouring tiles disagree about what a colour
    /// means, and a seam would appear across the map wherever a tile boundary
    /// fell — worse, a flat tile would light up as if it were mountainous.
    static let elevationRange: ClosedRange<Double> = 0...4500

    /// RGBA bytes, row-major, starting at the north edge — the order the grid
    /// is stored in and the order an image wants.
    ///
    /// - Parameters:
    ///   - grid: `samples` × `samples` metres above sea level, NaN for gaps.
    ///   - metresPerSampleX/Y: ground distance between samples. They differ:
    ///     a degree of longitude is shorter than a degree of latitude
    ///     everywhere but the equator, and using one for both tilts every
    ///     slope on the map.
    static func rgba(from grid: [Float], samples: Int, style: Style,
                     metresPerSampleX: Double, metresPerSampleY: Double) -> [UInt8] {
        precondition(grid.count == samples * samples, "grid is not square")
        var pixels = [UInt8](repeating: 0, count: samples * samples * 4)

        for row in 0..<samples {
            for column in 0..<samples {
                let index = row * samples + column
                let value = Double(grid[index])
                let offset = index * 4

                // A gap stays transparent. Shading it as sea level would draw
                // a flat plain over unknown ground, which is the one mistake
                // here that actively misleads.
                guard value.isFinite else { continue }

                let (r, g, b, a): (UInt8, UInt8, UInt8, UInt8)
                switch style {
                case .hillshade:
                    let shade = hillshade(grid: grid, samples: samples,
                                          row: row, column: column,
                                          metresPerSampleX: metresPerSampleX,
                                          metresPerSampleY: metresPerSampleY)
                    guard let shade else { continue }
                    let level = UInt8(clamping: Int((relief(from: shade) * 255).rounded()))
                    // Opaque here; the layer's own opacity does the blending.
                    // Per-pixel alpha as well would make the two interact and
                    // leave the strength impossible to reason about.
                    (r, g, b, a) = (level, level, level, 255)
                case .elevation:
                    let tint = elevationTint(metres: value)
                    (r, g, b, a) = (tint.0, tint.1, tint.2, 255)
                }
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = a
            }
        }
        return pixels
    }

    /// Rescales a hillshade so flat ground is white.
    ///
    /// Raw hillshade puts level ground at cos(zenith) — mid-grey — and
    /// multiplying that over the map darkens *everything* uniformly, which is
    /// how the first version turned Denver brown and buried the streets.
    /// Dividing through by the flat-ground value makes level terrain 1.0,
    /// which multiplies to no change at all, so only actual slopes darken and
    /// the relief is all that shows.
    static func relief(from shade: Double) -> Double {
        let flat = cos((90 - sunAltitudeDegrees) * .pi / 180)
        guard flat > 0 else { return shade }
        return min(shade / flat, 1)
    }

    /// Horn's method: slope and aspect from the eight neighbours.
    ///
    /// Returns nil where any neighbour is missing, rather than substituting a
    /// value — a fabricated neighbour produces a fabricated slope, and the
    /// edge of a coverage hole is exactly where that would show up as a
    /// convincing cliff that is not there.
    static func hillshade(grid: [Float], samples: Int, row: Int, column: Int,
                          metresPerSampleX: Double,
                          metresPerSampleY: Double) -> Double? {
        func value(_ r: Int, _ c: Int) -> Double? {
            guard r >= 0, r < samples, c >= 0, c < samples else { return nil }
            let sample = Double(grid[r * samples + c])
            return sample.isFinite ? sample : nil
        }

        guard let a = value(row - 1, column - 1), let b = value(row - 1, column),
              let c = value(row - 1, column + 1), let d = value(row, column - 1),
              let f = value(row, column + 1), let g = value(row + 1, column - 1),
              let h = value(row + 1, column), let i = value(row + 1, column + 1)
        else { return nil }

        let dzdx = ((c + 2 * f + i) - (a + 2 * d + g)) / (8 * metresPerSampleX)
        // Row 0 is the north edge, so increasing row index runs south. The
        // sign here is what keeps the light on the correct side.
        let dzdy = ((g + 2 * h + i) - (a + 2 * b + c)) / (8 * metresPerSampleY)

        let slope = atan(verticalExaggeration * (dzdx * dzdx + dzdy * dzdy).squareRoot())
        var aspect = atan2(dzdy, -dzdx)
        if aspect < 0 { aspect += 2 * .pi }

        let zenith = (90 - sunAltitudeDegrees) * .pi / 180
        let azimuth = (360 - sunAzimuthDegrees + 90) * .pi / 180

        let shade = cos(zenith) * cos(slope)
            + sin(zenith) * sin(slope) * cos(azimuth - aspect)
        return min(max(shade, 0), 1)
    }

    /// A hypsometric ramp: green lowland through tan and brown to white.
    static func elevationTint(metres: Double) -> (UInt8, UInt8, UInt8) {
        let span = elevationRange.upperBound - elevationRange.lowerBound
        let t = min(max((metres - elevationRange.lowerBound) / span, 0), 1)

        // Stops chosen so the Front Range reads the way a paper map does:
        // the plains green, the foothills tan, the peaks pale.
        let stops: [(position: Double, color: (Double, Double, Double))] = [
            (0.00, (90, 140, 90)),
            (0.30, (190, 180, 120)),
            (0.55, (160, 120, 85)),
            (0.75, (135, 110, 100)),
            (1.00, (245, 245, 245)),
        ]

        for index in 1..<stops.count where t <= stops[index].position {
            let lower = stops[index - 1], upper = stops[index]
            let span = upper.position - lower.position
            let local = span > 0 ? (t - lower.position) / span : 0
            func mix(_ a: Double, _ b: Double) -> UInt8 {
                UInt8(clamping: Int((a + (b - a) * local).rounded()))
            }
            return (mix(lower.color.0, upper.color.0),
                    mix(lower.color.1, upper.color.1),
                    mix(lower.color.2, upper.color.2))
        }
        let last = stops[stops.count - 1].color
        return (UInt8(last.0), UInt8(last.1), UInt8(last.2))
    }

    /// Ground distance between samples in a one-degree tile.
    ///
    /// Longitude converges toward the poles, so the two differ everywhere but
    /// the equator. Judged at the tile's mid-latitude.
    static func metresPerSample(tileLatitude: Int, samples: Int)
        -> (x: Double, y: Double) {
        let midLatitude = Double(tileLatitude) + 0.5
        let metresPerDegreeLatitude = 111_320.0
        let metresPerDegreeLongitude = metresPerDegreeLatitude
            * cos(midLatitude * .pi / 180)
        let perSample = Double(max(samples - 1, 1))
        return (x: abs(metresPerDegreeLongitude) / perSample,
                y: metresPerDegreeLatitude / perSample)
    }
}
