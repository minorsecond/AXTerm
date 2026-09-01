import Foundation

/// Recognising and importing spatial data that arrived over the air.
///
/// A message attachment is data from a third party, delivered by radio, and
/// opened by an operator who is usually busy. Two things follow from that:
///
/// - **Nothing is imported implicitly.** A layer appearing on the map because
///   a message arrived would be a surprise at best, and at worst a stranger
///   drawing on the operator's situational picture. The operator asks.
/// - **Malformed input refuses rather than half-draws.** The readers already
///   behave that way; this keeps the same rule at the boundary, with limits
///   sized for a device that may be a phone.
nonisolated enum MapOverlayAttachment {

    /// What an attachment turned out to be.
    enum Kind: Equatable, Sendable {
        case geoJSON
        /// A bare `.shp` with no companion files.
        case bareShapefile
        /// A zip containing a shapefile.
        case zippedShapefile

        var displayName: String {
            switch self {
            case .geoJSON: "GeoJSON"
            case .bareShapefile: "Shapefile (.shp only)"
            case .zippedShapefile: "Shapefile archive"
            }
        }
    }

    /// The largest attachment worth attempting.
    ///
    /// Anything over this arrived by some route other than packet — nobody
    /// sends 32 MB at 21 bytes per second — and parsing it on a handheld is
    /// a worse failure than declining to.
    static let maximumBytes = 32 * 1024 * 1024

    enum ImportError: Error, Equatable {
        case tooLarge(Int)
        case notSpatialData(String)
        case zip(ZipReader.ReadError)
        case shapefile(ShapefileReader.ReadError)
        case unreadable(String)
        case empty(String)

        var explanation: String {
            switch self {
            case .tooLarge(let bytes):
                "That attachment is \(ByteCount.string(Int64(bytes))), which is too large to open as a map layer."
            case .notSpatialData(let name):
                "\(name) is not map data AXTerm can read. It handles GeoJSON (.geojson, .json) and shapefiles (.shp, or a .zip containing one)."
            case .zip(let error):
                error.explanation
            case .shapefile(let error):
                error.explanation
            case .unreadable(let name):
                "\(name) could not be read. It may have been damaged in transfer."
            case .empty(let name):
                "\(name) contains no drawable features."
            }
        }
    }

    /// Whether this attachment looks like something the map could take.
    ///
    /// Name-based, deliberately: it decides whether to *offer* the action, and
    /// sniffing contents to decide whether to show a button would mean parsing
    /// every attachment of every message on arrival.
    static func kind(forAttachmentNamed name: String) -> Kind? {
        switch (name as NSString).pathExtension.lowercased() {
        case "geojson", "json": return .geoJSON
        case "shp": return .bareShapefile
        case "zip": return .zippedShapefile
        default: return nil
        }
    }

    /// Turns an attachment into a layer.
    ///
    /// - Parameter senderCallsign: named in the layer so a boundary from
    ///   somebody else is never confused with the operator's own work. Who
    ///   drew a zone matters as much as where it is.
    static func layer(from data: Data, named name: String,
                      senderCallsign: String,
                      colorName: String) throws -> MapOverlayLayer {
        guard data.count <= maximumBytes else { throw ImportError.tooLarge(data.count) }
        guard let kind = kind(forAttachmentNamed: name) else {
            throw ImportError.notSpatialData(name)
        }

        let features: [MapOverlayFeature]
        switch kind {
        case .geoJSON:
            do {
                features = try MapOverlayLoader.readGeoJSON(data, filename: name)
            } catch {
                throw ImportError.unreadable(name)
            }

        case .bareShapefile:
            // No companion `.prj`, so the coordinate system is unknown. Read
            // as WGS 84, which is what a shapefile sent over amateur radio
            // almost always is — and say so in the layer name rather than
            // silently assuming.
            do {
                features = try ShapefileReader.read(data).map { MapOverlayFeature(geometry: $0) }
            } catch let error as ShapefileReader.ReadError {
                throw ImportError.shapefile(error)
            }

        case .zippedShapefile:
            features = try readZippedShapefile(data, name: name)
        }

        guard !features.isEmpty else { throw ImportError.empty(name) }

        return MapOverlayLayer(
            id: storedName(for: name, from: senderCallsign),
            name: layerName(for: name, from: senderCallsign),
            features: features,
            colorName: colorName)
    }

    /// Reads the `.shp` out of an archive, checking its `.prj` first.
    ///
    /// The projection check is the whole reason to prefer a zip over a bare
    /// `.shp`: the `.prj` is the only thing that says whether these numbers
    /// are degrees, and reading a projected file as latitude/longitude puts
    /// every feature thousands of miles away with no error at all.
    private static func readZippedShapefile(_ data: Data, name: String) throws
        -> [MapOverlayFeature] {
        let entries: [ZipReader.Entry]
        do {
            entries = try ZipReader.entries(in: data)
        } catch let error as ZipReader.ReadError {
            throw ImportError.zip(error)
        }

        guard let shp = entries.first(where: {
            ($0.name as NSString).pathExtension.lowercased() == "shp"
        }) else {
            throw ImportError.notSpatialData(name)
        }

        let prj = entries.first {
            ($0.name as NSString).pathExtension.lowercased() == "prj"
        }.map { String(decoding: $0.data, as: UTF8.self) }

        do {
            try ShapefileReader.validateProjection(prj)
            return try ShapefileReader.read(shp.data).map { MapOverlayFeature(geometry: $0) }
        } catch let error as ShapefileReader.ReadError {
            throw ImportError.shapefile(error)
        }
    }

    /// Layer name carries the sender, so provenance survives on the map.
    static func layerName(for filename: String, from sender: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        let call = sender.trimmingCharacters(in: .whitespaces).uppercased()
        return call.isEmpty ? stem : "\(stem) (from \(call))"
    }

    /// Filename on disk, kept distinct per sender so two stations sending
    /// `zones.geojson` do not overwrite each other.
    static func storedName(for filename: String, from sender: String) -> String {
        let stem = ShapefileWriter.safeStem((filename as NSString).deletingPathExtension)
        let call = ShapefileWriter.safeStem(sender)
        return call == "layer" ? "\(stem).geojson" : "\(stem)_\(call).geojson"
    }
}
