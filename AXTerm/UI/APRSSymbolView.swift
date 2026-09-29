import SwiftUI

/// One APRS symbol, drawn the same way everywhere.
///
/// Goes through `APRSGlyphRasterizer`, so every surface gets the same three
/// things: AXTerm's own artwork where it exists, SF Symbols where it does
/// not, and the overlay character on top. Before this the map markers had all
/// three and every other view had none — the sidebar drew a bare SF Symbol,
/// so the same station looked like two different things depending on where
/// you were looking at it.
///
/// The rasterised glyph is white with an alpha mask, and template rendering
/// uses only that alpha, so `foregroundStyle` still decides the colour.
struct APRSSymbolView: View {
    let table: Character
    let code: Character
    /// Edge length in points.
    var size: CGFloat

    var body: some View {
        if let glyph = APRSGlyphRasterizer.image(table: table, code: code, pointSize: size) {
            Image(decorative: glyph, scale: APRSGlyphRasterizer.renderScale)
                .renderingMode(.template)
                .resizable()
                .frame(width: size, height: size)
        } else {
            // The rasteriser only fails if even SF Symbols has nothing, which
            // means a code outside the printable range.
            Image(systemName: APRSSymbolGlyph.fallback)
                .font(.system(size: size * 0.9, weight: .bold))
        }
    }
}
