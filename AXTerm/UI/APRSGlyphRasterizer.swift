import MapKit
import CoreText

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Renders an APRS symbol to a white template `CGImage`, cached, so the map's
/// station dots can carry a glyph without re-rasterising on every reconfigure.
/// The dot's CAShapeLayers are jitter-tuned and must not be disturbed; a glyph
/// is a separate `CALayer` whose `contents` is one of these images, tinted
/// white so it reads over any recency colour.
///
/// Keyed on the symbol rather than on an SF Symbol name, because the name was
/// never the identity: it hid both which artwork answers — ours where we have
/// drawn it, SF Symbols everywhere else — and the overlay character, which is
/// part of the symbol and used to be thrown away.
nonisolated enum APRSGlyphRasterizer {

    // Keyed by the whole symbol at a size, so the same glyph is drawn once for
    // the life of the app. APRS symbols are a small fixed set.
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]
    nonisolated(unsafe) private static let lock = NSLock()

    /// Pixels per point in the images this returns. A SwiftUI `Image` needs it
    /// to land at the right size.
    static let renderScale: CGFloat = 3

    /// A white glyph for the symbol, sized to fit inside a dot of `diameter`,
    /// with any overlay character drawn on top.
    static func image(table: Character, code: Character, diameter: CGFloat) -> CGImage? {
        // The glyph nearly fills the dot — it is the whole point of an APRS
        // marker, so it must read as a symbol, not a speck.
        image(table: table, code: code, pointSize: max(8, (diameter * 0.80).rounded()))
    }

    /// The same glyph at an explicit point size, for the places that lay out
    /// in points rather than around a dot.
    static func image(table: Character, code: Character, pointSize: CGFloat) -> CGImage? {
        let points = max(8, pointSize.rounded())
        let key = "\(table)\(code)@\(points)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let base = baseImage(table: table, code: code, points: points)
        let inscription = APRSSymbolArtwork.inscription(table: table, code: code)
        guard let image = compose(base: base, overlay: inscription, points: points)
        else { return nil }
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }

    /// Our own artwork when it exists, SF Symbols otherwise. The fallback is
    /// not a failure state: it covers all 188 codes, and three of them stay
    /// there on purpose.
    private static func baseImage(table: Character, code: Character, points: CGFloat) -> CGImage? {
        if let asset = APRSSymbolArtwork.assetName(table: table, code: code),
           let drawn = whiteImage(named: asset, points: points) {
            return drawn
        }
        return rasterize(systemName: APRSSymbolGlyph.systemImage(table: table, code: code),
                         points: points)
    }

    /// Draws the base glyph and, when the sender put a character in the table
    /// slot, that character over it.
    ///
    /// The character is punched out of the glyph first and then filled white,
    /// leaving a transparent halo. Without it a white letter on a white glyph
    /// is invisible — the overlay plates have a clear centre, but `\9` with a
    /// `G` on it is a solid gas pump.
    private static func compose(base: CGImage?, overlay: Character?, points: CGFloat) -> CGImage? {
        guard base != nil || overlay != nil else { return nil }
        let side = Int((points * renderScale).rounded())
        guard side > 0,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let box = CGFloat(side)
        if let base {
            let w = CGFloat(base.width), h = CGFloat(base.height)
            guard w > 0, h > 0 else { return nil }
            let fit = min(box / w, box / h)
            ctx.draw(base, in: CGRect(x: (box - w * fit) / 2, y: (box - h * fit) / 2,
                                      width: w * fit, height: h * fit))
        }
        if let overlay { draw(overlay: overlay, in: ctx, box: box) }
        return ctx.makeImage()
    }

    /// Overlay characters are read, not glanced at: `S` (a digi honouring the
    /// state alias) against `5`, `8` against `B`, `0` against `O`. At heavy
    /// weight the aperture of an `S` closes and it becomes a `5` — so this is
    /// bold and a little larger, which is more legible small, not less.
    private static func draw(overlay: Character, in ctx: CGContext, box: CGFloat) {
        #if os(iOS)
        let font = UIFont.systemFont(ofSize: box * 0.52, weight: .bold)
        #else
        let font = NSFont.systemFont(ofSize: box * 0.52, weight: .bold)
        #endif
        let white = CGColor(gray: 1, alpha: 1)
        func line(strokeWidth: CGFloat?) -> CTLine {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: white]
            if let strokeWidth {
                attrs[.strokeColor] = white
                // Negative means fill *and* stroke, which is what makes the
                // punched shape fatter than the letter rather than hollow.
                attrs[.strokeWidth] = -strokeWidth
            }
            return CTLineCreateWithAttributedString(
                NSAttributedString(string: String(overlay), attributes: attrs))
        }
        let measured = CTLineGetBoundsWithOptions(line(strokeWidth: nil), .useOpticalBounds)
        let x = (box - measured.width) / 2 - measured.minX
        let y = (box - measured.height) / 2 - measured.minY
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line(strokeWidth: 26), ctx)
        ctx.setBlendMode(.normal)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line(strokeWidth: nil), ctx)
        ctx.restoreGState()
    }

    #if os(iOS)
    private static func rasterize(systemName: String, points: CGFloat) -> CGImage? {
        let config = UIImage.SymbolConfiguration(pointSize: points, weight: .bold)
        guard let symbol = UIImage(systemName: systemName, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        return symbol.cgImage
    }

    private static func whiteImage(named name: String, points: CGFloat) -> CGImage? {
        guard let art = UIImage(named: name) else { return nil }
        let size = CGSize(width: points, height: points)
        let drawn = UIGraphicsImageRenderer(size: size).image { _ in
            art.withRenderingMode(.alwaysTemplate)
                .withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.cgImage
    }
    #else
    private static func rasterize(systemName: String, points: CGFloat) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: points, weight: .bold)
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        return whiten(base, to: base.size)
    }

    private static func whiteImage(named name: String, points: CGFloat) -> CGImage? {
        guard let art = NSImage(named: name) else { return nil }
        return whiten(art, to: CGSize(width: points, height: points))
    }

    /// Flattens to a solid white shape with the source's alpha, which is what
    /// makes one image usable over every recency colour.
    private static func whiten(_ image: NSImage, to size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        NSColor.white.set()
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        var proposed = NSRect(origin: .zero, size: size)
        return tinted.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }
    #endif
}
