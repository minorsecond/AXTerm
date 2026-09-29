import XCTest
@testable import AXTerm

/// Golden byte-level tests for the APRS message/query wire format. The exact
/// info-field bytes are pinned so a parser or encoder change that would break
/// interop with the wider APRS world fails here first.
final class APRSMessageTests: XCTestCase {

    private func parse(_ s: String) -> APRSMessage.Inbound? {
        APRSMessage.parse(info: Data(s.utf8))
    }

    // MARK: - Addressee field

    func testAddresseeFieldIsNineCharactersRightPadded() {
        XCTAssertEqual(APRSMessage.addresseeField("WU2Z"), "WU2Z     ")
        XCTAssertEqual(APRSMessage.addresseeField("K0EPI-7"), "K0EPI-7  ")
        XCTAssertEqual(APRSMessage.addresseeField("KB5YZB-15"), "KB5YZB-15")   // exactly 9
        XCTAssertEqual(APRSMessage.addresseeField("kf0abc-10").count, 9)
        XCTAssertEqual(APRSMessage.addresseeField("kf0abc-10"), "KF0ABC-10")   // uppercased
    }

    // MARK: - Parse

    func testParsesAMessageWithNumber() {
        XCTAssertEqual(parse(":WU2Z     :Testing{003"),
                       .message(addressee: "WU2Z", text: "Testing", number: "003"))
    }

    func testParsesAMessageWithoutNumber() {
        XCTAssertEqual(parse(":K0EPI-7  :hi there"),
                       .message(addressee: "K0EPI-7", text: "hi there", number: nil))
    }

    func testParsesAnAck() {
        XCTAssertEqual(parse(":WU2Z     :ack003"),
                       .ack(addressee: "WU2Z", number: "003"))
    }

    func testParsesAReject() {
        XCTAssertEqual(parse(":WU2Z     :rej003"),
                       .reject(addressee: "WU2Z", number: "003"))
    }

    func testParsesABulletin() {
        XCTAssertEqual(parse(":BLN1     :Club net 8pm 146.52"),
                       .bulletin(id: "BLN1", text: "Club net 8pm 146.52"))
    }

    func testParsesADirectedQuery() {
        XCTAssertEqual(parse(":K0EPI-7  :?APRSP"),
                       .directedQuery(addressee: "K0EPI-7", query: "?APRSP"))
    }

    func testParsesAGeneralQuery() {
        XCTAssertEqual(parse("?APRS?"), .generalQuery("?APRS?"))
    }

    func testTrailingCarriageReturnIsStripped() {
        XCTAssertEqual(parse(":WU2Z     :Testing\r"),
                       .message(addressee: "WU2Z", text: "Testing", number: nil))
    }

    func testABraceInBodyTextIsNotAMessageNumber() {
        // The run after the last '{' is 6 chars, so it is body text, not a
        // line number — the message keeps its full text and requests no ack.
        XCTAssertEqual(parse(":WU2Z     :set {abcdef"),
                       .message(addressee: "WU2Z", text: "set {abcdef", number: nil))
    }

    func testUnwrapsAThirdPartyRelayedMessage() {
        // A message an i-gate relayed onto RF: `}src>dst,path:<payload>`.
        // The embedded ack must still be recovered.
        XCTAssertEqual(parse("}K0VJ-10>APRS,TCPIP,W3OO-1*::WHO-IS   :ack1172"),
                       .ack(addressee: "WHO-IS", number: "1172"))
    }

    func testNonMessageFramesAreNil() {
        XCTAssertNil(parse("!3934.15N/10455.05W-position"))   // position, not a message
        XCTAssertNil(parse(""))
        XCTAssertNil(parse(":short:x"))                        // addressee < 9
    }

    // MARK: - Encode

    func testEncodesAMessage() {
        XCTAssertEqual(APRSMessage.messageInfo(to: "WU2Z", text: "Testing", number: "003"),
                       ":WU2Z     :Testing{003")
    }

    func testEncodesAMessageWithoutNumber() {
        XCTAssertEqual(APRSMessage.messageInfo(to: "K0EPI-7", text: "hi", number: nil),
                       ":K0EPI-7  :hi")
    }

    func testEncodesAnAck() {
        XCTAssertEqual(APRSMessage.ackInfo(to: "WU2Z", number: "003"), ":WU2Z     :ack003")
    }

    func testEncodesAReject() {
        XCTAssertEqual(APRSMessage.rejectInfo(to: "WU2Z", number: "003"), ":WU2Z     :rej003")
    }

    func testEncodesADirectedQuery() {
        XCTAssertEqual(APRSMessage.directedQueryInfo(to: "N0CALL", query: "?APRSP"),
                       ":N0CALL   :?APRSP")
    }

    func testMessageTextIsClampedToSixtySeven() {
        let long = String(repeating: "x", count: 100)
        let info = APRSMessage.messageInfo(to: "WU2Z", text: long, number: nil)
        // ":WU2Z     :" is 11 chars; body is clamped to 67.
        XCTAssertEqual(info.count, 11 + 67)
    }

    // MARK: - Round trip

    func testMessageRoundTrips() {
        let info = APRSMessage.messageInfo(to: "AB1CDE-9", text: "on my way", number: "42")
        XCTAssertEqual(APRSMessage.parse(info: Data(info.utf8)),
                       .message(addressee: "AB1CDE-9", text: "on my way", number: "42"))
    }

    func testAckRoundTrips() {
        let info = APRSMessage.ackInfo(to: "AB1CDE-9", number: "42")
        XCTAssertEqual(APRSMessage.parse(info: Data(info.utf8)),
                       .ack(addressee: "AB1CDE-9", number: "42"))
    }

    // MARK: - Addressed-to-us

    func testIsAddressedToUsMatchesFullCallWithSSID() {
        XCTAssertTrue(APRSMessage.isAddressedToUs("K0EPI-7", ours: ["K0EPI", "K0EPI-7"]))
        XCTAssertFalse(APRSMessage.isAddressedToUs("K0EPI-1", ours: ["K0EPI", "K0EPI-7"]))
    }
}
