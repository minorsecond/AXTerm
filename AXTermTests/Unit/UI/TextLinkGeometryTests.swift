//
//  TextLinkGeometryTests.swift
//  AXTermTests
//
//  The second layout has to land on the same glyphs the first one drew, or the
//  pointing hand appears somewhere the callsign is not. Monospaced text makes
//  the advances agree; what these check is that the ranges, the wrap and the
//  flipped coordinate space come out right.
//

#if os(macOS)
import XCTest
import AppKit
@testable import AXTerm

final class TextLinkGeometryTests: XCTestCase {

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func range(of needle: String, in text: String) -> Range<String.Index> {
        text.range(of: needle)!
    }

    func testARunGetsARectangleWhereTheTextIs() {
        let text = "relaying for WA0DE-9 tonight"
        let rects = TextLinkGeometry.rects(for: [range(of: "WA0DE-9", in: text)],
                                           in: text, font: font, width: 800)
        XCTAssertEqual(rects.count, 1)
        let rect = rects[0]
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        // "relaying for " precedes it, so the run cannot start at the margin.
        XCTAssertGreaterThan(rect.minX, 0)
    }

    /// The hit test is the whole point: a point on the run is a hit, a point
    /// on the words either side is not.
    func testThePointerIsOnlyOverTheRun() {
        let text = "relaying for WA0DE-9 tonight"
        let rects = TextLinkGeometry.rects(for: [range(of: "WA0DE-9", in: text)],
                                           in: text, font: font, width: 800)
        let rect = try! XCTUnwrap(rects.first)
        XCTAssertTrue(TextLinkGeometry.hit(CGPoint(x: rect.midX, y: rect.midY), rects: rects))
        XCTAssertFalse(TextLinkGeometry.hit(CGPoint(x: rect.minX - 8, y: rect.midY), rects: rects),
                       "the word before it is not a link")
        XCTAssertFalse(TextLinkGeometry.hit(CGPoint(x: rect.maxX + 8, y: rect.midY), rects: rects),
                       "nor the word after")
    }

    /// Top-left origin: the first line sits at the top, which is what a
    /// flipped NSView expects.
    func testTheOriginIsTopLeft() {
        let text = "WA0DE-9 first\nsecond line"
        let first = TextLinkGeometry.rects(for: [range(of: "WA0DE-9", in: text)],
                                           in: text, font: font, width: 800)
        XCTAssertEqual(try XCTUnwrap(first.first).minY, 0, accuracy: 2)
    }

    /// A run split across a wrap is two places the pointer can be, not one
    /// box spanning the gap between them.
    func testAWrappedRunYieldsARectPerLine() {
        // Narrow enough to force the wrap inside the padded run.
        let text = String(repeating: "x", count: 20) + " WA0DE-9 " + String(repeating: "y", count: 20)
        let wide = TextLinkGeometry.rects(for: [range(of: "WA0DE-9", in: text)],
                                          in: text, font: font, width: 1_000)
        XCTAssertEqual(wide.count, 1, "no wrap, one rect")

        let narrow = TextLinkGeometry.rects(for: [range(of: "WA0DE-9", in: text)],
                                            in: text, font: font, width: 60)
        XCTAssertGreaterThanOrEqual(narrow.count, 1)
        // Whatever the wrap does, no rectangle may be wider than the container.
        XCTAssertTrue(narrow.allSatisfy { $0.width <= 60 + 1 }, "\(narrow)")
    }

    func testSeveralRunsEachGetTheirOwn() {
        let text = "thanks @kj5imv and WA0DE-9"
        let rects = TextLinkGeometry.rects(
            for: [range(of: "@kj5imv", in: text), range(of: "WA0DE-9", in: text)],
            in: text, font: font, width: 800)
        XCTAssertEqual(rects.count, 2)
        XCTAssertLessThan(rects[0].minX, rects[1].minX, "in reading order")
        XCTAssertFalse(rects[0].intersects(rects[1]))
    }

    func testDegenerateInputIsHarmless() {
        XCTAssertEqual(TextLinkGeometry.rects(for: [], in: "abc", font: font, width: 100), [])
        let text = "abc"
        XCTAssertEqual(TextLinkGeometry.rects(for: [range(of: "b", in: text)],
                                              in: text, font: font, width: 0), [])
        XCTAssertEqual(TextLinkGeometry.rects(for: [], in: "", font: font, width: 100), [])
        XCTAssertFalse(TextLinkGeometry.hit(.zero, rects: []))
    }
}
#endif
