//
//  APRSFrequencySpecTests.swift
//  AXTermTests
//
//  The repeater listing at the front of a comment. Real strings from 144.390.
//

import XCTest
@testable import AXTerm

final class APRSFrequencySpecTests: XCTestCase {

    private func parse(_ s: String) -> (spec: APRSFrequencySpec, remainder: String)? {
        APRSFrequencySpec.parse(s)
    }

    // MARK: - The whole listing

    func testFrequencyToneAndOffset() throws {
        let r = try XCTUnwrap(parse("147.210MHz C100 +060_1"))
        XCTAssertEqual(r.spec.megahertz, 147.210, accuracy: 0.0005)
        XCTAssertEqual(r.spec.tone, .ctcss(hertz: 100.0))
        XCTAssertEqual(r.spec.offsetKilohertz, 600)
        XCTAssertEqual(r.remainder, "_1", "what is left is the operator's")
    }

    /// A TM-D710 pads the gap between the frequency and the offset with six
    /// spaces, and omits the tone entirely.
    func testAPaddedListingWithNoTone() throws {
        let r = try XCTUnwrap(parse("145.190MHz      -060="))
        XCTAssertEqual(r.spec.megahertz, 145.190, accuracy: 0.0005)
        XCTAssertNil(r.spec.tone, "no tone field is not the same as a tone of none")
        XCTAssertEqual(r.spec.offsetKilohertz, -600)
        XCTAssertEqual(r.remainder, "=")
    }

    func testFrequencyAlone() throws {
        let r = try XCTUnwrap(parse("146.415MHz"))
        XCTAssertEqual(r.spec.megahertz, 146.415, accuracy: 0.0005)
        XCTAssertNil(r.spec.tone)
        XCTAssertNil(r.spec.offsetKilohertz)
        XCTAssertEqual(r.remainder, "")
    }

    // MARK: - Tones

    /// The field is the tone with its decimal dropped and the fraction
    /// truncated, so `088` is 88.5 and not 88. Getting this wrong hands an
    /// operator a tone that will not open the repeater.
    func testTheToneTableIsUsedRatherThanArithmetic() {
        XCTAssertEqual(APRSFrequencySpec.ctcss("088"), 88.5)
        XCTAssertEqual(APRSFrequencySpec.ctcss("100"), 100.0)
        XCTAssertEqual(APRSFrequencySpec.ctcss("162"), 162.2)
        XCTAssertEqual(APRSFrequencySpec.ctcss("127"), 127.3)
        XCTAssertEqual(APRSFrequencySpec.ctcss("067"), 67.0)
        XCTAssertEqual(APRSFrequencySpec.ctcss("254"), 254.1)
    }

    /// No two standard tones share a whole-number part, which is what makes
    /// the lookup exact rather than a guess.
    func testNoTwoStandardTonesShareAWholeNumberPart() {
        let wholes = APRSFrequencySpec.standardTones.map { Int($0) }
        XCTAssertEqual(wholes.count, Set(wholes).count)
    }

    /// A tone that is not on the list gets no number invented for it.
    func testAnUnknownToneFieldIsNotGuessedAt() {
        XCTAssertNil(APRSFrequencySpec.ctcss("999"))
        XCTAssertNil(APRSFrequencySpec.ctcss("abc"))
    }

    func testTAndCBothCarryCTCSS() throws {
        XCTAssertEqual(try XCTUnwrap(parse("147.210MHz T088 +060")).spec.tone, .ctcss(hertz: 88.5))
        XCTAssertEqual(try XCTUnwrap(parse("147.210MHz C088 +060")).spec.tone, .ctcss(hertz: 88.5))
    }

    func testDCSKeepsTheCodeAsWritten() throws {
        XCTAssertEqual(try XCTUnwrap(parse("147.210MHz D023 +060")).spec.tone, .dcs(code: "023"),
                       "the leading zero is part of how DCS codes are named")
    }

    /// "There is no tone" and "nothing was said about a tone" are different
    /// facts and must not collapse into each other.
    func testAnExplicitAbsenceOfToneIsItsOwnAnswer() throws {
        XCTAssertEqual(try XCTUnwrap(parse("147.210MHz T000")).spec.tone, APRSFrequencySpec.Tone.none)
        XCTAssertNil(try XCTUnwrap(parse("147.210MHz")).spec.tone)
    }

    // MARK: - What is not a listing

    /// Anchored at the start on purpose: a comment that mentions a frequency
    /// in passing is somebody talking, not a structured field.
    func testAFrequencyMentionedMidSentenceIsLeftAlone() {
        XCTAssertNil(parse("net at 147.210MHz Thursday"))
        XCTAssertNil(parse("Weekly Net Thur 20:00 147.105 plus 107.2"))
    }

    func testMalformedListingsAreNotListings() {
        XCTAssertNil(parse("14.210MHz"), "three digits before the point")
        XCTAssertNil(parse("147.21MHz"), "three digits after it")
        XCTAssertNil(parse("147.210 MHz"), "the unit is attached on the air")
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("WX3in1Mini U=12.4V"))
    }

    /// An offset out of the listing's own format is not an offset.
    func testAnOffsetMustBeSignedAndThreeDigits() throws {
        XCTAssertNil(try XCTUnwrap(parse("147.210MHz 060")).spec.offsetKilohertz)
        XCTAssertEqual(try XCTUnwrap(parse("147.210MHz 060")).remainder, "060")
    }
}
