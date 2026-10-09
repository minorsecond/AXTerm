import MapKit

/// A hazard polygon on the map, carrying its own style. A subclass rather
/// than a style table so the map can tell hazards from the operator's own
/// layers when it rebuilds those, and draw each without a lookup.
final class HazardPolygon: MKPolygon {
    var hazardID = ""
    /// RGB as six hex digits, from `NWSHazardStyle`.
    var hex = ""
    var fillAlpha = 0.0
    var strokeAlpha = 0.0
    var dashed = false
}

/// Hazards from `HazardDrawing` as MapKit polygons.
enum HazardOverlayBuilder {

    /// One map polygon per polygon of the item, its holes as interior
    /// polygons, in the item's style.
    static func polygons(for item: HazardDrawing.Item) -> [HazardPolygon] {
        item.polygons.compactMap { rings in
            guard let outer = rings.first, outer.count >= 3 else { return nil }
            let holes = rings.dropFirst().filter { $0.count >= 3 }.map { ring -> MKPolygon in
                let coordinates = ring.map(coordinate)
                return MKPolygon(coordinates: coordinates, count: coordinates.count)
            }
            let coordinates = outer.map(coordinate)
            let polygon = HazardPolygon(coordinates: coordinates, count: coordinates.count,
                                        interiorPolygons: holes.isEmpty ? nil : holes)
            polygon.hazardID = item.id
            polygon.hex = item.hex
            polygon.fillAlpha = item.fillAlpha
            polygon.strokeAlpha = item.strokeAlpha
            polygon.dashed = item.dashed
            return polygon
        }
    }

    /// "FF1493" as components from 0 to 1; nil for anything else.
    static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    private static func coordinate(_ point: GreatCircle.Point) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
}
