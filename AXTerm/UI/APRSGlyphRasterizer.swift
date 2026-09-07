import MapKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Renders an SF Symbol to a white template `CGImage`, cached, so the map's
/// station dots can carry an APRS glyph without re-rasterising on every
/// reconfigure. The dot's CAShapeLayers are jitter-tuned and must not be
/// disturbed; a glyph is a separate `CALayer` whose `contents` is one of
/// these images, tinted white so it reads over any recency colour.
nonisolated enum APRSGlyphRasterizer {

    // Keyed by "name@points", so the same glyph at the same size is drawn
    // once for the life of the app. APRS symbols are a small fixed set.
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]
    nonisolated(unsafe) private static let lock = NSLock()

    /// A white glyph for the symbol, sized to fit inside a dot of `diameter`.
    static func image(systemName: String, diameter: CGFloat) -> CGImage? {
        // The glyph sits inside the dot with a little breathing room.
        let points = max(6, (diameter * 0.62).rounded())
        let key = "\(systemName)@\(points)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let image = rasterize(systemName: systemName, points: points) else { return nil }
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }

    #if os(iOS)
    private static func rasterize(systemName: String, points: CGFloat) -> CGImage? {
        let config = UIImage.SymbolConfiguration(pointSize: points, weight: .bold)
        guard let symbol = UIImage(systemName: systemName, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        return symbol.cgImage
    }
    #else
    private static func rasterize(systemName: String, points: CGFloat) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: points, weight: .bold)
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = base.size
        guard size.width > 0, size.height > 0 else { return nil }
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        NSColor.white.set()
        let rect = NSRect(origin: .zero, size: size)
        base.draw(in: rect)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        var proposed = NSRect(origin: .zero, size: size)
        return tinted.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }
    #endif
}
