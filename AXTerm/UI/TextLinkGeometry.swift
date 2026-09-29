//
//  TextLinkGeometry.swift
//  AXTerm
//
//  Where the link runs of a wrapped string actually sit, so something can own
//  cursor rects over them.
//
//  SwiftUI's `Text` draws `AttributedString` links and makes them clickable,
//  but on macOS it installs no cursor rect for them — and with
//  `.textSelection(.enabled)` the whole view is one I-beam tracking area, so
//  the pointer never changes as it crosses a link. AppKit gives that away free
//  in `NSTextView`; SwiftUI does not, and the convention it breaks is the
//  obvious one: Mail, Notes and Messages all show the pointing hand over a
//  link inside selectable text.
//
//  Laying the string out a second time is the price of keeping `Text` — and
//  worth it, because the alternative is an `NSTextView` per row in a lazy
//  stack whose layout cost has already taken this app down once. The console
//  is monospaced, so the second layout agrees with the first about advances;
//  what it has to get right is where the lines break.
//

#if os(macOS)
import AppKit

nonisolated enum TextLinkGeometry {

    /// Rectangles covering `ranges`, in a flipped coordinate space with the
    /// origin at the top left — the space an `NSView` subclass uses when
    /// `isFlipped` is true, which is what draws these.
    ///
    /// A range that wraps yields more than one rectangle: half a callsign at
    /// the end of a line and half at the start of the next is two separate
    /// places the pointer can be, and one bounding box around both would claim
    /// the empty space between them.
    static func rects(for ranges: [Range<String.Index>],
                      in text: String,
                      font: NSFont,
                      width: CGFloat) -> [CGRect] {
        guard width > 0, !text.isEmpty, !ranges.isEmpty else { return [] }

        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        var rects: [CGRect] = []
        for range in ranges {
            guard let nsRange = NSRange(range, in: text) as NSRange? else { continue }
            let glyphRange = layout.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                           withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                rects.append(rect)
            }
        }
        return rects
    }

    /// Whether a point in that same space falls on a link.
    static func hit(_ point: CGPoint, rects: [CGRect]) -> Bool {
        rects.contains { $0.contains(point) }
    }
}
#endif
