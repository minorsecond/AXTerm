//
//  APRSCommentExtensionTests.swift
//  AXTermTests
//
//  DAO and base-91 comment telemetry. Every expected value here came from
//  Direwolf's `decode_aprs` run against the same frame, not from reading the
//  specification — a refinement applied with the wrong scale or sign puts a
//  station in the wrong place, and that is not something to take on trust.
//

import XCTest
@testable import AXTerm

final class APRSCommentExtensionTests: XCTestCase {

    // MARK: - DAO

    /// decode_aprs: `!3933.48N/10447.63W … !w+K!` → N 39 33.4811, W 104 47.6346
    func testBase91DAOMatchesDirewolf() throws {
        let info = "!3933.48N/10447.63W>324/011/A=005741/146.520MHz or QRZ email!w+K!"
        let r = try XCTUnwrap(APRSParser.parse(destination: "APT314", info: Data(info.utf8)))
        XCTAssertEqual(r.latitude, 39 + 33.4811 / 60, accuracy: 0.0000005)
        XCTAssertEqual(r.longitude, -(104 + 47.6346 / 60), accuracy: 0.0000005)
        XCTAssertTrue(r.hasRefinedPosition)
        XCTAssertFalse(r.comment.contains("!w+K!"), "the extension is not the operator talking")
    }

    /// decode_aprs: the same frame with `!W12!` → N 39 33.4810, W 104 47.6320
    func testHumanReadableDAOMatchesDirewolf() throws {
        let info = "!3933.48N/10447.63W>324/011/A=005741!W12!"
        let r = try XCTUnwrap(APRSParser.parse(destination: "APT314", info: Data(info.utf8)))
        XCTAssertEqual(r.latitude, 39 + 33.4810 / 60, accuracy: 0.0000005)
        XCTAssertEqual(r.longitude, -(104 + 47.6320 / 60), accuracy: 0.0000005)
    }

    /// The refinement increases the magnitude, so a west longitude gets more
    /// negative. Adding to the signed value would walk the station east.
    func testTheRefinementIncreasesMagnitudeNotSignedValue() throws {
        let plain = "!3933.48N/10447.63W>"
        let dao = "!3933.48N/10447.63W>!W58!"
        let a = try XCTUnwrap(APRSParser.parse(destination: "APT314", info: Data(plain.utf8)))
        let b = try XCTUnwrap(APRSParser.parse(destination: "APT314", info: Data(dao.utf8)))
        XCTAssertGreaterThan(b.latitude, a.latitude, "north goes further north")
        XCTAssertLessThan(b.longitude, a.longitude, "west goes further west")
    }

    /// The whole reason for the three-character rule: N1ROG sends `!SN!` on
    /// every beacon, twenty-eight times in one evening. Two characters is not
    /// a DAO, and reading it as one would move the station.
    func testATwoCharacterBangRunIsNotADAO() throws {
        let info = "!3933.48N/10447.63W>!SN!_%"
        let r = try XCTUnwrap(APRSParser.parse(destination: "APT314", info: Data(info.utf8)))
        XCTAssertFalse(r.hasRefinedPosition)
        XCTAssertEqual(r.latitude, 39 + 33.48 / 60, accuracy: 0.0000005, "untouched")
        XCTAssertTrue(r.comment.contains("!SN!"), "left as the text it is: \(r.comment)")
    }

    func testASpaceMeansNoExtraPrecisionForThatCoordinate() throws {
        let info = "!3933.48N/10447.63W>!W5 !"
        let r = try XCTUnwrap(APRSParser.parse(destination: "APT314", info: Data(info.utf8)))
        XCTAssertEqual(r.latitude, 39 + 33.485 / 60, accuracy: 0.0000005)
        XCTAssertEqual(r.longitude, -(104 + 47.63 / 60), accuracy: 0.0000005)
    }

    // MARK: - Base-91 comment telemetry

    /// decode_aprs on VA6TAC's frame: `Seq=4, A1=449, A2=655`.
    func testCommentTelemetryMatchesDirewolf() throws {
        let info = "`pW7o?kk/'\"3r}ARES RDDR|!%%v(3||3"
        let r = try XCTUnwrap(APRSParser.parse(destination: "S8UXTQ", info: Data(info.utf8)))
        let telemetry = try XCTUnwrap(r.commentTelemetry)
        XCTAssertEqual(telemetry.sequence, 4)
        XCTAssertEqual(telemetry.values, [449, 655])
        XCTAssertFalse(r.comment.contains("|!%%v(3|"))
        XCTAssertTrue(r.comment.contains("ARES RDDR"), r.comment)
    }

