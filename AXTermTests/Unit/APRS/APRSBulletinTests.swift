import XCTest
@testable import AXTerm

/// Bulletins: the broadcast half of APRS messaging.
final class APRSBulletinTests: XCTestCase {

    // MARK: - The wire

    /// `:BLN1␣␣␣␣␣:text` — nine-character addressee, and no `{NNN`. A message
    /// number requests an ack, and a bulletin reaches every station in range;
    /// asking for one would have all of them answer at once.
    func testABulletinIsAddressedToItsSlotAndAsksForNoAck() {
        let info = APRSBulletin.info(identifier: "1", group: "", text: "Net control 147.105")
        XCTAssertEqual(info, ":BLN1     :Net control 147.105")
        XCTAssertFalse(info.contains("{"), "a bulletin must not request an ack")
    }

    /// A group narrows who it is for, inside the same nine characters.
    func testAGroupNarrowsTheSlot() {
        XCTAssertEqual(APRSBulletin.addressee(identifier: "1", group: "ares"), "BLN1ARES")
        XCTAssertEqual(APRSBulletin.info(identifier: "1", group: "ares", text: "hi"),
                       ":BLN1ARES :hi")
    }

    /// What we transmit is read back as a bulletin by our own parser, filed
    /// under the slot rather than under a callsign.
    func testWhatWeSendParsesBackAsABulletin() throws {
        let info = APRSBulletin.info(identifier: "3", group: "", text: "Shelter open")
        guard case let .bulletin(id, text)? = APRSMessage.parse(info: Data(info.utf8)) else {
            return XCTFail("not parsed as a bulletin: \(info)")
        }
        XCTAssertEqual(id.trimmingCharacters(in: .whitespaces), "BLN3")
        XCTAssertEqual(text, "Shelter open")
    }

    // MARK: - What is refused

    func testEmptyTextIsRefused() {
        XCTAssertEqual(APRSBulletin.problem(identifier: "1", group: "", text: "   "), .emptyText)
    }

    func testABadIdentifierIsRefused() {
        XCTAssertEqual(APRSBulletin.problem(identifier: "-", group: "", text: "hi"),
                       .badIdentifier)
    }

    func testAnnouncementIdentifiersAreAccepted() {
        XCTAssertNil(APRSBulletin.problem(identifier: "A", group: "", text: "hi"))
        XCTAssertTrue(APRSBulletin.announcementIdentifiers.contains("Z"))
    }

    func testAGroupThatCannotFitOrIsNotAlphanumericIsRefused() {
        XCTAssertEqual(APRSBulletin.problem(identifier: "1", group: "TOOLONG", text: "hi"),
                       .badGroup)
        XCTAssertEqual(APRSBulletin.problem(identifier: "1", group: "A-B", text: "hi"),
                       .badGroup)
        XCTAssertNil(APRSBulletin.problem(identifier: "1", group: "", text: "hi"))
    }

    /// `{` opens a message number and `|`/`~` are reserved by the spec, so a
    /// bulletin carrying one is read as protocol by somebody downstream.
    func testReservedCharactersAreRefused() {
        for c: Character in ["{", "|", "~"] {
            XCTAssertEqual(APRSBulletin.problem(identifier: "1", group: "", text: "net \(c) now"),
                           .reservedCharacter(c), "\(c) should be refused")
        }
    }

    /// Says how much over, because "too long" leaves the operator counting.
    func testTextTooLongSaysHowFarOver() {
        let text = String(repeating: "x", count: APRSMessage.maxTextLength + 4)
        XCTAssertEqual(APRSBulletin.problem(identifier: "1", group: "", text: text),
                       .textTooLong(over: 4))
    }

    /// Every refusal has to say something an operator can act on — a Problem
    /// that reaches the sheet with an empty message is a disabled button with
    /// no explanation.
    func testEveryProblemExplainsItself() {
        let all: [APRSBulletin.Problem] = [
            .emptyText, .textTooLong(over: 3), .badIdentifier, .badGroup,
            .reservedCharacter("{"),
        ]
        for problem in all {
            XCTAssertFalse(problem.message.isEmpty, "\(problem) says nothing")
        }
    }
}
