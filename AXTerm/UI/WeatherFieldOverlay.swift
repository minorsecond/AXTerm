import Foundation
import MapKit
import CoreGraphics

/// The inferred temperature field, drawn under the stations.
///
/// Follows `ElevationOverlay`'s shape for the same reason: MapKit asks for a
/// renderer on every pan and expects it back promptly, so the raster is built
/// once on a background queue and the first call returns nil rather than
/// blocking the map.
///
/// The image is deliberately coarse and heavily blurred by its own
/// interpolation. Sharp isotherms drawn from six stations would be a lie with
/// good edges; a soft wash says "roughly this, around here", which is what the
/// data supports.
nonisolated final class WeatherFieldOverlay: NSObject, MKOverlay, @unchecked Sendable {

    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    /// Identity for the overlay diff — changes whenever any station's reading
    /// changes, so a new reading redraws and nothing else does.
    let id: String

    /// Cells across the raster. Small on purpose: the field has no detail
    /// finer than the station spacing, and the renderer scales it up smoothly.
    private static let resolution = 96

    private let lock = NSLock()
    private var state: RenderState = .idle
    private let makeImage: @Sendable () -> CGImage?

    private enum RenderState {
        case idle
        case rendering
        case ready(CGImage?)
    }

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    init(id: String, bounds: MapBounds, makeImage: @escaping @Sendable () -> CGImage?) {
        self.id = id
        self.makeImage = makeImage
        let northWest = MKMapPoint(CLLocationCoordinate2D(
            latitude: bounds.north, longitude: bounds.west))
        let southEast = MKMapPoint(CLLocationCoordinate2D(
            latitude: bounds.south, longitude: bounds.east))
        boundingMapRect = MKMapRect(
            x: northWest.x, y: northWest.y,
            width: southEast.x - northWest.x,
            height: southEast.y - northWest.y)
        coordinate = CLLocationCoordinate2D(
            latitude: (bounds.north + bounds.south) / 2,
            longitude: (bounds.east + bounds.west) / 2)
        super.init()
    }

    /// The rendered wash, or nil while it is still being built.
    func image(onReady: @escaping @Sendable () -> Void) -> CGImage? {
        lock.lock()
        if let cached = Self.cache.object(forKey: id as NSString) {
            state = .ready(cached)
            lock.unlock()
            return cached
        }
        switch state {
        case .ready(let image):
            lock.unlock()
            return image
        case .rendering:
            lock.unlock()
            return nil
        case .idle:
            state = .rendering
            lock.unlock()
            let key = id
            let build = makeImage
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = build()
                if let image {
                    Self.cache.setObject(image, forKey: key as NSString,
                                         cost: image.height * image.bytesPerRow)
                }
                self?.lock.lock()
                self?.state = .ready(image)
                self?.lock.unlock()
                onReady()
            }
            return nil
        }
    }

    /// The area a field can speak for: every station's coverage radius,
    /// unioned, so the raster covers exactly what will be drawn and no more.
    struct MapBounds: Equatable, Sendable {
        var north: Double, south: Double, east: Double, west: Double
    }

    static func bounds(for field: APRSWeatherField) -> MapBounds? {
        guard !field.observations.isEmpty else { return nil }
        let latitudes = field.observations.map(\.position.latitude)
        let longitudes = field.observations.map(\.position.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return nil }
        // Pad by the coverage radius, in degrees at this latitude.
        let padLat = APRSWeatherField.coverageRadiusKm / 111.0
        let midLat = (minLat + maxLat) / 2
        let padLon = padLat / max(0.2, cos(midLat * .pi / 180))
        return MapBounds(north: min(90, maxLat + padLat),
                         south: max(-90, minLat - padLat),
                         east: min(180, maxLon + padLon),
                         west: max(-180, minLon - padLon))
    }

    /// Builds the overlay for a field, or nil when there is nothing to draw.
    ///
    /// `elevation` is called on a background queue for every cell, so it must
    /// be safe to call off the main thread and cheap enough to run a few
    /// thousand times.
    static func overlay(for field: APRSWeatherField,
                        elevation: (@Sendable (GreatCircle.Point) -> Double?)? = nil,
                        isDark: Bool) -> WeatherFieldOverlay? {
        guard let bounds = bounds(for: field), let range = field.temperatureRange else { return nil }

        // The identity has to change whenever the drawing would: a new reading
        // from any station, a different set of stations, or a theme flip.
        let signature = field.observations
            .sorted { $0.callsign < $1.callsign }
            .map { "\($0.callsign):\(Int($0.value.rounded())):\(Int(($0.elevationMetres ?? -1).rounded()))" }
            .joined(separator: ",")
        let id = "wxfield|\(field.parameter.rawValue)|\(isDark ? "dark" : "light")|\(String(format: "%.0f-%.0f", range.lowerBound, range.upperBound))|\(signature)"

        let resolution = Self.resolution
        return WeatherFieldOverlay(id: id, bounds: bounds) {
            render(field: field, bounds: bounds, range: range,
                   resolution: resolution, elevation: elevation)
        }
    }

    /// The raster itself: one sample per cell, alpha carrying the confidence
    /// so the wash fades out where the stations stop supporting it.
    private static func render(field: APRSWeatherField,
                               bounds: MapBounds,
                               range: ClosedRange<Double>,
                               resolution: Int,
                               elevation: (@Sendable (GreatCircle.Point) -> Double?)?) -> CGImage? {
        let width = resolution
        let height = resolution
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let span = max(range.upperBound - range.lowerBound, 0.001)

        for row in 0..<height {
            let latitude = bounds.north - (bounds.north - bounds.south)
                * (Double(row) + 0.5) / Double(height)
            for column in 0..<width {
                let longitude = bounds.west + (bounds.east - bounds.west)
                    * (Double(column) + 0.5) / Double(width)
                let point = GreatCircle.Point(latitude: latitude, longitude: longitude)
                let confidence = field.confidence(at: point)
                guard confidence > 0,
                      let value = field.temperature(at: point,
                                                    elevationMetres: elevation?(point))
                else { continue }

                let unit = min(1, max(0, (value - range.lowerBound) / span))
                let (red, green, blue) = colour(unit)
                let index = (row * width + column) * 4
                // Premultiplied alpha: the wash sits under the markers and
                // must never be strong enough to compete with them. At 0.42
                // it read as a sepia filter over the whole page — the
                // basemap's roads and water disappeared and the inference
                // looked more authoritative than the stations it came from.
                let alpha = confidence * 0.22
                pixels[index] = UInt8(red * alpha * 255)
                pixels[index + 1] = UInt8(green * alpha * 255)
                pixels[index + 2] = UInt8(blue * alpha * 255)
                pixels[index + 3] = UInt8(alpha * 255)
            }
        }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Cold to warm, the way a weather map is normally coloured: blue through
    /// a neutral middle to red. Kept muted — this is a background wash under
    /// the station markers, not the subject of the page.
    static func colour(_ unit: Double) -> (Double, Double, Double) {
        let stops: [(Double, Double, Double)] = [
            (0.26, 0.42, 0.78),   // cold blue
            (0.36, 0.68, 0.80),   // cool cyan
            (0.58, 0.76, 0.56),   // mild green
            (0.90, 0.78, 0.40),   // warm amber
            (0.85, 0.42, 0.30),   // hot red
        ]
        let scaled = min(0.999, max(0, unit)) * Double(stops.count - 1)
        let index = Int(scaled)
        let fraction = scaled - Double(index)
        let low = stops[index]
        let high = stops[min(index + 1, stops.count - 1)]
        return (low.0 + (high.0 - low.0) * fraction,
                low.1 + (high.1 - low.1) * fraction,
                low.2 + (high.2 - low.2) * fraction)
    }
}

/// Draws the wash, scaled smoothly up from its coarse raster.
nonisolated final class WeatherFieldOverlayRenderer: MKOverlayRenderer {

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let field = overlay as? WeatherFieldOverlay else { return }
        let image = field.image { [weak self] in
            DispatchQueue.main.async { self?.setNeedsDisplay() }
        }
        guard let image else { return }

        let rect = self.rect(for: overlay.boundingMapRect)
        context.saveGState()
        context.setBlendMode(.normal)
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
        context.restoreGState()
    }
}
