import XCTest
@testable import AXTerm

/// The composer's rules.
final class APRSComposeModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 100_000)

    // MARK: - Addressee

    func testAnEmptyAddresseeIsIncompleteRatherThanWrong() {
        let model = APRSComposeModel(to: "", text: "hello")
        XCTAssertNil(model.addresseeProblem, "nothing typed yet is not an error")
        XCTAssertFalse(model.canSend)
    }

    func testACallsignIsAcceptedWithOrWithoutAnSSID() {
        XCTAssertNil(APRSComposeModel(to: "W0ARP", text: "hi").addresseeProblem)
        XCTAssertNil(APRSComposeModel(to: "W0ARP-9", text: "hi").addresseeProblem)
    }

    func testTheAddresseeIsUppercasedAndTrimmed() {
        XCTAssertEqual(APRSComposeModel(to: "  w0arp-9 ", text: "hi").normalizedTo, "W0ARP-9")
    }

    func testSomethingThatIsNotACallsignIsRefused() {
        let model = APRSComposeModel(to: "hello there", text: "hi")
        XCTAssertNotNil(model.addresseeProblem)
        XCTAssertFalse(model.canSend)
    }

    // MARK: - Length

    func testTheLimitIsCountedDownRatherThanUp() {
        let model = APRSComposeModel(to: "W0ARP", text: String(repeating: "x", count: 60))
        XCTAssertEqual(model.remainingCharacters, 7)
        XCTAssertFalse(model.isOverLength)
    }

    /// The old sheet truncated on send, so a message could leave shorter than
    /// what was on screen when the button was pressed.
    func testAnOverLongMessageCannotBeSentRatherThanBeingCutShort() {
        let model = APRSComposeModel(to: "W0ARP",
                                     text: String(repeating: "x", count: 80))
        XCTAssertTrue(model.isOverLength)
        XCTAssertEqual(model.remainingCharacters, -13)
        XCTAssertFalse(model.canSend)
    }

    func testWhitespaceOnlyIsNotAMessage() {
        XCTAssertFalse(APRSComposeModel(to: "W0ARP", text: "   ").canSend)
    }

    func testTheOutgoingBodyIsTrimmed() {
        XCTAssertEqual(APRSComposeModel(to: "W0ARP", text: "  hi  ").outgoingText, "hi")
    }

    // MARK: - Suggestions

    private var heard: [APRSComposeModel.Suggestion] {
        [
            .init(callsign: "W0ARP-1", lastHeard: now.addingTimeInterval(-60), via: "WIDE1"),
            .init(callsign: "W0NED", lastHeard: now.addingTimeInterval(-600), via: nil),
            .init(callsign: "AD1CT", lastHeard: now.addingTimeInterval(-30), via: "WQ8M-9"),
            .init(callsign: "K5RHD-10", lastHeard: nil, via: nil),
        ]
    }

    func testSuggestionsLeadWithWhatWasHeardMostRecently() {
        let model = APRSComposeModel()
        XCTAssertEqual(model.suggestions(from: heard).map(\.callsign),
                       ["AD1CT", "W0ARP-1", "W0NED", "K5RHD-10"])
    }

    func testTypingNarrowsToAPrefix() {
        let model = APRSComposeModel(to: "w0")
        XCTAssertEqual(model.suggestions(from: heard).map(\.callsign), ["W0ARP-1", "W0NED"])
    }

    /// Once the callsign is complete, offering it back is a row that does
    /// nothing.
    func testAnExactMatchIsNotOfferedBack() {
        let model = APRSComposeModel(to: "W0NED")
        XCTAssertTrue(model.suggestions(from: heard).isEmpty)
    }

    func testSuggestionsAreCapped() {
        let many = (0..<50).map {
            APRSComposeModel.Suggestion(callsign: "N0CALL-\($0)",
                                        lastHeard: now.addingTimeInterval(-Double($0)), via: nil)
        }
        XCTAssertEqual(APRSComposeModel().suggestions(from: many).count, 8)
    }

    // MARK: - Heard

    func testAStationNeverHeardIsFlaggedButNotBlocked() {
        let model = APRSComposeModel(to: "VK2XYZ", text: "hi")
        XCTAssertFalse(model.isHeard(in: heard))
        XCTAssertTrue(model.canSend, "an i-gate may still deliver it")
    }

    /// Opening the composer from a station's card fills the field in, and the
    /// sheet has to be able to say which station that is.
    func testAPrefilledAddresseeResolvesToTheStationItNames() {
        let model = APRSComposeModel(to: "AD1CT")
        XCTAssertEqual(model.match(in: heard)?.via, "WQ8M-9")
    }

    func testAnUnheardAddresseeMatchesNothing() {
        XCTAssertNil(APRSComposeModel(to: "VK2XYZ").match(in: heard))
        XCTAssertNil(APRSComposeModel(to: "").match(in: heard))
    }

    func testAHeardStationIsNotFlagged() {
        XCTAssertTrue(APRSComposeModel(to: "ad1ct", text: "hi").isHeard(in: heard))
    }
}
