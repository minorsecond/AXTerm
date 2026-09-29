import XCTest
@testable import AXTerm

final class WinlinkBodyTextTests: XCTestCase {

    /// Verbatim from the 2026-08-24 INQUIRY reply.
    private let serviceReply = """
    Resource URL: https://radar.weather.gov/ridge/standard/KFTG_0.gif
      Inquiry ID: US.RAD.CCO
      Attachment: KFTG_0.jpg

    Note: The image file was very large as requested and has been altered to allow processing.

    =====
    Thanks for using Winlink, an Amateur Radio Safety Foundation
    sponsored project. For information about Winlink or to manage
    your Winlink account please visit:
    https://www.winlink.org
    """

    // MARK: - Detection

    func testFindsEveryWebLinkInOrder() {
        let links = WinlinkBodyText.links(in: serviceReply)
        XCTAssertEqual(links.map(\.absoluteString), [
            "https://radar.weather.gov/ridge/standard/KFTG_0.gif",
            "https://www.winlink.org",
        ])
    }

    func testARepeatedLinkIsOfferedOnce() {
        let body = "See https://example.com and again https://example.com"
        XCTAssertEqual(WinlinkBodyText.links(in: body).count, 1)
    }

    func testBodyWithNoLinksYieldsNone() {
        XCTAssertTrue(WinlinkBodyText.links(in: "Nothing to see here.").isEmpty)
        XCTAssertTrue(WinlinkBodyText.links(in: "").isEmpty)
    }

    /// Only web schemes are linked. Handing an arbitrary scheme to the
    /// system opener on the strength of an over-the-air message from a
    /// third party is not something the operator asked for.
    func testNonWebSchemesAreNotLinked() {
        XCTAssertTrue(WinlinkBodyText.links(in: "file:///etc/passwd").isEmpty)
        XCTAssertTrue(WinlinkBodyText.links(in: "ftp://example.com/x").isEmpty)
    }

    /// A URL at the end of a sentence must not swallow the full stop.
    func testTrailingPunctuationIsNotPartOfTheLink() {
        let links = WinlinkBodyText.links(in: "Visit https://example.com/page.")
        XCTAssertEqual(links.first?.absoluteString, "https://example.com/page")
    }

    func testTrailingBracketIsNotPartOfTheLink() {
        let links = WinlinkBodyText.links(in: "(see https://example.com/a)")
        XCTAssertEqual(links.first?.absoluteString, "https://example.com/a")
    }

    // MARK: - Attributed rendering

    /// The characters that arrived are the characters shown — links are
    /// an overlay, never an edit.
    func testAttributedTextPreservesTheBodyExactly() {
        let attributed = WinlinkBodyText.attributed(serviceReply)
        XCTAssertEqual(String(attributed.characters), serviceReply)
    }

    func testAttributedTextCarriesTheLinkAttribute() throws {
        let attributed = WinlinkBodyText.attributed(serviceReply)
        let linked = attributed.runs.compactMap(\.link)
        XCTAssertEqual(linked.map(\.absoluteString), [
            "https://radar.weather.gov/ridge/standard/KFTG_0.gif",
            "https://www.winlink.org",
        ])
    }

    func testPlainBodyRoundTripsUnchangedAndUnlinked() {
        let plain = "FPUS65 KBOU 240648\r\nSFTCO\r\n"
        let attributed = WinlinkBodyText.attributed(plain)
        XCTAssertEqual(String(attributed.characters), plain)
        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil })
    }
}
