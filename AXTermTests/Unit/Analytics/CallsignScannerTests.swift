//
//  CallsignScannerTests.swift
//  AXTermTests
//
//  Every string here is real traffic from a Colorado 144.390 channel. The
//  point of the scanner is not to find callsigns — a regex finds plenty. It is
//  to not offer a link to a CTCSS tone.
//

import XCTest
@testable import AXTerm

final class CallsignScannerTests: XCTestCase {

    private let heard: Set<String> = ["WA0DE-9", "K0EPI-7", "KF0YKI-9", "N0NHJ"]

    private func calls(_ text: String) -> [String] {
        CallsignScanner.scan(text, heard: heard).map(\.callsign)
    }

    private func linked(_ text: String) -> [String] {
        CallsignScanner.links(in: text, heard: heard).map(\.callsign)
    }

    // MARK: - What must not be linked

    /// The comment that started this. `T088` is a tone, `-060` an offset,
    /// and the address is an address.
    func testABeaconCommentOffersNoLinksForItsTelemetry() {
        let text = "`Jb}145.130MHz T088 -060 friesr@yahoo.com_%"
        XCTAssertEqual(linked(text), [], "nothing here is a station we can look up")
    }

    func testVersionStringsAreNotCallsigns() {
        XCTAssertEqual(linked("V:7.32 S:16"), [])
        XCTAssertEqual(linked("WX3in1Mini U=12.4V."), [])
        XCTAssertEqual(linked("U=14.2V,T=??.?C//??.?F"), [])
    }

    func testTelemetryAndPHGAreNotCallsigns() {
        XCTAssertEqual(linked("Telemetry #074 · 137, 140, 41, 0, 0 · bits 00010011"), [])
        XCTAssertEqual(linked("PHG5370/WA0DE SIMLA digi W2,COn"), [],
                       "WA0DE is glued to PHG5370 by a slash, so it is part of that field")
    }

    func testAnEmailAddressIsNotAnAPRSAddressee() {
        XCTAssertEqual(linked("mail me at k0epi@example.com"), [],
                       "the @ here makes an email address, not an addressee")
    }

    func testURLsAreLeftAlone() {
        XCTAssertEqual(linked("see https://qrz.com/db/W1AW for details"), [])
        XCTAssertEqual(linked("www.w1aw.org/news"), [])
    }

    // MARK: - What must be linked

    /// The APRS convention for talking to someone.
    func testAnAddressedCallsignIsLinkedEvenWhenUnheard() {
        let hits = CallsignScanner.scan("@kj5imv Happy Friday!", heard: heard)
        XCTAssertEqual(hits.map(\.callsign), ["KJ5IMV"])
        XCTAssertEqual(hits.first?.confidence, .addressed)
        XCTAssertEqual(linked("@kj5imv Happy Friday!"), ["KJ5IMV"])
    }

    /// The strongest evidence there is, and it needs no pattern argument.
    func testAStationWeHaveHeardIsLinked() {
        let hits = CallsignScanner.scan("relaying for WA0DE-9 tonight", heard: heard)
        XCTAssertEqual(hits.map(\.callsign), ["WA0DE-9"])
        XCTAssertEqual(hits.first?.confidence, .heard)
    }

    func testAHeardStationMatchesWhateverItsSSID() {
        XCTAssertEqual(linked("thanks WA0DE-7"), ["WA0DE-7"],
                       "heard on one SSID is heard: the licence is the same person")
    }

    func testACommentNamingAHeardStationLinksOnlyThat() {
        XCTAssertEqual(linked("APRS Voyager de N0NHJ 5,318 ft"), ["N0NHJ"])
    }

    // MARK: - Confidence

    /// A token that only matches the pattern is found but not offered. This is
    /// the line between "we noticed" and "we will send you somewhere".
    func testAnUnheardUnaddressedCallsignIsFoundButNotLinked() {
        let hits = CallsignScanner.scan("worked W1AW today", heard: heard)
        XCTAssertEqual(hits.map(\.callsign), ["W1AW"])
        XCTAssertEqual(hits.first?.confidence, .possible)
        XCTAssertEqual(linked("worked W1AW today"), [], "pattern alone is not enough to link")
    }

    func testServiceEndpointsAreNeverCallsigns() {
        XCTAssertEqual(calls("via WIDE1-1 WIDE2-1 to BEACON"), [])
        XCTAssertEqual(calls("NODES broadcast heard"), [])
    }

    // MARK: - Ranges

    /// The ranges have to be usable for drawing, so they must land on the
    /// callsign and not on the `@` or the surrounding words.
    func testTheRangeCoversTheTokenAsWritten() throws {
        let text = "thanks @kj5imv and WA0DE-9"
        let hits = CallsignScanner.links(in: text, heard: heard)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(String(text[try XCTUnwrap(hits.first).range]), "@kj5imv")
        XCTAssertEqual(String(text[try XCTUnwrap(hits.last).range]), "WA0DE-9")
    }

