import XCTest
@testable import AXTerm

/// PHG, RNG and DFS: what a station says about its own reach, from the seven
/// bytes that follow the symbol.
///
/// Every beacon here but the two synthesised ones was heard on the operator's
/// 144.390 channel, where the stations sending this are the digipeaters —
/// which makes it the one field on the line that answers "can I get into that
/// one".
final class APRSCoverageTests: XCTestCase {

    private func parse(_ info: String) -> APRSReport? {
        APRSParser.parse(destination: "APN391", info: Data(info.utf8))
    }

    private func antenna(_ info: String, _ file: StaticString = #filePath,
                         _ line: UInt = #line) throws -> APRSAntenna {
        let report = try XCTUnwrap(parse(info), file: file, line: line)
        guard case .antenna(let antenna) = try XCTUnwrap(report.coverage, file: file, line: line)
        else { throw NotAnAntenna() }
        return antenna
    }

    /// Thrown rather than skipped: a report that turned out not to describe an
    /// antenna is a failure, and a skip would pass quietly.
    private struct NotAnAntenna: Error {}

    // MARK: - PHG

    /// WA6IFI-6. Four digits that are four different scales: a square, a power
    /// of two, a plain number and a compass.
    func testPHGUnpacksToWattsHeightGainAndPattern() throws {
        let a = try antenna("!3847.33N110459.55W#PHG3830 WA6IFI W2,COn /A=12349")
        XCTAssertEqual(a.signal, .transmitting(watts: 9), "the digit is squared")
        XCTAssertEqual(a.heightFeet, 2560, "10 × 2⁸, not 8 feet")
        XCTAssertEqual(a.gainDecibels, 3)
        XCTAssertEqual(a.directivity, .omnidirectional)
        XCTAssertNil(a.beaconsPerHour)
    }

    func testTheFieldLeavesTheComment() throws {
        let r = try XCTUnwrap(parse("!3847.33N110459.55W#PHG3830 WA6IFI W2,COn /A=12349"))
        XCTAssertEqual(r.comment, "WA6IFI W2,COn",
                       "what is left is the operator's, and only that")
    }

    /// `W2,COn` is not a field and is not treated as one. It is the digi
    /// naming the aliases it will repeat, in the operator's own shorthand.
    func testTheAliasListStaysInTheComment() throws {
        let r = try XCTUnwrap(parse("!3926.88NS10412.40W#PHG5370/ WA0DE NE Elbert digi W2,COn"))
        XCTAssertTrue(r.comment.hasSuffix("W2,COn"), r.comment)
    }

    /// BADGR sends eight characters, not seven: the PHGR convention adds a
    /// beacon rate. Left unread it is a stray digit glued to the comment.
    func testTheRateDigitIsReadWhenItIsThere() throws {
        let a = try antenna("!3903.02NS10530.83W#PHG58306/Wilkerson Pass KC0CQZ")
        XCTAssertEqual(a.signal, .transmitting(watts: 25))
        XCTAssertEqual(a.heightFeet, 2560)
        XCTAssertEqual(a.beaconsPerHour, 6)

        let r = try XCTUnwrap(parse("!3903.02NS10530.83W#PHG58306/Wilkerson Pass KC0CQZ"))
        XCTAssertEqual(r.comment, "/Wilkerson Pass KC0CQZ", "the slash is the operator's")
    }

    /// SIMLA sends the plain seven and then a slash. Only a digit is a rate,
    /// or every station that separates its comment with punctuation loses a
    /// character of it.
    func testPunctuationAfterThePatternIsNotARate() throws {
        let a = try antenna("!3905.98NI10402.07W#PHG5370/WA0DE SIMLA digi")
        XCTAssertNil(a.beaconsPerHour)
        XCTAssertEqual(a.signal, .transmitting(watts: 25))
        XCTAssertEqual(a.heightFeet, 80, "10 × 2³")
        XCTAssertEqual(a.gainDecibels, 7)
    }

    /// Directivity is a bearing, not a width: `2` is a beam pointing east.
    func testABeamCarriesItsBearing() throws {
        let a = try antenna("!3847.33N110459.55W#PHG5132beam east")
        XCTAssertEqual(a.directivity, .beam(bearingDegrees: 90))
    }

    // MARK: - RNG and DFS

    /// A station that gives a radius and says nothing about how it got there.
    func testRangeIsAPlainRadius() throws {
        let r = try XCTUnwrap(parse("!3847.33N110459.55W#RNG0050wide coverage"))
        XCTAssertEqual(r.coverage, .range(miles: 50))
        XCTAssertEqual(r.comment, "wide coverage")
    }

    /// A direction finder has no transmitter to describe, so its first digit
    /// counts what it hears instead of what it sends.
    func testDirectionFindingReportsWhatItHears() throws {
        let a = try antenna("!3847.33N110459.55W#DFS2360omni df site")
        XCTAssertEqual(a.signal, .hearing(strengthSPoints: 2))
        XCTAssertEqual(a.heightFeet, 80)
        XCTAssertEqual(a.gainDecibels, 6)
        XCTAssertEqual(a.directivity, .omnidirectional)
    }

    // MARK: - What is not an extension

    /// QUAIL puts its battery voltage where the extension goes. The field is
    /// read in its own slot and nowhere else, so a `PHG` further along the
    /// sentence stays a word in the sentence.
    func testAnExtensionIsOnlyReadInItsOwnSlot() throws {
        let r = try XCTUnwrap(parse("!3901.30NS10622.31W# 12.1V 99F PHG2820 W2,COn"))
        XCTAssertNil(r.coverage)
        XCTAssertEqual(r.comment, "12.1V 99F PHG2820 W2,COn")
    }

    /// Course and speed live in the same seven bytes and are read first: a
    /// moving station is not describing an aerial.
    func testCourseAndSpeedKeepTheSlot() throws {
        let r = try XCTUnwrap(parse("!3935.36N/10440.15W>201/000/A=005938"))
        XCTAssertNil(r.coverage)
        XCTAssertEqual(r.courseDegrees, 201)
        XCTAssertEqual(r.altitudeFeet, 5938)
    }

    // MARK: - Altitude

    /// WA6IFI-6 sends five digits where the spec asks for six. Insisting on
    /// six printed `/A=12349` in the comment and left the altitude column
    /// empty for a station sitting at twelve thousand feet.
    func testAShortAltitudeIsStillAnAltitude() throws {
        XCTAssertEqual(parse("!3847.33N110459.55W#PHG3830 WA6IFI /A=12349")?.altitudeFeet, 12349)
    }

    func testTheSixDigitFormIsUnchanged() throws {
        XCTAssertEqual(parse("!3935.36N/10440.15W>201/000/A=005938")?.altitudeFeet, 5938)
    }

    /// `/A=` with nothing countable after it is not an altitude, and stays
    /// where it was written.
    func testAnEmptyAltitudeIsNotRead() throws {
        let r = try XCTUnwrap(parse("!3847.33N110459.55W#see /A= for nothing"))
        XCTAssertNil(r.altitudeFeet)
        XCTAssertEqual(r.comment, "see /A= for nothing")
    }
}
