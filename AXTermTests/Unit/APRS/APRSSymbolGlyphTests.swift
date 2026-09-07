import XCTest
@testable import AXTerm

final class APRSSymbolGlyphTests: XCTestCase {

    func testCommonSymbolsMapToGlyphs() {
        XCTAssertEqual(APRSSymbolGlyph.systemImage(table: "/", code: ">"), "car.fill")
        XCTAssertEqual(APRSSymbolGlyph.systemImage(table: "/", code: "#"), "antenna.radiowaves.left.and.right")
        XCTAssertEqual(APRSSymbolGlyph.systemImage(table: "/", code: "-"), "house.fill")
        XCTAssertEqual(APRSSymbolGlyph.systemImage(table: "/", code: "_"), "cloud.sun.fill")
        XCTAssertTrue(APRSSymbolGlyph.isKnown(table: "/", code: ">"))
    }

    func testUnknownSymbolFallsBackButStaysLabeled() {
        XCTAssertEqual(APRSSymbolGlyph.systemImage(table: "/", code: "Q"), "mappin.circle.fill")
        XCTAssertFalse(APRSSymbolGlyph.isKnown(table: "/", code: "Q"))
        // The catalog still names it, so the tooltip is never blank.
        XCTAssertFalse(APRSSymbolGlyph.label(table: "/", code: ">").isEmpty)
    }
}