    func testEmptyAndPunctuationOnlyTextIsHarmless() {
        XCTAssertEqual(calls(""), [])
        XCTAssertEqual(calls("· — , ,"), [])
    }

    // MARK: - Web and email addresses

    /// Stations put these in their comments constantly. The scanner already
    /// had to find them in order to avoid them; now they become links.
    func testWebAddressesBecomeLinks() {
        let text = "NCFPD digi W2,COn NE Elbert digi www.ARESDEC.org"
        let links = CallsignScanner.webLinks(in: text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.url.absoluteString, "https://www.ARESDEC.org",
                       "a bare www. address still needs a scheme to open")
    }

    func testASchemeIsKeptAsWritten() {
        XCTAssertEqual(CallsignScanner.webLinks(in: "see http://www.k0rap.com").first?.url.absoluteString,
                       "http://www.k0rap.com")
    }

    /// The console wraps a station's comment in its own quotation marks, and
    /// the closing one is not part of the address.
    ///
    /// It used to be. `URL` took it without complaint, encoded it into the
    /// hostname as punycode, and clicking K0RAP-9's beacon opened
    /// `www.k0rap.xn--com-9o0a` — a domain that has never existed. Nothing on
    /// screen gave it away, because what was drawn was the comment and the
    /// quote was the console's own.
    func testTheConsolesOwnQuotationMarkIsNotPartOfTheAddress() throws {
        let text = "9.9 mi NNW \u{00B7} \u{201C}http://www.k0rap.com\u{201D}"
        let link = try XCTUnwrap(CallsignScanner.webLinks(in: text).first)
        XCTAssertEqual(link.url.absoluteString, "http://www.k0rap.com")
        XCTAssertEqual(link.url.host(), "www.k0rap.com", "a real hostname, not punycode")
        XCTAssertEqual(String(text[link.range]), "http://www.k0rap.com",
                       "and the quote is not drawn as part of the link either")
    }

    func testAQuotedBareAddressStillGetsItsScheme() throws {
        let text = "\u{201C}www.aresdec.org\u{201D}"
        let link = try XCTUnwrap(CallsignScanner.webLinks(in: text).first)
        XCTAssertEqual(link.url.absoluteString, "https://www.aresdec.org")
    }

    func testEmailAddressesBecomeMailtoLinks() {
        let links = CallsignScanner.webLinks(in: "PHG8230 Randy K5RHD.73@GMAIL.COM Arvada")
        XCTAssertEqual(links.first?.url.absoluteString, "mailto:K5RHD.73@GMAIL.COM")
    }

    /// The sentence keeps its punctuation; the address does not take it along.
    func testTrailingPunctuationIsNotPartOfTheAddress() throws {
        let text = "details at www.aresdec.org."
        let link = try XCTUnwrap(CallsignScanner.webLinks(in: text).first)
        XCTAssertEqual(link.url.absoluteString, "https://www.aresdec.org")
        XCTAssertEqual(String(text[link.range]), "www.aresdec.org", "the full stop stays behind")
    }

    /// The reason `NSDataDetector` is not used: it reads a bare frequency as a
    /// link, and on this channel that is the commonest thing in a comment.
    func testAFrequencyIsNotAWebAddress() {
        XCTAssertEqual(CallsignScanner.webLinks(in: "146.520MHz or QRZ email").count, 0)
        XCTAssertEqual(CallsignScanner.webLinks(in: "147.210 MHz · CTCSS 100.0").count, 0)
        XCTAssertEqual(CallsignScanner.webLinks(in: "U=12.4V,T=??.?C/??.?F").count, 0)
    }

    /// A callsign inside an address is still not a callsign, so the two kinds
    /// of link can never fight over the same characters.
    func testAWebAddressAndACallsignDoNotOverlap() {
        let text = "www.k5rhd.org and WA0DE-9"
        XCTAssertEqual(CallsignScanner.webLinks(in: text).count, 1)
        XCTAssertEqual(CallsignScanner.links(in: text, heard: heard).map(\.callsign), ["WA0DE-9"])
    }

    // MARK: - The link the console draws

    /// Round trip through the private scheme the console renders and catches.
    /// The scheme is never registered with the system, so a mistake here would
    /// send the operator's browser somewhere instead of opening a station.
    func testTheConsoleLinkRoundTrips() throws {
        let url = try XCTUnwrap(ConsoleCallsignLink.url(for: "KF0YKI-9"))
        XCTAssertEqual(url.scheme, ConsoleCallsignLink.scheme)
        XCTAssertEqual(ConsoleCallsignLink.callsign(from: url), "KF0YKI-9")
    }

    func testSomebodyElsesURLIsNotOurs() {
        XCTAssertNil(ConsoleCallsignLink.callsign(from: URL(string: "https://example.com")!))
        XCTAssertNil(ConsoleCallsignLink.callsign(from: URL(string: "mailto:a@b.com")!))
    }
}
