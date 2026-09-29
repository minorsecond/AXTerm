import XCTest
@testable import AXTerm

/// The reading pane's body derivation.
///
/// Prompted by a real message: `INQUIRY: LIST`, the Winlink catalog reply,
/// 180,575 bytes of fixed-width listing. Selecting it stalled the window.
final class WinlinkRenderedBodyTests: XCTestCase {

    /// A stand-in for that catalog reply — same shape, same order of
    /// magnitude, no dependency on a database that may not be there.
    private func catalogListing(rows: Int = 2_400) -> Data {
        var text = """
        Automated reply from Winlink Inquiry Server.

        Processed: 2026/08/23 14:09
        Re: INQUIRY LIST

        CATEGORY     INQUIRY_ID      SUBJECT                          SIZE    ORIGINATED\r\n
        """
        for row in 0..<rows {
            text += "ARCTIC_ICE   FICN\(String(format: "%05d", row))      "
                + "\"Iceberg Canada East Coast Waters\"              1657    2025/11/25 21:18\r\n"
        }
        return Data(text.utf8)
    }

    func testALongBodyIsCappedAndSaysSo() {
        let body = catalogListing()
        XCTAssertGreaterThan(body.count, 150_000, "fixture should be catalog-sized")

        let rendered = WinlinkRenderedBody.make(body: body)

        XCTAssertTrue(rendered.isTruncated)
        XCTAssertLessThanOrEqual(rendered.shownCharacters, WinlinkRenderedBody.previewCharacterLimit)
        // The whole text is still there for "Show Everything" and for the
        // save-to-file escape hatch.
        XCTAssertEqual(rendered.totalCharacters, rendered.raw.count)
        XCTAssertGreaterThan(rendered.totalCharacters, rendered.shownCharacters)
    }

    /// Cutting mid-row through a fixed-width listing looks like corruption.
    func testTheCapFallsOnALineBoundary() throws {
        let rendered = WinlinkRenderedBody.make(body: catalogListing())
        guard case .text(let attributed) = rendered.content else {
            return XCTFail("a catalog listing is not a forecast")
        }
        let shown = String(attributed.characters)
        XCTAssertTrue(shown.hasSuffix("\r\n") || shown.last?.isNewline == true,
                      "cut mid-line: …\(String(shown.suffix(40)))")
    }

    func testAskingForEverythingRendersEverything() {
        let body = catalogListing()
        let rendered = WinlinkRenderedBody.make(body: body, fullText: true)

        XCTAssertFalse(rendered.isTruncated)
        XCTAssertEqual(rendered.shownCharacters, rendered.totalCharacters)
    }

    /// Ordinary mail is far below the cap and must be untouched.
    func testAShortBodyIsNotCapped() {
        let rendered = WinlinkRenderedBody.make(
            body: Data("Line one.\r\nLine two.\r\n".utf8))

        XCTAssertFalse(rendered.isTruncated)
        guard case .text(let attributed) = rendered.content else {
            return XCTFail("expected plain text")
        }
        XCTAssertEqual(String(attributed.characters), "Line one.\r\nLine two.\r\n")
    }

    /// A forecast is a table, not a wall of text, so the cap has no business
    /// truncating it — and the raw text stays available behind its
    /// disclosure.
    func testAParsedForecastIsNeverTruncated() throws {
        let rendered = WinlinkRenderedBody.make(body: Data(Self.sftco.utf8))

        guard case .forecast = rendered.content else {
            return XCTFail("the SFTCO fixture must parse as a forecast")
        }
        XCTAssertFalse(rendered.isTruncated)
        XCTAssertEqual(rendered.raw, Self.sftco)
    }

    /// Undecodable bytes produce a message, never a crash or an empty pane.
    func testAnUndecodableBodyStillRenders() {
        let rendered = WinlinkRenderedBody.make(body: Data([0xFF, 0xFE, 0x00, 0x01]))
        if case .text(let attributed) = rendered.content {
            XCTAssertFalse(String(attributed.characters).isEmpty)
        } else {
            XCTFail("expected plain text")
        }
    }

    /// The same SFTCO capture `NWSTabularForecastTests` uses, so this
    /// stays honest about what the parser actually accepts.
    private static let sftco = """
    FPUS65 KBOU 240648
    SFTCO\u{20}
    COZ001>014-017>023-030>051-058>099-251100-

    Tabular State Forecast for Colorado
    National Weather Service Denver/Boulder CO
    1247 AM MDT Mon Aug 24 2026

    ROWS INCLUDE...
       Daily predominant daytime weather 6AM-6PM
       Forecast temperatures...early morning low/daytime high
             Probability of precipitation nighttime 6PM-6AM/daytime 6AM-6PM
              - indicates temperatures below zero
             MM indicates missing data


       FCST     FCST     FCST     FCST     FCST     FCST     FCST\u{20}
       Tue      Wed      Thu      Fri      Sat      Sun      Mon\u{20}
       Aug 25   Aug 26   Aug 27   Aug 28   Aug 29   Aug 30   Aug 31\u{20}


    ...NORTHEAST COLORADO...
       DENVER
       Ptcldy   Tstrms   Ptcldy   Sunny    Ptcldy   Ptcldy   Ptcldy\u{20}
       62/88    60/87    60/90    61/94    62/94    63/92    62/91\u{20}
        30/30    40/50    40/30    30/10    20/20    20/30    30/30\u{20}

       BURLINGTON
       Ptcldy   Ptcldy   Sunny    Sunny    Vryhot   Sunny    Sunny\u{20}
       63/89    59/86    59/87    61/94    62/96    62/94    61/91\u{20}
        30/40    50/20    60/10    30/00    10/00    20/00    30/10\u{20}


    ...SOUTHEAST COLORADO...
       COLORADO SPRINGS
       Ptcldy   Ptcldy   Ptcldy   Sunny    Sunny    Ptcldy   Ptcldy\u{20}
       58/86    56/83    55/85    56/89    58/91    59/89    58/87\u{20}
        30/60    60/80    40/50    40/30    10/20    20/30    30/30\u{20}

       PUEBLO
       Sunny    Ptcldy   Sunny    Sunny    Vryhot   Vryhot   Sunny\u{20}
       62/92    60/87    59/90    60/95    62/97    63/96    62/94\u{20}
        40/60    70/50    50/20    40/00    20/10    20/10    20/10\u{20}

    $$

    =====
    Thanks for using Winlink, an Amateur Radio Safety Foundation
    sponsored project. For information about Winlink or to manage
    your Winlink account please visit:
    https://www.winlink.org
    """
}
