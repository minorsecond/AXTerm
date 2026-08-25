import Foundation
import CoreLocation

/// Writes ESRI shapefiles.
///
/// The reader exists because agencies hand out shapefiles; the writer exists
/// because they expect them back. An operator who marked twelve positions
/// during an activation and is asked to send them to the EOC's GIS person
/// needs a shapefile, not a format that person's software will not open.
///
/// A "shapefile" is really four files that must agree with each other:
///
/// - `.shp` the geometry
/// - `.shx` an index into it, byte offset and length per record
/// - `.dbf` the attributes, one dBASE III row per record
/// - `.prj` the coordinate system, without which the numbers are just numbers
///
/// They are emitted together, in a zip, because a shapefile delivered as a
/// lone `.shp` is a shapefile nobody can use — and because the `.prj` is the
/// difference between a boundary landing in Colorado and landing in the Gulf
/// of Guinea.
///
/// One geometry type per file, which is the format's own rule: a shapefile
/// declares its shape type in the header and every record must match. Mixing
/// points and polygons in one file produces something most readers reject.
nonisolated enum ShapefileWriter {

    enum WriteError: Error, Equatable {
        case empty
        case mixedGeometryTypes([String])

        var explanation: String {
            switch self {
            case .empty:
                "There is nothing to export."
            case .mixedGeometryTypes(let kinds):
                "A shapefile holds one geometry type, and this layer has \(kinds.joined(separator: ", ")). Export as GeoJSON instead, which allows mixed types, or split the layer."
            }
        }
    }

    /// WGS 84 geographic, matching what everything in this app stores.
    static let wgs84WKT = """
    GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],\
    PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]]
    """

    static let fileMagic: Int32 = 9994
    static let version: Int32 = 1000

    // MARK: - Entry point

    /// Every component file, keyed by extension.
    static func components(layer: MapOverlayLayer) throws -> [String: Data] {
        guard !layer.features.isEmpty else { throw WriteError.empty }

        let kinds = Set(layer.features.map { Self.kind(of: $0.geometry) })
        guard kinds.count == 1, let kind = kinds.first else {
            throw WriteError.mixedGeometryTypes(kinds.sorted())
        }

        let shapeType = Self.shapeType(for: kind)
        let bounds = Self.bounds(of: layer)

        var records: [Data] = []
        for feature in layer.features {
            records.append(content(for: feature.geometry, shapeType: shapeType))
        }

        return [
            "shp": shp(records: records, shapeType: shapeType, bounds: bounds),
            "shx": shx(records: records, shapeType: shapeType, bounds: bounds),
            "dbf": DBFWriter.data(for: layer.features),
            "prj": Data(wgs84WKT.utf8),
        ]
    }

    /// The four files in one zip, named after the layer.
    static func zippedShapefile(layer: MapOverlayLayer) throws -> Data {
        let stem = Self.safeStem(layer.name)
        let parts = try components(layer: layer)
        return ZipWriter.archive(files: parts.map { (name: "\(stem).\($0.key)", data: $0.value) }
            .sorted { $0.name < $1.name })
    }

    /// A filename other software will accept: no spaces, no punctuation.
    ///
    /// dBASE and older GIS tools are unforgiving about both, and a layer
    /// called "Evac Zone C (draft)" would produce a file some readers refuse
    /// to open.
    static func safeStem(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = name.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "layer" : String(trimmed.prefix(60))
    }

    // MARK: - Geometry

    static func kind(of geometry: ShapefileReader.Geometry) -> String {
        switch geometry {
        case .point: "points"
        case .polyline: "lines"
        case .polygon: "areas"
        }
    }

    static func shapeType(for kind: String) -> Int32 {
        switch kind {
        case "points": 1
        case "lines": 3
        default: 5
        }
    }

    /// One record's content, without the record header.
    static func content(for geometry: ShapefileReader.Geometry, shapeType: Int32) -> Data {
        var data = Data()
        data.append(littleEndian: shapeType)

        switch geometry {
        case .point(let coordinate):
            data.append(littleEndian: coordinate.longitude)
            data.append(littleEndian: coordinate.latitude)

        case .polyline(let parts):
            appendParts(&data, parts: parts)

        case .polygon(let rings):
            // A shapefile polygon's outer ring must wind clockwise and its
            // holes counter-clockwise. Readers use the winding to tell which
            // is which, so a ring wound the wrong way becomes a hole — and
            // the county disappears, leaving a hole-shaped gap.
            let outer = rings.first.map { Self.wound($0, clockwise: true) } ?? []
            let holes = rings.dropFirst().map { Self.wound($0, clockwise: false) }
            appendParts(&data, parts: [outer] + holes, closeRings: true)
        }

        return data
    }

    private static func appendParts(_ data: inout Data,
                                    parts: [[CLLocationCoordinate2D]],
                                    closeRings: Bool = false) {
        let rings = closeRings ? parts.map(GeoJSONWriter.closed) : parts
        let box = Self.boundingBox(of: rings.flatMap { $0 })

        data.append(littleEndian: box.minX)
        data.append(littleEndian: box.minY)
        data.append(littleEndian: box.maxX)
        data.append(littleEndian: box.maxY)
        data.append(littleEndian: Int32(rings.count))
        data.append(littleEndian: Int32(rings.reduce(0) { $0 + $1.count }))

        var start: Int32 = 0
        for ring in rings {
            data.append(littleEndian: start)
            start += Int32(ring.count)
        }
        for ring in rings {
            for coordinate in ring {
                data.append(littleEndian: coordinate.longitude)
                data.append(littleEndian: coordinate.latitude)
            }
        }
    }

    /// Rewinds a ring to the requested direction.
    ///
    /// Uses the shoelace formula: a positive signed area means the ring is
    /// counter-clockwise in x/y terms.
    static func wound(_ ring: [CLLocationCoordinate2D],
                      clockwise: Bool) -> [CLLocationCoordinate2D] {
        guard ring.count >= 3 else { return ring }
        var area = 0.0
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            area += (b.longitude - a.longitude) * (b.latitude + a.latitude)
        }
        // `area > 0` here is clockwise, because the sum above is the negated
        // shoelace: convenient, and the reason this is a named function with
        // a test rather than an inline expression nobody can check.
        let isClockwise = area > 0
        return isClockwise == clockwise ? ring : ring.reversed()
    }

    // MARK: - Files

    private struct BoundingBox {
        var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0
    }

    private static func boundingBox(of coordinates: [CLLocationCoordinate2D]) -> BoundingBox {
        guard !coordinates.isEmpty else { return BoundingBox() }
        return BoundingBox(
            minX: coordinates.map(\.longitude).min() ?? 0,
            minY: coordinates.map(\.latitude).min() ?? 0,
            maxX: coordinates.map(\.longitude).max() ?? 0,
            maxY: coordinates.map(\.latitude).max() ?? 0)
    }

    private static func bounds(of layer: MapOverlayLayer) -> BoundingBox {
        boundingBox(of: layer.coordinates)
    }

    /// The 100-byte header both `.shp` and `.shx` share.
    ///
    /// `fileLength` is in **16-bit words**, big-endian — the same unit trap as
    /// the record headers, in a different place.
    private static func header(fileLengthBytes: Int, shapeType: Int32,
                               bounds: BoundingBox) -> Data {
        var data = Data()
        data.append(bigEndian: fileMagic)
        for _ in 0..<5 { data.append(bigEndian: Int32(0)) }
        data.append(bigEndian: Int32(fileLengthBytes / 2))
        data.append(littleEndian: version)
        data.append(littleEndian: shapeType)
        data.append(littleEndian: bounds.minX)
        data.append(littleEndian: bounds.minY)
        data.append(littleEndian: bounds.maxX)
        data.append(littleEndian: bounds.maxY)
        // Z and M ranges: unused, but the header is fixed-width.
        for _ in 0..<4 { data.append(littleEndian: Double(0)) }
        return data
    }

    private static func shp(records: [Data], shapeType: Int32, bounds: BoundingBox) -> Data {
        var body = Data()
        for (index, content) in records.enumerated() {
            body.append(bigEndian: Int32(index + 1))       // record number, 1-based
            body.append(bigEndian: Int32(content.count / 2))
            body.append(content)
        }
        return header(fileLengthBytes: 100 + body.count, shapeType: shapeType, bounds: bounds) + body
    }

    /// The index: for each record, its offset and content length, both in
    /// 16-bit words, both big-endian.
    private static func shx(records: [Data], shapeType: Int32, bounds: BoundingBox) -> Data {
        var body = Data()
        var offsetBytes = 100
        for content in records {
            body.append(bigEndian: Int32(offsetBytes / 2))
            body.append(bigEndian: Int32(content.count / 2))
            offsetBytes += 8 + content.count
        }
        return header(fileLengthBytes: 100 + body.count, shapeType: shapeType, bounds: bounds) + body
    }
}

