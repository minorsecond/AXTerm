import Foundation

/// Choosing a format to send a layer in, and being honest about what that
/// costs on the air.
///
/// This is the part where an operator can waste an afternoon. A county
/// boundary is tens of thousands of coordinates; as a zipped shapefile that is
/// a megabyte or more, which at the ~21 bytes/second this station has actually
/// measured on 145.050 is **over thirteen hours** of airtime, spread across
/// dozens of sessions. The app must not present that as a normal thing to do.
///
/// Twelve marked positions, on the other hand, are a couple of kilobytes of
/// GeoJSON and cross in under a minute. That is the case worth supporting, and
/// the difference between the two is four orders of magnitude — so the size is
/// stated in airtime, not bytes, and the format that is wrong for the radio is
/// labelled as such rather than merely offered.
nonisolated enum MapOverlayExport {

    enum Format: String, CaseIterable, Identifiable, Sendable {
        /// Plain text, compresses well, readable by anything modern.
        case geoJSON
        /// Four files in a zip. What GIS software expects, and far larger.
        case shapefile

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .geoJSON: "GeoJSON"
            case .shapefile: "Shapefile (.zip)"
            }
        }

        var fileExtension: String {
            switch self {
            case .geoJSON: "geojson"
            case .shapefile: "zip"
            }
        }

        /// Why an operator would pick this one.
        var summary: String {
            switch self {
            case .geoJSON:
                "Plain text. Compresses well, so it is the format to send over the air. Opens in QGIS, ArcGIS, Google Earth and most web tools."
            case .shapefile:
                "Four files in a zip — what older GIS software expects. Several times larger than GeoJSON and mostly incompressible, so it is a poor choice for a radio link."
            }
        }
    }

    /// What sending a layer would actually cost.
    struct Assessment: Equatable, Sendable {
        var byteCount: Int
        var airtimeText: String
        var sessionsRequired: Int
        /// True when this is unreasonable to put on the air at all.
        var isImpractical: Bool
        /// Stated to the operator, in full.
        var advice: String

        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        }
    }

    /// Beyond this, sending over packet stops being a judgement call and
    /// becomes a mistake. Roughly forty minutes at this station's measured
    /// rate — long enough that the operator should be handing over a memory
    /// card instead.
    static let impracticalSeconds: Double = 40 * 60

    static func assess(byteCount: Int, airtime: WinlinkAirtimeEstimate) -> Assessment {
        let seconds = airtime.estimatedSeconds(bytes: byteCount)
        let sessions = airtime.sessionsRequired(bytes: byteCount)
        let impractical = seconds > impracticalSeconds

        var advice: String
        if impractical {
            advice = """
            This is \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)) — about \(airtime.airtimeText(bytes: byteCount)) of airtime\(sessions > 1 ? ", across roughly \(sessions) sessions" : "").

            That is not a reasonable thing to put on a shared channel. The channel is occupied for the whole of it, and any interruption starts a session again.

            Send a subset instead: the marks that matter rather than the whole boundary layer. If the recipient genuinely needs the full layer, the internet, a memory card or a phone will all do it in seconds.
            """
        } else if sessions > 1 {
            advice = """
            About \(airtime.airtimeText(bytes: byteCount)) of airtime, which will not fit in one session — expect roughly \(sessions), resuming where each leaves off.

            Workable, but the channel is busy for the duration.
            """
        } else {
            advice = "About \(airtime.airtimeText(bytes: byteCount)) of airtime in a single session."
        }

        return Assessment(byteCount: byteCount,
                          airtimeText: airtime.airtimeText(bytes: byteCount),
                          sessionsRequired: sessions,
                          isImpractical: impractical,
                          advice: advice)
    }

    /// The recommended format for a given destination.
    ///
    /// Over the air the answer is always GeoJSON: it is text, so LZHUF
    /// actually compresses it, where a zipped shapefile is already compressed
    /// and gains nothing.
    static func recommendedFormat(forRadio: Bool) -> Format {
        forRadio ? .geoJSON : .shapefile
    }

    /// A filename that survives being handled by other software.
    static func filename(layer: MapOverlayLayer, format: Format) -> String {
        "\(ShapefileWriter.safeStem(layer.name)).\(format.fileExtension)"
    }
}
