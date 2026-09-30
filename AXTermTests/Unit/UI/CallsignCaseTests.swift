//
//  CallsignCaseTests.swift
//  AXTermTests
//
//  The case rules the callsign and grid square fields apply as the operator
//  types: callsigns all upper-case, locators DM79po.
//

import XCTest
@testable import AXTerm

final class CallsignCaseTests: XCTestCase {

    // MARK: - Callsigns

    func testMixedCaseComesBackUpper() {
        XCTAssertEqual(CallsignCase.uppercased("k0Epi"), "K0EPI")
    }

    func testUpperCaseIsReturnedUnchanged() {
        XCTAssertEqual(CallsignCase.uppercased("K0EPI"), "K0EPI")
        XCTAssertEqual(CallsignCase.uppercased("WIDE1-1,WIDE2-1"), "WIDE1-1,WIDE2-1")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(CallsignCase.uppercased(""), "")
    }

    func testAnSSIDSuffixIsKept() {
        XCTAssertEqual(CallsignCase.uppercased("kb5yzb-7"), "KB5YZB-7")
        XCTAssertEqual(CallsignCase.uppercased("k0epi-"), "K0EPI-",
                       "a half-typed SSID is left for the operator to finish")
    }

    func testDigipeaterListsKeepTheirSeparators() {
        XCTAssertEqual(CallsignCase.uppercased("wide1-1,wide2-1"), "WIDE1-1,WIDE2-1")
        XCTAssertEqual(CallsignCase.uppercased("drl, kb5yzb-7  cosco"), "DRL, KB5YZB-7  COSCO")
        XCTAssertEqual(CallsignCase.uppercased("k0epi, "), "K0EPI, ",
                       "a trailing separator is where the next call goes; it stays")
    }

    /// Callsigns are ASCII. Anything else is left as typed, so the length
    /// and the caret do not move and the field's validation can point at it.
    func testNonASCIIIsLeftAlone() {
        XCTAssertEqual(CallsignCase.uppercased("straße"), "STRAßE",
                       "ß would become SS and lengthen the text")
        XCTAssertEqual(CallsignCase.uppercased("k0épi"), "K0éPI")
        XCTAssertEqual(CallsignCase.uppercased("ı"), "ı", "dotless i is not ASCII i")
        XCTAssertEqual(CallsignCase.uppercased("k0epi🙂"), "K0EPI🙂")
    }

    func testTheLengthNeverChanges() {
        for text in ["k0epi-7", "straße", "k0épi", "e\u{301}", "wide1-1, wide2-1", "🙂a"] {
            XCTAssertEqual(CallsignCase.uppercased(text).utf16.count, text.utf16.count, text)
        }
    }

    func testItIsIdempotent() {
        for text in ["k0epi-7", "Straße", "drl, cosco"] {
            let once = CallsignCase.uppercased(text)
            XCTAssertEqual(CallsignCase.uppercased(once), once, text)
        }
    }

    // MARK: - Grid squares

    func testALocatorTakesTheConventionalCase() {
        XCTAssertEqual(Maidenhead.formatted("dm79po"), "DM79po")
        XCTAssertEqual(Maidenhead.formatted("DM79PO"), "DM79po")
        XCTAssertEqual(Maidenhead.formatted("Dm79Po45"), "DM79po45")
        XCTAssertEqual(Maidenhead.formatted("dm79"), "DM79")
    }

    func testAHalfTypedLocatorIsCasedAsFarAsItGoes() {
        XCTAssertEqual(Maidenhead.formatted(""), "")
        XCTAssertEqual(Maidenhead.formatted("d"), "D")
        XCTAssertEqual(Maidenhead.formatted("dm7"), "DM7")
        XCTAssertEqual(Maidenhead.formatted("dm79P"), "DM79p")
    }

    func testALocatorIsTrimmed() {
        XCTAssertEqual(Maidenhead.formatted("  dm79po \n"), "DM79po")
    }

    func testAMalformedLocatorKeepsItsMistakes() {
        XCTAssertEqual(Maidenhead.formatted("7dm9"), "7Dm9")
        XCTAssertEqual(Maidenhead.formatted("DMxxPO"), "DMxxpo")
        XCTAssertFalse(Maidenhead.isValid(Maidenhead.formatted("DMxxPO")))
    }

    func testAFormattedLocatorStillResolves() {
        XCTAssertEqual(Maidenhead.center(of: Maidenhead.formatted("DM79PO")),
                       Maidenhead.center(of: "DM79po"))
    }

    func testTheGeneratedLocatorIsAlreadyFormatted() throws {
        let grid = try XCTUnwrap(Maidenhead.locator(latitude: 39.6, longitude: -104.9, precision: 8))
        XCTAssertEqual(Maidenhead.formatted(grid), grid)
    }
}
