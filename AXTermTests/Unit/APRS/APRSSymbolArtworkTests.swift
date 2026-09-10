//
//  APRSSymbolArtworkTests.swift
//  AXTermTests
//

import XCTest
#if os(macOS)
import AppKit
#endif
@testable import AXTerm

/// Our own artwork, and the overlay character that used to be discarded.
///
/// 24% of the position reports on a live channel put a character in the table
/// slot. `S#`, `1#`, `I#` and `D#` are four kinds of digipeater the operator
/// deliberately marked apart, and every one of them drew as the same picture.
final class APRSSymbolArtworkTests: XCTestCase {

    private let codes: [Character] = (0x21...0x7E).map { Character(UnicodeScalar($0)!) }

    // MARK: - Splitting a symbol into its parts

    func testThePrimaryTableCarriesNoOverlay() {
        let r = APRSSymbolArtwork.resolve(table: "/", code: "-")
        XCTAssertEqual(r, .init(table: "/", code: "-", overlay: nil))
    }

    func testThePlainAlternateTableCarriesNoOverlay() {
        let r = APRSSymbolArtwork.resolve(table: "\\", code: "#")
        XCTAssertEqual(r, .init(table: "\\", code: "#", overlay: nil))
    }

    /// Straight from the capture: the four digipeaters and the gas station.
    func testARealOverlayIsKeptAndReadsAsTheAlternateTable() {
        for (table, code) in [("S", "#"), ("1", "#"), ("I", "#"), ("D", "#"), ("G", "9")] {
            let r = APRSSymbolArtwork.resolve(table: Character(table), code: Character(code))
            XCTAssertEqual(r.table, "\\", "an overlay decorates the alternate table")
            XCTAssertEqual(r.code, Character(code))
            XCTAssertEqual(r.overlay, Character(table))
        }
    }

    /// The spec allows a digit or a capital letter and nothing else. A
    /// lower-case or punctuation character in that slot is a malformed frame,
    /// not an overlay, and inventing one would put a letter on the map that
    /// nobody transmitted.
    func testOnlyDigitsAndCapitalsCountAsAnOverlay() {
        for bad: Character in ["a", "z", ":", "~", "*", " "] {
            XCTAssertNil(APRSSymbolArtwork.resolve(table: bad, code: "#").overlay,
                         "\(bad) is not a legal overlay character")
        }
        for good: Character in ["0", "9", "A", "Z"] {
            XCTAssertEqual(APRSSymbolArtwork.resolve(table: good, code: "#").overlay, good)
        }
    }

    // MARK: - The artwork exists

    func testTheSymbolsSeenOnAirAreDrawn() {
        // Every base symbol observed in the 2026-09-10 capture.
        let onAir: [(Character, Character)] = [
            ("/", "-"), ("\\", "#"), ("/", "#"), ("/", ">"), ("/", "&"), ("/", "r"),
            ("/", "j"), ("/", "k"), ("\\", "9"), ("/", "f"), ("\\", ">"), ("\\", "I"),
            ("/", "J"), ("/", "R"), ("/", "["), ("/", "v"), ("\\", "w"), ("\\", "-"),
            ("/", ";"), ("\\", "b"), ("/", "5"), ("/", "`"), ("\\", "&"), ("/", "0"),
            ("\\", "k"), ("\\", "@"), ("\\", "A"), ("/", "b"), ("/", "M"), ("\\", "K"),
            ("/", "_"), ("\\", "_"), ("/", "s"), ("/", "u"),
        ]
        for (table, code) in onAir {
            XCTAssertNotNil(APRSSymbolArtwork.assetName(table: table, code: code),
                            "\(table)\(code) is on the air and has no drawing")
        }
    }

    /// An overlay must not change which artwork answers — it decorates the
    /// alternate table's symbol, it does not replace it.
    func testAnOverlayResolvesToTheSameArtworkAsThePlainAlternate() {
        for overlay: Character in ["S", "1", "I", "D"] {
            XCTAssertEqual(APRSSymbolArtwork.assetName(table: overlay, code: "#"),
                           APRSSymbolArtwork.assetName(table: "\\", code: "#"))
        }
    }

    /// A digipeater is a digipeater whichever table it came from. `/#` is
    /// "Digipeater" and `\#` is spec-named "Number (overlay)", but the New
    /// n-N Paradigm tells digis to beacon `#` with a letter on it, so in
    /// practice the second one IS the digi symbol. Drawing them as two
    /// different objects said they were two different things.
    func testBothTablesDrawTheSameDigipeater() {
        let primary = APRSSymbolArtwork.assetName(table: "/", code: "#")
        XCTAssertNotNil(primary)
        XCTAssertEqual(APRSSymbolArtwork.assetName(table: "\\", code: "#"), primary)
        XCTAssertEqual(APRSSymbolArtwork.assetName(table: "S", code: "#"), primary)
    }

    /// Ten "Circle N" symbols share one plate; the digit is drawn on top.
    func testTheCircleDigitsShareOnePlate() {
        let plate = APRSSymbolArtwork.assetName(table: "/", code: "0")
        XCTAssertNotNil(plate)
        for d: Character in "123456789" {
            XCTAssertEqual(APRSSymbolArtwork.assetName(table: "/", code: d), plate)
        }
    }

