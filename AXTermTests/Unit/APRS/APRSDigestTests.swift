//
//  APRSDigestTests.swift
//  AXTermTests
//
//  What the terminal says about an APRS frame, and which chip it files it
//  under. The frames here are the shapes a Colorado 144.390 channel actually
//  carries — the ones in the screenshot that started this.
//

import XCTest
@testable import AXTerm

final class APRSDigestTests: XCTestCase {

    // Roughly Castle Rock, so the distances below are real ones.
    private let here = GreatCircle.Point(latitude: 39.37, longitude: -104.86)

    private func digest(_ info: String, to destination: String = "APRS") -> APRSDigest? {
        APRSDigest.parse(destination: destination, info: Data(info.utf8))
    }

    // MARK: - The frame that could not be printed

    /// Mic-E keeps the latitude in the AX.25 destination and the rest in bytes
    /// that are not text. This is the case the whole change exists for: raw,
    /// the console printed `SYSQSQ` as a callsign and the payload as mojibake.
    func testMicEBecomesAPositionSentence() throws {
        let d = try XCTUnwrap(digest("\u{60}pEzn6cR/\u{60}\"Hd]_4", to: "SYSQSQ"))
        guard case .position(let report) = d else { return XCTFail("expected a position, got \(d)") }
        XCTAssertEqual(report.latitude, 39.52, accuracy: 0.1)
        XCTAssertEqual(report.longitude, -104.70, accuracy: 0.1)

        // Asserted on shape rather than on an exact string: the point is that
        // the operator gets coordinates and a bearing instead of `SYSQSQ` and
        // a payload of unprintable bytes.
        let line = APRSDigestLine.text(for: d, observer: here, inMiles: true)
        XCTAssertTrue(line.hasPrefix("39."), line)
        XCTAssertTrue(line.contains("-104."), line)
        XCTAssertTrue(line.contains("mi"), "the distance from here belongs on the line: \(line)")
        XCTAssertTrue(["N", "S", "E", "W"].contains { line.hasSuffix($0) || line.contains(" \($0) ") }
                      || line.range(of: #"\b[NSEW]{1,3}\b"#, options: .regularExpression) != nil,
                      "expected a compass bearing in: \(line)")
        XCTAssertEqual(d.messageClass, .beacon)
    }

    func testAnUncompressedPositionReadsAsCoordinatesAndComment() throws {
        let d = try XCTUnwrap(digest("!3923.61N/10440.49W#APRS Voyager"))
        guard case .position(let report) = d else { return XCTFail("expected a position") }
        XCTAssertEqual(report.latitude, 39.3935, accuracy: 0.001)
        XCTAssertEqual(report.longitude, -104.6748, accuracy: 0.001)

        let line = APRSDigestLine.text(for: d, observer: nil, inMiles: true)
        XCTAssertTrue(line.hasPrefix("39."), line)
        XCTAssertTrue(line.contains("APRS Voyager"), line)
        XCTAssertFalse(line.contains("mi"), "no observer, so no invented distance: \(line)")
    }

    /// Without a position of our own the coordinates stand alone. With one,
    /// the distance appears — same frame, same decode.
    func testDistanceAppearsOnlyWhenWeKnowWhereWeAre() throws {
        let d = try XCTUnwrap(digest("!3923.61N/10440.49W#"))
        XCTAssertFalse(APRSDigestLine.text(for: d, observer: nil).contains("mi"))
        XCTAssertTrue(APRSDigestLine.text(for: d, observer: here).contains("mi"))
    }

    func testUnitsFollowTheOperatorsPreference() throws {
        let d = try XCTUnwrap(digest("!3923.61N/10440.49W#"))
        XCTAssertTrue(APRSDigestLine.text(for: d, observer: here, inMiles: true).contains("mi"))
        XCTAssertTrue(APRSDigestLine.text(for: d, observer: here, inMiles: false).contains("km"))
    }

    // MARK: - The rest of the channel

    func testAMessageReadsAsAMessageAndFilesUnderData() throws {
        let d = try XCTUnwrap(digest(":K0EPI-7  :are you there?{42"))
        let line = APRSDigestLine.text(for: d)
        XCTAssertTrue(line.contains("K0EPI-7"), line)
        XCTAssertTrue(line.contains("are you there?"), line)
        XCTAssertTrue(line.contains("42"), "the message number is how you ack it: \(line)")
        XCTAssertEqual(d.messageClass, .data)
    }

    /// An ack is protocol chatter about a message, not a message.
    func testAnAckFilesUnderCommandsNotData() throws {
        let d = try XCTUnwrap(digest(":K0EPI-7  :ack42"))
        XCTAssertEqual(d.messageClass, .prompt)
        XCTAssertTrue(APRSDigestLine.text(for: d).contains("42"))
    }

    func testAStatusReportReadsAsTheOperatorsOwnWords() throws {
        let d = try XCTUnwrap(digest(">monitoring 146.52"))
        XCTAssertEqual(APRSDigestLine.text(for: d), "Status: monitoring 146.52")
        XCTAssertEqual(d.messageClass, .beacon)
    }

    func testTelemetryKeepsItsCountsRaw() throws {
        let d = try XCTUnwrap(digest("T#123,010,020,030,040,050,10101010"))
        let line = APRSDigestLine.text(for: d)
        XCTAssertTrue(line.contains("123"), line)
        XCTAssertTrue(line.contains("bits 10101010"), line)
        XCTAssertEqual(d.messageClass, .beacon)
    }

    // MARK: - Comments that are not text

    /// KE0HXD-7 on 144.390, byte for byte. A TM-D710 pads its status field to
    /// a fixed length with `FF`, which is neither ASCII nor UTF-8, so every
    /// one of them decodes to U+FFFD and the line used to end in a row of
    /// replacement glyphs. The frequency and the offset either side of the
    /// padding are real and must survive it.
    func testAStatusFieldPaddedWithFFReadsAsItsRealFields() throws {
        let hex = "6070474D225D776B2F5D2246587D3134352E3139304D487A2020202020202D303630"
            + String(repeating: "FF", count: 18) + "3D0D"
        var bytes = [UInt8]()
        for i in stride(from: 0, to: hex.count, by: 2) {
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            bytes.append(UInt8(hex[start..<end], radix: 16)!)
        }
        let d = try XCTUnwrap(APRSDigest.parse(destination: "S9TRTR", info: Data(bytes)))
        guard case .position(let report) = d else { return XCTFail("expected a position") }

        // The altitude is base-91 in the comment and decodes independently of
        // the padding: 5,587 ft is the figure the terminal has been showing.
        XCTAssertEqual(report.altitudeFeet ?? 0, 5_587, accuracy: 2)

        // The listing is read out of the comment, so it arrives as fields
        // rather than as the raw text the radio padded.
        XCTAssertEqual(report.frequency?.megahertz ?? 0, 145.190, accuracy: 0.0005)
        XCTAssertEqual(report.frequency?.offsetKilohertz, -600)
        XCTAssertNil(report.frequency?.tone, "this one names no tone")

        let line = APRSDigestLine.text(for: d, observer: nil, inMiles: true)
        XCTAssertFalse(line.contains("\u{FFFD}"), "no replacement glyphs on the line: \(line)")
        XCTAssertTrue(line.contains("145.190 MHz"), line)
        XCTAssertTrue(line.contains("-600 kHz"), "the offset is shown in kHz, not wire units: \(line)")
        XCTAssertFalse(line.contains("}"), "the base-91 altitude is not printed twice: \(line)")
    }

    func testRunsOfSpacesLeftByStrippedPaddingAreCollapsed() throws {
        let d = try XCTUnwrap(digest("!3923.61N/10440.49W#a\u{FFFD}\u{FFFD}\u{FFFD}   b"))
        XCTAssertTrue(APRSDigestLine.text(for: d).hasSuffix("\u{201C}a b\u{201D}"),
                      APRSDigestLine.text(for: d))
    }

    /// A comment that was nothing but padding leaves no empty quotes behind.
    func testACommentOfNothingButPaddingDisappears() throws {
        let d = try XCTUnwrap(digest("!3923.61N/10440.49W#\u{FFFD}\u{FFFD}\u{FFFD}"))
        XCTAssertFalse(APRSDigestLine.text(for: d).contains("\u{201C}"),
                       "no empty quotes: \(APRSDigestLine.text(for: d))")
    }

    // MARK: - Not APRS

    /// A NET/ROM broadcast and a BBS prompt are readable as sent, and the
    /// terminal must go on printing them exactly as they arrived.
    func testNonAPRSFramesAreLeftAlone() {
        XCTAssertNil(digest("Welcome to the K0EPI BBS. Enter command:"))
        XCTAssertNil(digest(""))
    }

    // MARK: - Classification

    /// The reason positions are filed as beacons: `detectMessageType` sorted
    /// anything over ten characters into DATA, so on a busy APRS channel there
    /// was no way to quiet the beacons without hiding the conversation.
    func testBeaconsAndConversationLandOnDifferentChips() throws {
        let beacon = try XCTUnwrap(digest("!3923.61N/10440.49W#APRS Voyager"))
        let message = try XCTUnwrap(digest(":K0EPI-7  :are you there?{42"))
        XCTAssertEqual(beacon.messageClass, .beacon)
        XCTAssertEqual(message.messageClass, .data)
        XCTAssertNotEqual(beacon.messageClass, message.messageClass)
    }

    /// The console builds its own digest from the frame, and classifies from
    /// it rather than from how the text happens to read.
    func testConsoleLineDecodesAndClassifiesFromTheFrame() {
        let info = Data("!3923.61N/10440.49W#APRS Voyager".utf8)
        let line = ConsoleLine.packet(from: "WA0DE-9", to: "APMI0", text: "raw text here",
                                      aprsInfo: info)
        XCTAssertNotNil(line.aprs)
        XCTAssertEqual(line.messageType, .beacon)
        XCTAssertEqual(line.aprsInfo, info, "the bytes are kept so a reload decodes the same way")
    }

    /// A frame that is not APRS keeps the old behaviour and stores no bytes.
    func testConsoleLineKeepsNothingForNonAPRS() {
        let line = ConsoleLine.packet(from: "K0EPI-7", to: "NODES", text: "NET/ROM broadcast",
                                      aprsInfo: Data("NET/ROM broadcast".utf8))
        XCTAssertNil(line.aprs)
        XCTAssertNil(line.aprsInfo)
    }

    /// The line a digipeater's beacon becomes. `PHG3830` on its own is a
    /// serial number; unpacked it is the answer to whether this station can be
    /// reached, which on a 144.390 channel is the question.
    func testADigipeatersBeaconReadsAsAnAerial() throws {
        let d = try XCTUnwrap(digest("!3847.33N110459.55W#PHG3830 WA6IFI W2,COn /A=12349"))
        let line = APRSDigestLine.text(for: d, observer: here, inMiles: true)
        XCTAssertTrue(line.contains("9 W"), line)
        XCTAssertTrue(line.contains("2,560 ft HAAT"), line)
        XCTAssertTrue(line.contains("3 dB"), line)
        XCTAssertTrue(line.contains("omni"), line)
        XCTAssertTrue(line.contains("12,349 ft"), "the short /A= is an altitude: \(line)")
        XCTAssertTrue(line.hasSuffix("\u{201C}WA6IFI W2,COn\u{201D}"),
                      "and what is left is the operator's: \(line)")
    }

    /// Metric keeps the same fields in the same order, converted.
    func testTheAerialConvertsWithEverythingElse() throws {
        let d = try XCTUnwrap(digest("!3847.33N110459.55W#PHG3830 WA6IFI"))
        let line = APRSDigestLine.text(for: d, observer: here, inMiles: false)
        XCTAssertTrue(line.contains("780 m HAAT"), line)
    }
}
