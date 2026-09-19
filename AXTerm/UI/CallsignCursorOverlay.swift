//
//  CallsignCursorOverlay.swift
//  AXTerm
//
//  The pointing hand over a callsign in a console line.
//
//  A transparent `NSView` laid over the text whose only job is to own cursor
//  rects. It is the AppKit mechanism for exactly this, which is why the
//  behaviour comes out right: the hand appears over the link, the I-beam
//  returns over the rest of the selectable line, and the system handles the
//  transitions rather than this pushing and popping cursors on hover events.
//
//  It never takes a click. `hitTest` returns nil, so mouse events pass
//  straight through to the `Text` beneath — selection still works over a link,
//  and the click continues to go through SwiftUI's own link handling. Cursor
//  rects are a property of the view's area, not of hit testing, so declining
//  events costs nothing here.
//
//  Applied only to lines that actually contain a callsign. Most do not, and a
//  view per row in a lazy stack is not something to hand out for free in a
//  console whose layout cost has already taken the app down once.
//

#if os(macOS)
import SwiftUI
import AppKit

struct CallsignCursorOverlay: NSViewRepresentable {
    let text: String
    let ranges: [Range<String.Index>]
    let font: NSFont

    func makeNSView(context: Context) -> CursorRectView {
        let view = CursorRectView()
        view.apply(text: text, ranges: ranges, font: font)
        return view
    }

    func updateNSView(_ view: CursorRectView, context: Context) {
        view.apply(text: text, ranges: ranges, font: font)
    }

    final class CursorRectView: NSView {
        private var text = ""
        private var ranges: [Range<String.Index>] = []
        private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        /// Top-left origin, to match how the text is laid out.
        override var isFlipped: Bool { true }

        /// Never takes the click: the text underneath owns selection and the
        /// link itself.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(text: String, ranges: [Range<String.Index>], font: NSFont) {
            guard text != self.text || ranges != self.ranges || font != self.font else { return }
            self.text = text
            self.ranges = ranges
            self.font = font
            window?.invalidateCursorRects(for: self)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            // The wrap changes with the width, so the rects do too.
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard !ranges.isEmpty else { return }
            for rect in TextLinkGeometry.rects(for: ranges, in: text, font: font, width: bounds.width) {
                addCursorRect(rect.intersection(bounds), cursor: .pointingHand)
            }
        }
    }
}
#endif