// MARK: - dBASE III attributes

/// Writes the `.dbf` that carries a shapefile's attributes.
///
/// dBASE III is ancient and rigid: fixed-width ASCII fields, names capped at
/// ten characters, one record per shape in the same order. Nothing about it is
/// negotiable, because the readers on the other end are equally old.
nonisolated enum DBFWriter {

    /// Field width for the name and every attribute. Generous enough for a
    /// zone label, short enough that a hundred features stay small.
    static let fieldWidth = 64
    static let maximumFieldNameLength = 10

    static func data(for features: [MapOverlayFeature]) -> Data {
        // Field order must be stable: the header declares it once and every
        // record repeats it positionally.
        var names = ["NAME"]
        var seen: Set<String> = ["NAME"]
        for feature in features {
            for key in feature.attributes.keys.sorted() {
                let field = fieldName(key)
                if seen.insert(field).inserted { names.append(field) }
            }
        }
        // dBASE III allows at most 128 fields; beyond that, drop the excess
        // rather than writing a header no reader will accept.
        names = Array(names.prefix(128))

        let headerLength = 32 + names.count * 32 + 1
        let recordLength = 1 + names.count * fieldWidth

        var data = Data()
        data.append(0x03)                         // dBASE III, no memo
        let now = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day], from: Date())
        data.append(UInt8((now.year ?? 2000) % 100))
        data.append(UInt8(now.month ?? 1))
        data.append(UInt8(now.day ?? 1))
        data.append(littleEndian: UInt32(features.count))
        data.append(littleEndian: UInt16(headerLength))
        data.append(littleEndian: UInt16(recordLength))
        data.append(Data(repeating: 0, count: 20))   // reserved

        for name in names {
            var field = Data(name.utf8.prefix(maximumFieldNameLength))
            field.append(Data(repeating: 0, count: 11 - field.count))
            data.append(field)
            data.append(UInt8(ascii: "C"))            // character field
            data.append(Data(repeating: 0, count: 4)) // reserved
            data.append(UInt8(fieldWidth))
            data.append(0)                            // decimal count
            data.append(Data(repeating: 0, count: 14))
        }
        data.append(0x0D)                             // end of field descriptors

        for feature in features {
            data.append(UInt8(ascii: " "))            // not deleted
            for name in names {
                let value = name == "NAME"
                    ? feature.name
                    : feature.attributes.first { fieldName($0.key) == name }?.value ?? ""
                data.append(padded(value))
            }
        }
        data.append(0x1A)                             // end of file
        return data
    }

    /// dBASE field names are upper-case **ASCII**, at most ten characters.
    ///
    /// ASCII specifically: a dBASE III header has no encoding field, so a
    /// reader interprets the bytes in whatever code page it assumes. A field
    /// called `ÉVACUATION` is a different name to every reader that opens it,
    /// and some reject the header outright.
    static func fieldName(_ key: String) -> String {
        let cleaned = key.uppercased().map { character -> Character in
            let isPlainASCII = character.isASCII && (character.isLetter || character.isNumber)
            return isPlainASCII ? character : "_"
        }
        return String(String(cleaned).prefix(maximumFieldNameLength))
    }

    /// Fixed-width, space-padded, ASCII.
    ///
    /// Non-ASCII is transliterated rather than dropped: an operator's note
    /// with an accent in it should still be readable on the other end, and a
    /// dBASE III reader given UTF-8 shows mojibake.
    static func padded(_ value: String) -> Data {
        let ascii = value.folding(options: .diacriticInsensitive, locale: .current)
            .unicodeScalars.map { $0.isASCII ? Character($0) : "?" }
        var data = Data(String(ascii).utf8.prefix(fieldWidth))
        data.append(Data(repeating: UInt8(ascii: " "), count: fieldWidth - data.count))
        return data
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func append(bigEndian value: Int32) {
        var raw = value.bigEndian
        append(Data(bytes: &raw, count: 4))
    }

    mutating func append(littleEndian value: Int32) {
        var raw = value.littleEndian
        append(Data(bytes: &raw, count: 4))
    }

    mutating func append(littleEndian value: UInt32) {
        var raw = value.littleEndian
        append(Data(bytes: &raw, count: 4))
    }

    mutating func append(littleEndian value: UInt16) {
        var raw = value.littleEndian
        append(Data(bytes: &raw, count: 2))
    }

    mutating func append(littleEndian value: Double) {
        var raw = value.bitPattern.littleEndian
        append(Data(bytes: &raw, count: 8))
    }
}
