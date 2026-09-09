import XCTest
@testable import AXTerm

/// The message layer against the APRS Protocol Reference 1.01 itself.
///
/// Separate from `APRSMessageTests`, which checks that our encoder and our
/// parser agree with each other — a closed loop that stays green even if both
/// are wrong together. These assert the shapes the *document* specifies, with
/// the chapter cited on each, and several are additionally corroborated by a
/// real Xastir accepting or emitting the same bytes on the test rig
/// (`AXTermTests/Fixtures/xastir-oracle*.json`).
final class APRSSpecVectorTests: XCTestCase {

    // MARK: - Chapter 14: message format

    /// The addressee field is **exactly nine characters**, space-padded on the
    /// right, followed by a colon. A shorter callsign does not shorten the
    /// field; that fixed width is what lets a receiver find the colon.
    ///
    /// Corroborated: `:XASTIR-1 :Testing{003` was acked by a real Xastir, so
    /// this padding is what the reference decoder expects.
    func testAddresseeIsNineCharactersSpacePadded() {
        for (call, padded) in [("WU2Z", "WU2Z     "),
                               ("XASTIR-1", "XASTIR-1 "),
                               ("K0EPI-7", "K0EPI-7  "),
                               ("ABCDEFGHI", "ABCDEFGHI")] {
            let info = APRSMessage.messageInfo(to: call, text: "x", number: nil)
            XCTAssertTrue(info.hasPrefix(":" + padded + ":"),
                          "\(call) produced \(info)")
            XCTAssertEqual(info.prefix(11).count, 11, "colon, 9 chars, colon")
        }
    }

    /// The reference's own worked example (ch.14): a message to WU2Z reading
    /// "Testing" with message number 003.
    func testTheReferenceMessageExample() throws {
        let info = APRSMessage.messageInfo(to: "WU2Z", text: "Testing", number: "003")
        XCTAssertEqual(info, ":WU2Z     :Testing{003")

        guard case let .message(addressee, text, number) =
                APRSMessage.parse(info: Data(info.utf8)) else {
            return XCTFail("did not parse as a message")
        }
        XCTAssertEqual(addressee.trimmingCharacters(in: .whitespaces), "WU2Z")
        XCTAssertEqual(text, "Testing")
        XCTAssertEqual(number, "003")
    }

    /// An acknowledgement is the literal `ack` followed by the message number,
    /// addressed back to the sender (ch.14).
    ///
    /// Corroborated: Xastir answered `Testing{003` with `:ORACLE-1 :ack003`.
    func testAcknowledgementFormat() {
        XCTAssertEqual(APRSMessage.ackInfo(to: "ORACLE-1", number: "003"),
                       ":ORACLE-1 :ack003")
        XCTAssertEqual(APRSMessage.ackInfo(to: "WU2Z", number: "1"),
                       ":WU2Z     :ack1")
    }

    /// A reject is the same shape with `rej` (ch.14).
    func testRejectFormat() {
        XCTAssertEqual(APRSMessage.rejectInfo(to: "WU2Z", number: "003"),
                       ":WU2Z     :rej003")
    }

    /// Message numbers are 1 to 5 characters. All of that range round-trips,
    /// and a real Xastir acked `{1`, `{12` and `{99999` on the rig.
    func testMessageNumbersFromOneToFiveCharacters() throws {
        for number in ["1", "12", "003", "9999", "99999"] {
            let info = APRSMessage.messageInfo(to: "WU2Z", text: "x", number: number)
            guard case let .message(_, _, parsed) =
                    APRSMessage.parse(info: Data(info.utf8)) else {
                return XCTFail("\(number) did not parse")
            }
            XCTAssertEqual(parsed, number)
        }
    }

    /// Message text is capped at 67 characters (ch.14).
    func testMessageTextLimit() {
        XCTAssertEqual(APRSMessage.maxTextLength, 67)
    }

    /// A message with no `{number` solicits no acknowledgement — it is a
    /// statement, not a request (ch.14).
    ///
    /// Corroborated: `no-number-here` drew no ack from Xastir.
    func testAnUnnumberedMessageParsesWithNoNumber() throws {
        guard case let .message(_, text, number) =
                APRSMessage.parse(info: Data(":WU2Z     :Not at keyboard.".utf8)) else {
            return XCTFail("did not parse as a message")
        }
        XCTAssertEqual(text, "Not at keyboard.")
        XCTAssertNil(number)
    }

