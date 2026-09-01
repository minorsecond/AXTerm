import Foundation
import MapKit
import CoreGraphics

/// One stored elevation tile, drawn on the map.
///
/// A tile per overlay rather than one overlay for everything: MapKit only
/// asks for the renderers whose bounding rects are on screen, so panning away
/// from a tile stops it costing anything.
// `@unchecked Sendable`, earned by the lock: every mutable field is read
// and written under `lock`, which is what lets the tile be built on a
// background queue and handed back.
nonisolated final class ElevationOverlay: NSObject, MKOverlay, @unchecked Sendable {

    let tileLatitude: Int
    let tileLongitude: Int
    let style: TerrainShading.Style
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    /// Shading a 1024-square grid is a few million operations, and MapKit
    /// asks for a redraw on every pan. Rendered once, off the main thread,
    /// and kept in a process-wide cache so panning back, toggling styles, or
    /// rebuilding the overlay list is free.
    private let lock = NSLock()
    private var state: RenderState = .idle
    private let makeImage: @Sendable () -> CGImage?

    private enum RenderState {
        case idle
        case rendering
        case ready(CGImage?)
    }

    /// Shared across overlay instances, so rebuilding the list — which the
    /// view does whenever the stored tile count changes — does not throw away
    /// work already done.
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        // Roughly ten tiles at 1024 squared RGBA. Beyond that the operator is
        // looking at more terrain than fits on a screen anyway.
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

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

    /// The shaded image if it is ready.
    ///
    /// Never blocks. MapKit calls the renderer expecting it to return
    /// promptly; shading inside that call is what made the terrain take
    /// seconds to appear and froze panning while it did. The first call
    /// starts the work and returns nil, and `onReady` fires when the tile can
    /// be drawn.
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

            // The Swift String crosses, not the NSString: `NSString` is not
            // Sendable and this closure is.
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
// `@unchecked Sendable` because MapKit says so: it calls renderers from
// its own drawing queues, and an overlay renderer that refused to cross a
// thread could not be used at all.
nonisolated final class ElevationOverlayRenderer: MKOverlayRenderer, @unchecked Sendable {

    #if DEBUG
    /// Counts terrain repaints. A tile that never reports itself ready, or
    /// a renderer that invalidates itself, keeps MapKit redrawing — and a
    /// map redrawing continuously re-resolves its own label layer, which is
    /// the remaining candidate for movement nothing else accounts for.
    nonisolated(unsafe) private static var drawCount = 0
    nonisolated(unsafe) private static var pendingCount = 0
    nonisolated(unsafe) private static var drawWindow = Date.distantPast

    private static func noteDraw(ready: Bool) {
        drawCount += 1
        if !ready { pendingCount += 1 }
        let elapsed = Date().timeIntervalSince(drawWindow)
        guard elapsed >= 5 else { return }
        if drawWindow != .distantPast {
            print(String(format: "[MAPDIAG] terrain draws %d in %.1fs (%d still shading)",
                         drawCount, elapsed, pendingCount))
        }
        drawCount = 0
        pendingCount = 0
        drawWindow = Date()
    }
    #endif

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale,
                       in context: CGContext) {
        guard let overlay = overlay as? ElevationOverlay else { return }
        // Nil means the shading is still running. Asking MapKit to redraw
        // this tile when it finishes is what keeps the map responsive: the
        // terrain fades in a tile at a time instead of the whole map
        // stalling until every tile is ready.
        let pending = overlay.image(onReady: { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.setNeedsDisplay(overlay.boundingMapRect)
            }
        })
        #if DEBUG
        Self.noteDraw(ready: pending != nil)
        #endif
        guard let image = pending else { return }

        let rect = rect(for: overlay.boundingMapRect)
        context.saveGState()
        // Blend rather than paint: MapKit has no overlay level beneath the
        // roads, so anything drawn opaquely here buries the street grid and
        // the network lines. Multiplying darkens what is already there.
        context.setBlendMode(overlay.style.blendMode)
        context.setAlpha(overlay.style.opacity)
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
