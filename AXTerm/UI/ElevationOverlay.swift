import Foundation
import MapKit
import CoreGraphics

/// One stored elevation tile, drawn on the map.
///
/// A tile per overlay rather than one overlay for everything: MapKit only
/// asks for the renderers whose bounding rects are on screen, so panning away
/// from a tile stops it costing anything.
nonisolated final class ElevationOverlay: NSObject, MKOverlay {

    let tileLatitude: Int
    let tileLongitude: Int
    let style: TerrainShading.Style
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    /// Rendered lazily and kept, because shading a 1024-square grid is a few
    /// million floating-point operations and MapKit redraws on every pan.
    private let lock = NSLock()
    private var cachedImage: CGImage?
    private let makeImage: @Sendable () -> CGImage?

    init(tileLatitude: Int, tileLongitude: Int,
         style: TerrainShading.Style,
         makeImage: @escaping @Sendable () -> CGImage?) {
        self.tileLatitude = tileLatitude
        self.tileLongitude = tileLongitude
        self.style = style
        self.makeImage = makeImage

        let bounds = ElevationStore.bounds(lat: tileLatitude, lon: tileLongitude)
        let northWest = MKMapPoint(CLLocationCoordinate2D(
            latitude: bounds.north, longitude: bounds.west))
        let southEast = MKMapPoint(CLLocationCoordinate2D(
            latitude: bounds.south, longitude: bounds.east))
        boundingMapRect = MKMapRect(
            x: northWest.x, y: northWest.y,
            width: southEast.x - northWest.x,
            height: southEast.y - northWest.y)
        coordinate = CLLocationCoordinate2D(
            latitude: bounds.south + ElevationStore.tileDegrees / 2,
            longitude: bounds.west + ElevationStore.tileDegrees / 2)
        super.init()
    }

    /// Identity for the overlay-sync diff: re-adding an unchanged tile would
    /// throw away the rendered image with it.
    var id: String { "terrain|\(style.rawValue)|\(tileLatitude)/\(tileLongitude)" }

    func image() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedImage { return cachedImage }
        cachedImage = makeImage()
        return cachedImage
    }

    /// Builds the overlays for everything currently stored.
    static func overlays(from store: ElevationStore,
                         style: TerrainShading.Style) -> [ElevationOverlay] {
        let tiles = (try? store.storedTiles()) ?? []
        return tiles.map { tile in
            ElevationOverlay(tileLatitude: tile.lat, tileLongitude: tile.lon,
                             style: style) {
                guard let grid = try? store.tile(lat: tile.lat, lon: tile.lon) else {
                    return nil
                }
                let spacing = TerrainShading.metresPerSample(
                    tileLatitude: tile.lat, samples: grid.samples)
                let pixels = TerrainShading.rgba(
                    from: grid.grid, samples: grid.samples, style: style,
                    metresPerSampleX: spacing.x, metresPerSampleY: spacing.y)
                return Self.image(from: pixels, samples: grid.samples)
            }
        }
    }

    private static func image(from pixels: [UInt8], samples: Int) -> CGImage? {
        var bytes = pixels
        let provider = CFDataCreate(nil, &bytes, bytes.count).map(CGDataProvider.init(data:))
        guard let provider = provider ?? nil else { return nil }
        return CGImage(
            width: samples, height: samples,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: samples * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Draws a shaded elevation tile.
nonisolated final class ElevationOverlayRenderer: MKOverlayRenderer {

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale,
                       in context: CGContext) {
        guard let overlay = overlay as? ElevationOverlay,
              let image = overlay.image() else { return }

        let rect = rect(for: overlay.boundingMapRect)
        context.saveGState()
        // Core Graphics draws images bottom-up; the map's context runs
        // top-down. Flipping inside the tile's own rect keeps north at the
        // top — without it the terrain is mirrored, which looks entirely
        // plausible until you notice the mountains are east of Denver.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: rect.width, height: rect.height))
        context.restoreGState()
    }
}