    /// A missing asset draws nothing at all — no crash, no compile error,
    /// indistinguishable from the bug this replaced. Resolve every name we
    /// claim against the running bundle.
    #if os(macOS)
    func testEveryAssetNameLoadsFromTheBundle() {
        var missing: [String] = []
        for table: Character in ["/", "\\"] {
            for code in codes {
                guard let name = APRSSymbolArtwork.assetName(table: table, code: code) else { continue }
                guard let art = NSImage(named: name) else {
                    missing.append("\(table)\(code) -> \(name) (no such asset)")
                    continue
                }
                // A name that resolves to an empty image still draws nothing,
                // which is the failure this test exists to catch.
                if art.size.width <= 0 || art.size.height <= 0 {
                    missing.append("\(table)\(code) -> \(name) (empty)")
                }
                if !art.isTemplate {
                    missing.append("\(table)\(code) -> \(name) (not a template: it cannot be tinted)")
                }
            }
        }
        XCTAssertTrue(missing.isEmpty, "artwork that does not load: \(missing.joined(separator: ", "))")
    }
    #endif

    // MARK: - The fidelity bug itself

    #if os(macOS)
    private func pixels(_ table: Character, _ code: Character) -> Data? {
        guard let image = APRSGlyphRasterizer.image(table: table, code: code, diameter: 26),
              let data = image.dataProvider?.data else { return nil }
        return Data(referencing: data as NSData)
    }

    /// The whole point. Four digipeaters, four pictures.
    func testOverlaidDigipeatersDrawDifferently() throws {
        let s = try XCTUnwrap(pixels("S", "#"))
        let one = try XCTUnwrap(pixels("1", "#"))
        let i = try XCTUnwrap(pixels("I", "#"))
        let plain = try XCTUnwrap(pixels("\\", "#"))
        XCTAssertNotEqual(s, one, "S# and 1# are different digipeaters")
        XCTAssertNotEqual(s, i, "S# and I# are different digipeaters")
        XCTAssertNotEqual(one, i, "1# and I# are different digipeaters")
        XCTAssertNotEqual(s, plain, "an overlaid digi is not a bare one")
    }

    /// An overlay on a solid symbol has to survive too: `G9` is a letter on a
    /// gas pump, with nothing hollow to sit in.
    func testAnOverlayOnASolidSymbolChangesTheImage() throws {
        XCTAssertNotEqual(try XCTUnwrap(pixels("G", "9")), try XCTUnwrap(pixels("\\", "9")))
    }

    /// The ten circles share a plate, so the digit has to be drawn from the
    /// code — otherwise "Circle 0" through "Circle 9" are one empty ring.
    func testTheCircleDigitsDrawTheirNumber() throws {
        let zero = try XCTUnwrap(pixels("/", "0"))
        let five = try XCTUnwrap(pixels("/", "5"))
        XCTAssertNotEqual(zero, five, "Circle 0 and Circle 5 must not be the same picture")
    }

    func testTheInscriptionIsTheOverlayOrTheCircleDigit() {
        XCTAssertEqual(APRSSymbolArtwork.inscription(table: "S", code: "#"), "S")
        XCTAssertEqual(APRSSymbolArtwork.inscription(table: "/", code: "7"), "7")
        XCTAssertNil(APRSSymbolArtwork.inscription(table: "/", code: "-"),
                     "a house has nothing written on it")
        XCTAssertNil(APRSSymbolArtwork.inscription(table: "\\", code: "#"))
    }

    /// Every surface goes through the rasteriser now, so a symbol asked for at
    /// a point size must render — the sidebar and the picker used to draw a
    /// bare SF Symbol and the map an overlaid one, and the same station looked
    /// like two different things.
    func testAPointSizeRenderMatchesTheDotRender() throws {
        // The dot form is defined as 80% of the diameter, so these are the
        // same request expressed two ways and must agree.
        let byDot = try XCTUnwrap(APRSGlyphRasterizer.image(table: "S", code: "#", diameter: 20))
        let byPoints = try XCTUnwrap(APRSGlyphRasterizer.image(table: "S", code: "#", pointSize: 16))
        XCTAssertEqual(byDot.width, byPoints.width)
        XCTAssertEqual(byDot.height, byPoints.height)
    }

    func testAPointSizeRenderCarriesTheOverlayToo() throws {
        let overlaid = try XCTUnwrap(APRSGlyphRasterizer.image(table: "S", code: "#", pointSize: 18)
            .flatMap { $0.dataProvider?.data }.map { Data(referencing: $0 as NSData) })
        let plain = try XCTUnwrap(APRSGlyphRasterizer.image(table: "\\", code: "#", pointSize: 18)
            .flatMap { $0.dataProvider?.data }.map { Data(referencing: $0 as NSData) })
        XCTAssertNotEqual(overlaid, plain, "the sidebar must not lose the overlay the map keeps")
    }

    /// Codes with no drawing still render — SF Symbols answers for the other
    /// 158, and the fallback is a supported state rather than a hole.
    func testAnUndrawnCodeStillRenders() {
        XCTAssertNil(APRSSymbolArtwork.assetName(table: "/", code: "$"))
        XCTAssertNotNil(APRSGlyphRasterizer.image(table: "/", code: "$", diameter: 26),
                        "SF Symbols must still answer where we have drawn nothing")
    }
    #endif
}
