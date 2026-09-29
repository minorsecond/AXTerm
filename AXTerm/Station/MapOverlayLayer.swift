import Foundation
import MapKit
import Combine
import CoreLocation

/// One drawable thing on a layer, with whatever the file said about it.
///
/// Attributes are carried rather than discarded because they are usually the
/// point: a polygon is not "a polygon", it is "Evacuation Zone C" or "Douglas
/// County". A layer that draws shapes with no names is a decoration.
nonisolated struct MapOverlayFeature: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var geometry: ShapefileReader.Geometry
    /// String attributes only. Shapefile `.dbf` and GeoJSON both carry richer
    /// types, but everything this app does with them is display them, and a
    /// single representation avoids a type ladder nobody reads.
    var attributes: [String: String]
    /// True for something the operator placed here, as opposed to something
    /// that arrived in a file. Only these are editable — silently rewriting
    /// an agency's boundary would be worse than refusing to.
    var isUserPlaced: Bool

    init(id: UUID = UUID(), name: String = "",
         geometry: ShapefileReader.Geometry,
         attributes: [String: String] = [:],
         isUserPlaced: Bool = false) {
        self.id = id
        self.name = name
        self.geometry = geometry
        self.attributes = attributes
        self.isUserPlaced = isUserPlaced
    }
}

/// Vector data drawn over the basemap: county lines, ARES districts,
/// evacuation zones, flood polygons, marked positions.
///
/// The basemap answers "what is the terrain here". These answer "what are the
/// boundaries that matter to this activation". Both are stored locally, so a
/// layer loaded before an activation is there during it.
nonisolated struct MapOverlayLayer: Identifiable, Equatable, Sendable {

    let id: String
    var name: String
    var features: [MapOverlayFeature]
    /// Stored as a name rather than a `Color` so the layer stays free of
    /// SwiftUI and can be persisted and tested.
    var colorName: String
    var isVisible: Bool
    /// True for a layer the operator is building rather than one that came
    /// from a file. Features can only be added to these.
    var isEditable: Bool

    init(id: String, name: String, features: [MapOverlayFeature],
         colorName: String, isVisible: Bool = true, isEditable: Bool = false) {
        self.id = id
        self.name = name
        self.features = features
        self.colorName = colorName
        self.isVisible = isVisible
        self.isEditable = isEditable
    }

    /// The palette offered for layers, in the order it is handed out.
    ///
    /// Deliberately avoids the greens, yellows and oranges the station markers
    /// use: an overlay sharing a colour with "answers / patchy / rarely"
    /// invites reading a boundary as a link quality.
    static let palette = ["blue", "purple", "teal", "indigo", "brown", "pink"]

    static func color(forIndex index: Int) -> String {
        palette[index % palette.count]
    }

    var featureCount: Int { features.count }
    var geometries: [ShapefileReader.Geometry] { features.map(\.geometry) }

    /// Every coordinate, for framing the map on the layer.
    var coordinates: [CLLocationCoordinate2D] {
        features.flatMap { feature -> [CLLocationCoordinate2D] in
            switch feature.geometry {
            case .point(let coordinate): [coordinate]
            case .polyline(let parts), .polygon(let parts): parts.flatMap { $0 }
            }
        }
    }

    /// MapKit overlays for the renderer.
    ///
    /// Polygons keep their holes: the first ring is the boundary and the rest
    /// are interior. Dropping them would draw a solid county over a lake.
    func mapKitOverlays() -> [MKOverlay] {
        features.compactMap { feature -> MKOverlay? in
            switch feature.geometry {
            case .point(let coordinate):
                // A point has no area; drawn as a small circle so it is
                // visible at any zoom rather than a zero-size overlay.
                return MKCircle(center: coordinate, radius: 120)

            case .polyline(let parts):
                let lines = parts.filter { $0.count >= 2 }.map {
                    MKPolyline(coordinates: $0, count: $0.count)
                }
                guard !lines.isEmpty else { return nil }
                return lines.count == 1 ? lines[0] : MKMultiPolyline(lines)

            case .polygon(let rings):
                guard let outer = rings.first, outer.count >= 3 else { return nil }
                let holes = rings.dropFirst()
                    .filter { $0.count >= 3 }
                    .map { MKPolygon(coordinates: $0, count: $0.count) }
                return MKPolygon(coordinates: outer, count: outer.count,
                                 interiorPolygons: holes.isEmpty ? nil : Array(holes))
            }
        }
    }
}

// MARK: - Loading

