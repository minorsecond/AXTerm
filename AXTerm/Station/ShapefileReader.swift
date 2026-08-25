import Foundation
import CoreLocation

/// Reads ESRI shapefile geometry.
///
/// Shapefiles are how agencies actually distribute boundaries: county lines,
/// ARES districts, evacuation zones, flood polygons, repeater coverage. An
/// operator handed a `.zip` from an EOC has a shapefile, not GeoJSON, and
/// telling them to convert it first is telling them to find a computer with
/// GDAL on it during an activation.
///
/// The format is old and simple, which is why this is a reader rather than a
/// dependency: a fixed 100-byte header, then length-prefixed records of a
/// handful of geometry types, big-endian in places and little-endian in
/// others. Only the geometry types that mean anything on a map are decoded;
/// the rest are reported as unsupported rather than silently skipped, because
/// a boundary that quietly fails to draw is worse than one that refuses to.
///
/// Attributes come from the companion `.dbf`, which is a separate old format
/// — see `DBFReader`.
nonisolated enum ShapefileReader {

    enum ReadError: Error, Equatable {
        case tooShort
        case notAShapefile(magic: Int32)
        /// A geometry this reader does not draw. Named so the operator learns
        /// which one rather than seeing an empty map.
        case unsupportedShapeType(Int32, name: String)
        case truncatedRecord(index: Int)
        /// The file declares a projection this reader cannot convert from.
        case unsupportedProjection(String)

        var explanation: String {
            switch self {
            case .tooShort:
                return "The file is too short to be a shapefile."
            case .notAShapefile(let magic):
                return "That is not a shapefile — its header starts with \(magic) rather than the expected 9994. A shapefile is usually distributed as a .zip containing .shp, .dbf and .prj files; the .shp is the one to open."
            case .unsupportedShapeType(let code, let name):
                return "This shapefile contains \(name) (type \(code)), which AXTerm does not draw. Points, lines and polygons are supported."
            case .truncatedRecord(let index):
                return "The file ends part-way through record \(index). It may have been truncated in transfer."
            case .unsupportedProjection(let name):
                return "This shapefile is projected as \(name). AXTerm reads unprojected latitude/longitude (WGS 84) only — reproject it, or ask for the WGS 84 version."
            }
        }
    }

    /// The geometry kinds worth drawing on a station map.
    enum Geometry: Equatable, Sendable {
        case point(CLLocationCoordinate2D)
        /// One or more line strings — a shapefile "polyline" may have several.
        case polyline([[CLLocationCoordinate2D]])
        /// Rings. The first is the outer boundary; any others are holes.
        case polygon([[CLLocationCoordinate2D]])

        static func == (lhs: Geometry, rhs: Geometry) -> Bool {
            switch (lhs, rhs) {
            case (.point(let a), .point(let b)):
                return a.latitude == b.latitude && a.longitude == b.longitude
            case (.polyline(let a), .polyline(let b)), (.polygon(let a), .polygon(let b)):
                guard a.count == b.count else { return false }
                return zip(a, b).allSatisfy { first, second in
                    first.count == second.count && zip(first, second).allSatisfy {
                        $0.latitude == $1.latitude && $0.longitude == $1.longitude
                    }
                }
            default:
                return false
            }
        }
    }

    /// Shape type codes from the ESRI specification.
    ///
    /// The Z and M variants carry elevation or measure values after the
    /// coordinates. Their x/y layout is identical, so they are read as their
    /// 2D equivalents and the extra dimensions ignored — a county boundary
    /// with elevations is still a county boundary.
    enum ShapeType: Int32 {
        case null = 0
        case point = 1
        case polyline = 3
        case polygon = 5
        case multipoint = 8
        case pointZ = 11
        case polylineZ = 13
        case polygonZ = 15
        case multipointZ = 18
        case pointM = 21
        case polylineM = 23
        case polygonM = 25
        case multipointM = 28
        case multipatch = 31

        var name: String {
            switch self {
            case .null: "null shapes"
            case .point, .pointZ, .pointM: "points"
            case .polyline, .polylineZ, .polylineM: "polylines"
            case .polygon, .polygonZ, .polygonM: "polygons"
            case .multipoint, .multipointZ, .multipointM: "multipoints"
            case .multipatch: "multipatch geometry"
            }
        }

        /// The 2D shape this reads as.
        var base: ShapeType {
            switch self {
            case .point, .pointZ, .pointM: .point
            case .polyline, .polylineZ, .polylineM: .polyline
            case .polygon, .polygonZ, .polygonM: .polygon
            case .multipoint, .multipointZ, .multipointM: .multipoint
            case .null: .null
            case .multipatch: .multipatch
            }
        }
    }

    static let fileMagic: Int32 = 9994
    static let headerLength = 100

    /// Reads every geometry in a `.shp`.
    ///
    /// Records that cannot be decoded stop the read rather than being
    /// skipped: a partially-drawn boundary is indistinguishable from a
    /// complete one, and an operator planning around an evacuation zone
    /// needs to know the zone is whole.
    static func read(_ data: Data) throws -> [Geometry] {
        guard data.count >= headerLength else { throw ReadError.tooShort }

        let magic = Int32(bigEndian: data.readInt32(at: 0))
        guard magic == fileMagic else { throw ReadError.notAShapefile(magic: magic) }

        var geometries: [Geometry] = []
        var offset = headerLength
        var index = 0

        while offset + 8 <= data.count {
            // Record header: number and content length, both big-endian, the
            // length in 16-bit words — a detail that has broken every naive
            // shapefile reader ever written.
            let contentWords = Int(Int32(bigEndian: data.readInt32(at: offset + 4)))
            let contentBytes = contentWords * 2
            let body = offset + 8

            guard contentBytes >= 4, body + contentBytes <= data.count else {
                throw ReadError.truncatedRecord(index: index)
            }

            let rawType = Int32(littleEndian: data.readInt32(at: body))
            guard let type = ShapeType(rawValue: rawType) else {
                throw ReadError.unsupportedShapeType(rawType, name: "an unknown shape type")
            }

            if let geometry = try decode(type: type, data: data,
                                         start: body, length: contentBytes, index: index) {
                geometries.append(geometry)
            }

            offset = body + contentBytes
            index += 1
        }

        return geometries
    }

    private static func decode(type: ShapeType, data: Data, start: Int,
                               length: Int, index: Int) throws -> Geometry? {
        switch type.base {
        case .null:
            // A legal record meaning "no geometry here". Skipped, not an error.
            return nil

        case .point:
            guard length >= 20 else { throw ReadError.truncatedRecord(index: index) }
            let x = data.readDouble(at: start + 4)
            let y = data.readDouble(at: start + 12)
            return .point(CLLocationCoordinate2D(latitude: y, longitude: x))

        case .polyline, .polygon:
            // Header: type(4) bbox(32) numParts(4) numPoints(4)
            guard length >= 44 else { throw ReadError.truncatedRecord(index: index) }
            let numParts = Int(Int32(littleEndian: data.readInt32(at: start + 36)))
            let numPoints = Int(Int32(littleEndian: data.readInt32(at: start + 40)))
            guard numParts >= 0, numPoints >= 0 else {
                throw ReadError.truncatedRecord(index: index)
            }

            let partsStart = start + 44
            let pointsStart = partsStart + numParts * 4
            guard pointsStart + numPoints * 16 <= start + length else {
                throw ReadError.truncatedRecord(index: index)
            }

            var partStarts: [Int] = []
            for part in 0..<numParts {
                partStarts.append(Int(Int32(littleEndian: data.readInt32(at: partsStart + part * 4))))
            }

            var rings: [[CLLocationCoordinate2D]] = []
            for (position, first) in partStarts.enumerated() {
                let last = position + 1 < partStarts.count ? partStarts[position + 1] : numPoints
                guard first >= 0, last <= numPoints, first <= last else {
                    throw ReadError.truncatedRecord(index: index)
                }
                var ring: [CLLocationCoordinate2D] = []
                ring.reserveCapacity(last - first)
                for point in first..<last {
                    let base = pointsStart + point * 16
                    let x = data.readDouble(at: base)
                    let y = data.readDouble(at: base + 8)
                    ring.append(CLLocationCoordinate2D(latitude: y, longitude: x))
                }
                if !ring.isEmpty { rings.append(ring) }
            }

            guard !rings.isEmpty else { return nil }
            return type.base == .polygon ? .polygon(rings) : .polyline(rings)

        case .multipoint:
            guard length >= 40 else { throw ReadError.truncatedRecord(index: index) }
            let numPoints = Int(Int32(littleEndian: data.readInt32(at: start + 36)))
            let pointsStart = start + 40
            guard numPoints >= 0, pointsStart + numPoints * 16 <= start + length else {
                throw ReadError.truncatedRecord(index: index)
            }
            // Represented as a one-part polyline of the points, which is what
            // a multipoint is on a map: several places, one feature.
            var points: [CLLocationCoordinate2D] = []
            for point in 0..<numPoints {
                let base = pointsStart + point * 16
                points.append(CLLocationCoordinate2D(latitude: data.readDouble(at: base + 8),
                                                     longitude: data.readDouble(at: base)))
            }
            return points.isEmpty ? nil : .polyline([points])

        case .multipatch:
            throw ReadError.unsupportedShapeType(type.rawValue, name: type.name)

        default:
            // Unreachable: `base` only ever returns the six cases above. Kept
            // so adding a shape type to the enum is a compile-time decision
            // rather than something that silently falls through to "drawn
            // nothing".
            throw ReadError.unsupportedShapeType(type.rawValue, name: type.name)
        }
    }

    // MARK: - Projection

    /// Checks the companion `.prj`, if there is one.
    ///
    /// A shapefile carries no coordinate system in the `.shp` itself — the
    /// numbers are just numbers. If the `.prj` says the file is in State
    /// Plane feet, reading it as latitude/longitude puts every feature in the
    /// Gulf of Guinea, and it does so *without any error*. So the projection
    /// is checked, and an unrecognised one is refused.
    ///
    /// - Parameter wkt: contents of the `.prj` file, or nil when there is none.
    static func validateProjection(_ wkt: String?) throws {
        guard let wkt, !wkt.isEmpty else {
            // No .prj at all. Overwhelmingly this means WGS 84 in practice,
            // and refusing would reject most agency downloads, so it is
            // accepted — the map will make a wrong projection obvious the
            // moment nothing appears where it should.
            return
        }
        let upper = wkt.uppercased()
        // A geographic (unprojected) coordinate system on the WGS 84 or NAD 83
        // datum reads directly as latitude/longitude. NAD 83 differs from
        // WGS 84 by about a metre, which does not matter for a boundary drawn
        // on a map of a county.
        let isGeographic = upper.hasPrefix("GEOGCS")
        let isKnownDatum = upper.contains("WGS_1984") || upper.contains("WGS 84")
            || upper.contains("WGS84") || upper.contains("NAD83") || upper.contains("NAD_1983")
        guard isGeographic, isKnownDatum else {
            throw ReadError.unsupportedProjection(Self.projectionName(wkt))
        }
    }

    /// First quoted name in the WKT, for the error message.
    static func projectionName(_ wkt: String) -> String {
        guard let open = wkt.firstIndex(of: "\""),
              let close = wkt[wkt.index(after: open)...].firstIndex(of: "\"")
        else { return "an unrecognised coordinate system" }
        return String(wkt[wkt.index(after: open)..<close])
    }
}

// MARK: - Byte reading

private extension Data {
    /// Reads without assuming the buffer starts at zero — `Data` slices keep
    /// their parent's indices, which has silently broken more binary parsers
    /// than any other single thing.
    func readInt32(at offset: Int) -> Int32 {
        let start = startIndex + offset
        return self[start..<start + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    }

    func readDouble(at offset: Int) -> Double {
        let start = startIndex + offset
        let bits = self[start..<start + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        return Double(bitPattern: UInt64(littleEndian: bits))
    }
}
