#if os(macOS)
import AppKit

/// Measures message text exactly the way the row's text view lays it out.
///
/// TextKit 1 with no line fragment padding and no inset, the same setup as
/// `ConsoleMessageTextView`, so a height measured here is the height the view
/// needs, to the point.
@MainActor
final class ConsoleTextMeasurer {
    static let shared = ConsoleTextMeasurer()

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    private var fixedAdvance: [UInt16: Bool] = [:]
    private var lineHeights: [String: CGFloat] = [:]

    /// The text on one line. For text in one fixed-pitch font whose every
    /// character has the font's own advance, that is the character count
    /// times the advance, with no layout at all: the console measures every
    /// row it holds, and most are like this. Anything else is laid out.
    func idealSize(of text: NSAttributedString) -> NSSize {
        if let size = fixedPitchSize(of: text) { return size }
        return size(of: text, width: nil)
    }

    private func fixedPitchSize(of text: NSAttributedString) -> NSSize? {
        guard text.length > 0,
              let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font.isFixedPitch
        else { return nil }
        var fonts = 0
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { _, _, _ in fonts += 1 }
        guard fonts == 1 else { return nil }
        let ctFont = font as CTFont
        var spaceGlyph: CGGlyph = 0
        var space: UniChar = 0x20
        guard CTFontGetGlyphsForCharacters(ctFont, &space, &spaceGlyph, 1) else { return nil }
        let advance = CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &spaceGlyph, nil, 1)
        for unit in text.string.utf16 where !(0x20...0x7E).contains(unit) {
            if let known = fixedAdvance[unit] {
                if !known { return nil }
                continue
            }
            var character = unit
            var glyph: CGGlyph = 0
            var ok = false
            if !UTF16.isLeadSurrogate(unit), !UTF16.isTrailSurrogate(unit),
               CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1), glyph != 0 {
                ok = CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, nil, 1) == advance
            }
            fixedAdvance[unit] = ok
            if !ok { return nil }
        }
        return NSSize(width: ceil(CGFloat(text.length) * advance), height: lineHeight(for: font))
    }

    /// One line's height in a font, as TextKit lays it out.
    func lineHeight(for font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)"
        if let height = lineHeights[key] { return height }
        let height = size(of: NSAttributedString(string: "X", attributes: [.font: font]), width: nil).height
        lineHeights[key] = height
        return height
    }

    /// The size of the text laid out within `width`; unbounded when nil.
    func size(of text: NSAttributedString, width: CGFloat?) -> NSSize {
        // An empty message is one line of the console font tall. An empty
        // string has no attributes to ask for its font: asking for the font
        // at index 0 threw, and A crashed on every launch (2026-10-10).
        guard text.length > 0 else {
            return NSSize(width: 0, height: lineHeight(for: ConsoleRowModel.messageFont))
        }
        container.size = NSSize(width: width ?? CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }
}

/// A row's measurements that do not depend on its width, taken once.
struct ConsoleRowMeasurements {
    var timestamp: NSSize
    var header: [NSSize]
    var symbol: NSSize?
    /// The message on one line.
    var messageIdeal: NSSize
    var expansionLineHeight: CGFloat

    @MainActor
    init(model: ConsoleRowModel, measurer: ConsoleTextMeasurer = .shared) {
        let timestampText = model.timestamp as NSString
        let ts = timestampText.size(withAttributes: [.font: model.timestampFont])
        timestamp = NSSize(width: ceil(ts.width),
                           height: ceil(model.timestampFont.ascender - model.timestampFont.descender + model.timestampFont.leading))
        header = model.header.map { $0.size() }
        symbol = model.symbol == nil ? nil : NSSize(width: ceil(model.symbolPointSize + 4), height: ceil(model.symbolPointSize + 4))
        messageIdeal = measurer.idealSize(of: model.message)
        let expansionFont = NSFont.monospacedSystemFont(ofSize: model.timestampFont.pointSize, weight: .regular)
        expansionLineHeight = ceil(expansionFont.ascender - expansionFont.descender + expansionFont.leading) + 2
    }
}

/// Where everything in a row goes at one width.
struct ConsoleRowGeometry: Equatable {
    var height: CGFloat
    var timestampRect: CGRect
    var headerRects: [CGRect]
    var symbolRect: CGRect?
    var messageRect: CGRect
    var expansionTop: CGFloat
    var expansionLineHeight: CGFloat

    static let padding: CGFloat = ConsoleTheme.rowPadding
    static let spacing: CGFloat = 6
    static let indicatorWidth: CGFloat = ConsoleTheme.indicatorBarWidth
    /// How much room a message must have beyond its width to be taken as one
    /// line without laying it out: two characters of the console font.
    static let fitMargin: CGFloat = 15
    /// Left edge of the time, after the padding and the indicator bar.
    static var contentLeft: CGFloat { padding + indicatorWidth + spacing }

    /// Lays a row out in `width`. `messageHeight(width)` measures the message
    /// wrapped in a given width; it is asked only when the message does not
    /// fit on one line, which on most rows it does.
    static func layout(width: CGFloat, measurements m: ConsoleRowMeasurements, wrapsBelow: Bool,
                       expansionLines: Int,
                       messageHeight: (CGFloat) -> CGFloat) -> ConsoleRowGeometry {
        let left = contentLeft
        let right = width - padding
        let top = padding

        let timestampRect = CGRect(x: left, y: top, width: m.timestamp.width, height: m.timestamp.height)
        var x = timestampRect.maxX + spacing
        var headerRects: [CGRect] = []
        for size in m.header {
            headerRects.append(CGRect(x: x, y: top, width: size.width, height: size.height))
            x += size.width + spacing
        }
        let headerBottom = max(timestampRect.maxY, headerRects.map(\.maxY).max() ?? top)
        let headerEnd = headerRects.last.map { $0.maxX + spacing } ?? (timestampRect.maxX + spacing)

        let symbolWidth = m.symbol.map { $0.width + spacing } ?? 0
        let blockIdeal = symbolWidth + m.messageIdeal.width

        // Where the message block starts and how wide it may be.
        var blockLeft = headerEnd
        var blockTop = top
        if wrapsBelow {
            let leading = headerEnd - spacing - left
            let available = right - left
            if ConsoleRowArrangement.choose(leadingWidth: leading, messageWidth: blockIdeal,
                                            available: available, spacing: spacing) == .messageBelow {
                blockLeft = timestampRect.maxX + spacing
                blockTop = headerBottom + 2
            }
        }
        let textLeft = blockLeft + symbolWidth
        let textWidth = max(right - textLeft, 40)
        // A message that fits with room to spare is one line; near the edge,
        // or past it, it is laid out to be sure.
        let textHeight = m.messageIdeal.width + fitMargin <= textWidth ? m.messageIdeal.height : messageHeight(textWidth)

        let symbolRect = m.symbol.map { CGRect(x: blockLeft, y: blockTop - 1, width: $0.width, height: $0.height) }
        let messageRect = CGRect(x: textLeft, y: blockTop, width: textWidth, height: textHeight)
        let contentBottom = max(headerBottom, messageRect.maxY, symbolRect?.maxY ?? 0)
        let expansionTop = contentBottom + (expansionLines > 0 ? 2 : 0)
        let height = expansionTop + CGFloat(expansionLines) * m.expansionLineHeight + padding

        return ConsoleRowGeometry(height: ceil(height), timestampRect: timestampRect, headerRects: headerRects,
                                  symbolRect: symbolRect, messageRect: messageRect,
                                  expansionTop: expansionTop, expansionLineHeight: m.expansionLineHeight)
    }
}
#endif
