//
//  APRSSymbolGlyphTests.swift
//  AXTermTests
//

import XCTest
import AppKit
@testable import AXTerm

/// Every APRS symbol must draw as something, and the something must exist.
///
/// The bug this pins: the glyph map covered 39 codes out of 188 and ignored
/// the table, so `/M` — a Mac, which K0EPI-3 beacons — fell through to the
/// generic pin and was indistinguishable from a station carrying no symbol.
final class APRSSymbolGlyphTests: XCTestCase {

    /// `!`(0x21)…`~`(0x7E): the whole printable symbol range, per table.
    private let codes: [Character] = (0x21...0x7E).map { Character(UnicodeScalar($0)!) }

    // MARK: - Coverage

    func testTheCatalogHasBothTablesInFull() {
        XCTAssertEqual(APRSSymbolCatalog.primary.count, 94)
        XCTAssertEqual(APRSSymbolCatalog.alternate.count, 94)
        XCTAssertEqual(codes.count, 94, "the range under test is the range the tables use")
    }

    func testEverySymbolInBothTablesHasItsOwnGlyph() {
        for table: Character in ["/", "\\"] {
            for code in codes {
                XCTAssertTrue(
                    APRSSymbolGlyph.isKnown(table: table, code: code),
                    "\(table)\(code) falls back to the generic pin")
                XCTAssertNotEqual(
                    APRSSymbolGlyph.systemImage(table: table, code: code),
                    APRSSymbolGlyph.fallback,
                    "\(table)\(code) resolved to the fallback")
            }
        }
    }

    /// The compatibility guarantee. A wrong SF Symbol name is not a compile
    /// error and not a crash — it draws nothing at all, which looks exactly
    /// like the bug we just fixed. Resolve every one against the running
    /// system so a typo, or a symbol this macOS does not ship, fails here.
    func testEveryGlyphNameResolvesOnThisSystem() {
        var unresolved: [String] = []
        for table: Character in ["/", "\\"] {
            for code in codes {
                let name = APRSSymbolGlyph.systemImage(table: table, code: code)
                if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
                    unresolved.append("\(table)\(code) -> \(name)")
                }
            }
        }
        XCTAssertTrue(unresolved.isEmpty,
                      "SF Symbol names that do not exist: \(unresolved.joined(separator: ", "))")
    }

    // MARK: - The table is part of the symbol

    /// K0EPI-3, off the air 2026-09-10: Mic-E symbol table `/`, code `M`.
    func testAMacDrawsAnApple() {
        XCTAssertEqual(APRSSymbolGlyph.systemImage(table: "/", code: "M"), "applelogo")
        XCTAssertEqual(APRSSymbolCatalog.symbol(table: "/", code: "M")?.label, "Mac apple")
    }

    /// Same code, different table, different thing. Keying on the code alone
    /// made these identical.
    func testPairsThatShareACodeButNotAMeaningDrawDifferently() {
        // `_` is deliberately absent: `/_` is a weather station and `\\_` a
        // WX site that also digipeats. Those are the same kind of thing, and
        // forcing them apart would mean choosing a worse icon to satisfy a
        // test. Sharing a glyph is only wrong when the meanings differ.
        let pairs: [(Character, String, String)] = [
            ("M", "Mac apple", "MARS"),
            (";", "campground", "park"),
            ("K", "school", "Kenwood"),
            ("L", "PC user", "lighthouse"),
        ]
        for (code, primaryMeaning, alternateMeaning) in pairs {
            XCTAssertNotEqual(
                APRSSymbolGlyph.systemImage(table: "/", code: code),
                APRSSymbolGlyph.systemImage(table: "\\", code: code),
                "/\(code) is a \(primaryMeaning); \\\(code) is a \(alternateMeaning)")
        }
    }

    /// An overlay puts a character where the table goes; the glyph underneath
    /// is still the alternate table's, which is what the overlay decorates.
    func testAnOverlayCharacterUsesTheAlternateTable() {
        for overlay: Character in ["0", "9", "A", "Z"] {
            XCTAssertEqual(
                APRSSymbolGlyph.systemImage(table: overlay, code: "M"),
                APRSSymbolGlyph.systemImage(table: "\\", code: "M"),
                "overlay \(overlay) must read as the alternate table")
        }
    }

    /// Outside the printable range there is no symbol to draw.
    func testACodeOutsideTheRangeGetsTheGenericMarker() {
        XCTAssertEqual(APRSSymbolGlyph.systemImage(table: "/", code: " "),
                       APRSSymbolGlyph.fallback)
        XCTAssertFalse(APRSSymbolGlyph.isKnown(table: "/", code: " "))
    }
}
