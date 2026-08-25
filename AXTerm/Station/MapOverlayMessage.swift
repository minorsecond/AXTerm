import Foundation
import CoreLocation

/// Builds a Winlink message carrying a map layer.
///
/// The coordinate system is stated in the body, always, and not merely implied
/// by the attachment. This is the difference between the recipient plotting a
/// zone in Colorado and plotting it in the Gulf of Guinea, and it is exactly
/// the kind of thing that gets lost when a file is forwarded on: GeoJSON's
/// specification mandates WGS 84, but the person opening it in twenty minutes
/// under pressure will not be reading RFC 7946 to confirm that.
///
/// For a shapefile the `.prj` is in the zip and is authoritative. For GeoJSON
/// there is no sidecar to carry it, so the body carries it instead — including
/// the full WKT, so a recipient whose software wants one can paste it into a
/// `.prj` and be certain.
nonisolated enum MapOverlayMessage {

    /// The `crs` member GeoJSON used to have.
    ///
    /// RFC 7946 **removed** it and fixed the coordinate system at WGS 84, so
    /// writing one back into the file would produce something that is no
    /// longer valid GeoJSON and that some parsers reject. Stating it in the
    /// message body is the correct way to be explicit without corrupting the
    /// attachment.
    static let coordinateSystemName = "WGS 84 (EPSG:4326), longitude/latitude in decimal degrees"

    struct Draft: Equatable, Sendable {
        var subject: String
        var body: String
        var attachmentName: String
        var attachment: Data
    }

    /// Builds the message for a layer.
    ///
    /// - Parameter assessment: what this costs on the air, from
    ///   `MapOverlayExport.assess`. Included in the body so the *recipient*
    ///   knows what they are being sent before they download it on a link as
    ///   slow as the one it arrived over.
    static func draft(layer: MapOverlayLayer,
                      format: MapOverlayExport.Format,
                      attachment: Data,
                      assessment: MapOverlayExport.Assessment,
                      operatorCallsign: String,
                      generatedAt: Date) -> Draft {

        let counts = Self.featureSummary(layer)
        var lines: [String] = []

        lines.append("Map layer: \(layer.name)")
        lines.append("")
        lines.append("Features: \(counts)")
        lines.append("Format: \(format.displayName)")
        lines.append("Coordinate system: \(coordinateSystemName)")
        lines.append("Size: \(assessment.sizeDescription)")
        lines.append("Prepared: \(Self.timestamp(generatedAt)) by \(operatorCallsign.uppercased())")

        switch format {
        case .geoJSON:
            lines.append("")
            lines.append("GeoJSON per RFC 7946: coordinates are [longitude, latitude] in that order, on WGS 84. There is no projection sidecar in this format. If your software asks for one, this is the equivalent WKT:")
            lines.append("")
            lines.append(ShapefileWriter.wgs84WKT)
        case .shapefile:
            lines.append("")
            lines.append("The archive contains .shp, .shx, .dbf and .prj. The .prj declares WGS 84 and is authoritative — if your software offers to assume a different coordinate system, decline.")
        }

        if !layer.features.isEmpty {
            lines.append("")
            lines.append("Contents:")
            for feature in layer.features.prefix(Self.listedFeatureLimit) {
                lines.append("  \(Self.describe(feature))")
            }
            if layer.features.count > Self.listedFeatureLimit {
                // Truncation is disclosed rather than silent: the recipient
                // must be able to tell a short list from a shortened one.
                lines.append("  (\(layer.features.count - Self.listedFeatureLimit) more in the attachment)")
            }
        }

        return Draft(
            subject: "Map layer: \(layer.name)",
            body: lines.joined(separator: "\r\n") + "\r\n",
            attachmentName: MapOverlayExport.filename(layer: layer, format: format),
            attachment: attachment)
    }

    /// How many features are listed in the body before it is truncated.
    ///
    /// The body is airtime too. Twenty lines is enough to recognise what
    /// arrived; a hundred would double the message for a list the attachment
    /// already contains.
    static let listedFeatureLimit = 20

    static func featureSummary(_ layer: MapOverlayLayer) -> String {
        var points = 0, lines = 0, areas = 0
        for feature in layer.features {
            switch feature.geometry {
            case .point: points += 1
            case .polyline: lines += 1
            case .polygon: areas += 1
            }
        }
        var parts: [String] = []
        if points > 0 { parts.append("\(points) mark\(points == 1 ? "" : "s")") }
        if lines > 0 { parts.append("\(lines) line\(lines == 1 ? "" : "s")") }
        if areas > 0 { parts.append("\(areas) area\(areas == 1 ? "" : "s")") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    /// One line per feature: its name and, for a mark, where it is.
    ///
    /// A position in the body means the most important case — a handful of
    /// marked locations — is readable even if the attachment is stripped,
    /// truncated, or opened on something with no mapping software at all.
    static func describe(_ feature: MapOverlayFeature) -> String {
        let name = feature.name.isEmpty ? "(unnamed)" : feature.name
        switch feature.geometry {
        case .point(let coordinate):
            // Degrees-decimal-minutes, matching the format the Winlink
            // position templates use — the recipient reads it in the same
            // shape as every other position this network carries.
            let location = StationLocation(latitude: coordinate.latitude,
                                           longitude: coordinate.longitude,
                                           gridSquare: "", source: .gps, timestamp: Date())
            return "\(name)  \(StationLocationFormat.degreeMinute(location))"
        case .polyline(let parts):
            let count = parts.reduce(0) { $0 + $1.count }
            return "\(name)  line, \(count) points"
        case .polygon(let rings):
            let count = rings.first?.count ?? 0
            return "\(name)  area, \(count) corners"
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date) + " UTC"
    }
}