    /// Bulletins are messages whose addressee begins `BLN` (ch.14). They are
    /// broadcasts: nobody acks them and nobody is addressed by them.
    func testBulletinAddresseeShape() throws {
        for id in ["BLN1", "BLN9", "BLN4WX"] {
            let info = ":\(id.padding(toLength: 9, withPad: " ", startingAt: 0)):Snow expected"
            guard case let .bulletin(parsedID, text) =
                    APRSMessage.parse(info: Data(info.utf8)) else {
                return XCTFail("\(id) did not parse as a bulletin")
            }
            XCTAssertEqual(parsedID.trimmingCharacters(in: .whitespaces), id)
            XCTAssertEqual(text, "Snow expected")
        }
    }

    // MARK: - Chapter 15: queries

    /// A directed query rides inside a message: the query token is the message
    /// text, and the station it is aimed at is the addressee (ch.15).
    ///
    /// Corroborated end to end — this is byte-for-byte what the capture script
    /// transmitted and Xastir answered.
    func testDirectedQueryIsAMessageWhoseTextIsTheToken() throws {
        let info = APRSMessage.directedQueryInfo(to: "XASTIR-1", query: "?APRSP")
        XCTAssertEqual(info, ":XASTIR-1 :?APRSP")

        guard case let .directedQuery(addressee, query) =
                APRSMessage.parse(info: Data(info.utf8)) else {
            return XCTFail("did not parse as a directed query")
        }
        XCTAssertEqual(addressee.trimmingCharacters(in: .whitespaces), "XASTIR-1")
        XCTAssertEqual(query, "?APRSP")
    }

    /// Query tokens are written in upper case with a leading `?` (ch.15), and
    /// implementations that follow the document refuse other cases rather than
    /// guessing. Xastir ignored `?aprsp` on the rig; our own normaliser fixes
    /// what an operator types rather than transmitting it as typed.
    func testQueryTokensAreUppercaseWithALeadingQuestionMark() {
        for token in APRSDirectedQuery.allCases.map(\.token) + [APRSMessage.generalQueryAllInfo] {
            XCTAssertTrue(token.hasPrefix("?"), token)
            XCTAssertEqual(token, token.uppercased(), token)
        }
        XCTAssertEqual(APRSStationQuery(callsign: "X", custom: "aprsp").token, "?APRSP")
    }

    /// A general query is unaddressed: it is not a message at all, but a frame
    /// whose information field *starts* with the query token (ch.15). That is
    /// why it reaches everyone and why nobody acks it.
    func testGeneralQueryIsNotAMessage() throws {
        guard case let .generalQuery(text) =
                APRSMessage.parse(info: Data(APRSMessage.generalQueryAllInfo.utf8)) else {
            return XCTFail("?APRS? should parse as a general query, not a message")
        }
        XCTAssertEqual(text, "?APRS?")
    }

    // MARK: - Chapter 5: the AX.25 destination

    /// The AX.25 destination field carries a software tocall or a generic APRS
    /// address — never the message recipient, which lives in the information
    /// field (ch.5). Getting this wrong is invisible locally and wrong on the
    /// air, so it is asserted rather than assumed.
    ///
    /// Corroborated: every reply Xastir sent came from `XASTIR-1>APX218` with
    /// the addressee inside the payload, never in the destination.
    func testTheAddresseeIsNeverTheAX25Destination() {
        let info = APRSMessage.messageInfo(to: "WU2Z", text: "Testing", number: "003")
        XCTAssertTrue(info.contains("WU2Z"))
        XCTAssertTrue(APRSBeacon.tocall.hasPrefix("AP"),
                      "our tocall must look like a tocall: \(APRSBeacon.tocall)")
        XCTAssertNotEqual(APRSBeacon.tocall, "WU2Z")
    }

    // MARK: - Third-party traffic (ch.17)

    /// A `}`-wrapped frame is third-party traffic: the payload is a complete
    /// frame from somewhere else, and unwrapping it once must yield the
    /// original message.
    func testThirdPartyTrafficUnwrapsToTheOriginalMessage() throws {
        let inner = ":XASTIR-1 :?APRSP"
        let wrapped = "}K0EPI-7>APZAXT,TCPIP,WE0FUN-1*:\(inner)"
        guard case let .directedQuery(addressee, query) =
                APRSMessage.parse(info: Data(wrapped.utf8)) else {
            return XCTFail("third-party wrapper did not unwrap")
        }
        XCTAssertEqual(addressee.trimmingCharacters(in: .whitespaces), "XASTIR-1")
        XCTAssertEqual(query, "?APRSP")
    }
}