    /// `|3` is not a telemetry run — it is a Byonics TinyTrak3 signing its
    /// transmission, and it is stripped as a device suffix instead.
    ///
    /// Worth keeping as a test because the first pass here got it wrong, with
    /// Direwolf's apparent agreement: `decode_aprs` without its `tocalls.yaml`
    /// cannot identify devices and leaves the suffix in the comment, which
    /// reads exactly like "it is only text". With the table loaded it says
    /// "Byonics TinyTrak3" and consumes it.
    func testALonePipeIsNotATelemetryRun() {
        var text = "ARES RDDR|3"
        XCTAssertNil(APRSCommentTelemetry.take(from: &text),
                     "four base-91 characters between pipes is the minimum")
        XCTAssertEqual(text, "ARES RDDR|3", "the telemetry reader leaves it alone")
    }

    func testAnOddLengthRunIsRejected() {
        var text = "x|!%%v(|"
        XCTAssertNil(APRSCommentTelemetry.take(from: &text))
    }

    func testFiveChannelsIsTheMost() throws {
        var text = "|!%AABBCCDDEE|"
        let t = try XCTUnwrap(APRSCommentTelemetry.take(from: &text))
        XCTAssertEqual(t.values.count, 5)
        XCTAssertEqual(text, "")
    }

    // MARK: - Device signatures

    /// K0RAP-9's beacon, byte for byte, carriage return included.
    ///
    /// The return is the whole point. A first pass looked for the signature
    /// before trimming, so the last two characters were `4\r` rather than
    /// `_4`, the match failed, and the trim then removed only the return —
    /// leaving `_4` welded to the end of the URL in front of it. The console
    /// linkified `www.k0rap.com_4`, which resolves to a punycode hostname that
    /// goes nowhere.
    func testADeviceSignatureIsFoundEvenBehindACarriageReturn() throws {
        let info = "`pK\u{1C}l4*>/`\"Ew}147.210MHz C100 +060 http://www.k0rap.com_4\r"
        let r = try XCTUnwrap(APRSParser.parse(destination: "SYTUZZ", info: Data(info.utf8)))

        XCTAssertEqual(r.frequency?.megahertz ?? 0, 147.210, accuracy: 0.0005)
        XCTAssertEqual(r.comment, "http://www.k0rap.com",
                       "the signature comes off and the address is left whole")

        let links = CallsignScanner.webLinks(in: r.comment)
        XCTAssertEqual(links.first?.url.absoluteString, "http://www.k0rap.com",
                       "and the link goes where the operator meant")
    }

    /// Two characters of the operator's own that merely look like a signature
    /// are kept: only an exact match from the known set is taken.
    func testTextThatMerelyEndsInTwoCharactersIsKept() throws {
        let info = "`pK\u{1C}l4*>/`\"Ew}back at 5_7\r"
        let r = try XCTUnwrap(APRSParser.parse(destination: "SYTUZZ", info: Data(info.utf8)))
        XCTAssertEqual(r.comment, "back at 5_7")
    }

    // MARK: - Together

    /// N0RAP's beacon is a type code, an altitude, a DAO and a device
    /// signature — four structured fields and not one word of comment.
    /// Direwolf, with its device table loaded, reports exactly the same:
    /// "MIC-E, normal car (side view), Byonics TinyTrak3, In Service" and no
    /// comment line at all.
    func testARealBeaconIsAllStructureAndNoComment() throws {
        let info = "`pD(o>)>/'\"Kv}!w6c!|3"
        let r = try XCTUnwrap(APRSParser.parse(destination: "S8UXTQ", info: Data(info.utf8)))
        XCTAssertNotNil(r.altitudeFeet)
        XCTAssertTrue(r.hasRefinedPosition)
        XCTAssertEqual(r.comment, "", "nothing the operator wrote")
    }

    /// VA6TAC sends the same signature after its telemetry, so both have to
    /// come off to leave the words behind.
    func testTelemetryAndADeviceSignatureBothComeOff() throws {
        let info = "`pW7o?kk/'\"3r}ARES RDDR|!%%v(3||3"
        let r = try XCTUnwrap(APRSParser.parse(destination: "S8UXTQ", info: Data(info.utf8)))
        XCTAssertEqual(r.commentTelemetry?.values, [449, 655])
        XCTAssertEqual(r.comment, "ARES RDDR")
    }
}