/// Reads overlay files the operator picked.
nonisolated enum MapOverlayLoader {

    enum LoadError: Error, Equatable {
        case unreadable(String)
        case unsupportedFormat(String)
        case empty(String)
        case shapefile(ShapefileReader.ReadError)

        var explanation: String {
            switch self {
            case .unreadable(let name):
                "\(name) could not be read."
            case .unsupportedFormat(let ext):
                "AXTerm reads shapefiles (.shp) and GeoJSON (.geojson or .json). It does not read .\(ext)."
            case .empty(let name):
                "\(name) contains no drawable features. It may hold only attributes, or only geometry types AXTerm does not draw."
            case .shapefile(let error):
                error.explanation
            }
        }
    }

    static let shapefileExtensions: Set<String> = ["shp"]
    static let geoJSONExtensions: Set<String> = ["geojson", "json"]

    /// Loads one file into a layer.
    ///
    /// - Parameter projectionWKT: contents of the companion `.prj`, when the
    ///   caller could find one. A shapefile carries no coordinate system in
    ///   the `.shp` itself, and reading a projected file as latitude/longitude
    ///   places every feature thousands of miles away without any error — so
    ///   the check happens here rather than being left to the eye.
    static func load(data: Data, filename: String,
                     projectionWKT: String? = nil,
                     colorName: String) throws -> MapOverlayLayer {
        let ext = (filename as NSString).pathExtension.lowercased()
        let name = (filename as NSString).deletingPathExtension

        let features: [MapOverlayFeature]
        if shapefileExtensions.contains(ext) {
            do {
                try ShapefileReader.validateProjection(projectionWKT)
                features = try ShapefileReader.read(data).map { MapOverlayFeature(geometry: $0) }
            } catch let error as ShapefileReader.ReadError {
                throw LoadError.shapefile(error)
            }
        } else if geoJSONExtensions.contains(ext) {
            features = try readGeoJSON(data, filename: filename)
        } else {
            throw LoadError.unsupportedFormat(ext.isEmpty ? "that file" : ext)
        }

        guard !features.isEmpty else { throw LoadError.empty(filename) }
        return MapOverlayLayer(id: filename, name: name, features: features,
                               colorName: colorName)
    }

    /// GeoJSON via MapKit's own decoder.
    ///
    /// Converted into the same feature model as shapefiles so the rest of the
    /// app has one representation to draw, not two.
    static func readGeoJSON(_ data: Data, filename: String) throws -> [MapOverlayFeature] {
        let objects: [MKGeoJSONObject]
        do {
            objects = try MKGeoJSONDecoder().decode(data)
        } catch {
            throw LoadError.unreadable(filename)
        }

        var features: [MapOverlayFeature] = []
        for object in objects {
            let attributes = Self.attributes(of: object)
            let name = attributes["name"] ?? attributes["NAME"] ?? ""
            for geometry in Self.geometries(in: object) {
                features.append(MapOverlayFeature(
                    name: name, geometry: geometry, attributes: attributes,
                    // Round-trips a layer the operator drew: a file AXTerm
                    // wrote reloads as editable rather than frozen.
                    isUserPlaced: attributes["axterm_placed"] == "1"))
            }
        }
        return features
    }

    /// Feature properties, flattened to strings.
    private static func attributes(of object: MKGeoJSONObject) -> [String: String] {
        guard let feature = object as? MKGeoJSONFeature,
              let data = feature.properties,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        return raw.reduce(into: [String: String]()) { result, entry in
            switch entry.value {
            case let text as String: result[entry.key] = text
            case let number as NSNumber: result[entry.key] = number.stringValue
            case is NSNull: break
            default: result[entry.key] = String(describing: entry.value)
            }
        }
    }

    private static func geometries(in object: MKGeoJSONObject) -> [ShapefileReader.Geometry] {
        var result: [ShapefileReader.Geometry] = []
        for shape in Self.shapes(in: object) {
            switch shape {
            case let point as MKPointAnnotation:
                result.append(.point(point.coordinate))
            case let polygon as MKPolygon:
                var rings = [Self.coordinates(of: polygon)]
                rings.append(contentsOf: (polygon.interiorPolygons ?? []).map(Self.coordinates(of:)))
                result.append(.polygon(rings))
            case let multi as MKMultiPolygon:
                for polygon in multi.polygons {
                    var rings = [Self.coordinates(of: polygon)]
                    rings.append(contentsOf: (polygon.interiorPolygons ?? []).map(Self.coordinates(of:)))
                    result.append(.polygon(rings))
                }
            case let line as MKPolyline:
                result.append(.polyline([Self.coordinates(of: line)]))
            case let multi as MKMultiPolyline:
                result.append(.polyline(multi.polylines.map(Self.coordinates(of:))))
            default:
                // A geometry MapKit produced that this does not draw. Skipped
                // rather than fatal: GeoJSON files routinely mix types, and
                // one unusual feature should not cost the other thousand.
                continue
            }
        }
        return result
    }

    private static func shapes(in object: MKGeoJSONObject) -> [MKShape] {
        if let feature = object as? MKGeoJSONFeature { return feature.geometry }
        if let shape = object as? MKShape { return [shape] }
        return []
    }

    private static func coordinates(of overlay: MKMultiPoint) -> [CLLocationCoordinate2D] {
        var points = [CLLocationCoordinate2D](repeating: .init(),
                                              count: overlay.pointCount)
        overlay.getCoordinates(&points, range: NSRange(location: 0, length: overlay.pointCount))
        return points
    }
}
