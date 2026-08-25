import XCTest
@testable import AXTerm

final class WinlinkP2PListenerTests: XCTestCase {

    private func listener(armed: Bool = true,
                          callsign: String = "K0EPI-7",
                          busy: Bool = false) -> WinlinkP2PListener {
        WinlinkP2PListener(isArmed: armed, myCallsign: callsign, isExchangeRunning: busy)
    }

    // MARK: - Arming

    /// Answering is not neutral: an armed station accepts mail from
    /// anyone and transmits in reply with nobody present. Off by default.
    func testUnarmedStationDoesNotAnswer() {
        XCTAssertEqual(listener(armed: false).decide(called: "K0EPI-7", isInitiator: false),
                       .notArmed)
    }

    func testArmedStationAnswersACallToItself() {
        XCTAssertEqual(listener().decide(called: "K0EPI-7", isInitiator: false), .answer)
    }

    /// Our own outgoing gateway sessions must never be mistaken for
    /// someone calling us.
    func testOutgoingCallsAreNeverAnswered() {
        XCTAssertEqual(listener().decide(called: "W0ARP-10", isInitiator: true), .weInitiated)
    }

    // MARK: - Addressing

    /// The station answers on the callsign it was configured with, not
    /// on whatever happens to arrive.
    func testCallsToAnotherStationAreIgnored() {
        let decision = listener().decide(called: "W0ARP-10", isInitiator: false)
        XCTAssertEqual(decision, .wrongCallsign(called: "W0ARP-10", expected: "K0EPI-7"))
    }

    /// A configured SSID is exact. Otherwise a station set up as K0EPI-7
    /// would hijack calls meant for the node on K0EPI-1 — which is
    /// precisely the collision this operator's setup has.
    func testAConfiguredSSIDAnswersOnlyThatSSID() {
        XCTAssertEqual(listener(callsign: "K0EPI-7").decide(called: "K0EPI-1", isInitiator: false),
                       .wrongCallsign(called: "K0EPI-1", expected: "K0EPI-7"))
        XCTAssertEqual(listener(callsign: "K0EPI-7").decide(called: "K0EPI", isInitiator: false),
                       .wrongCallsign(called: "K0EPI", expected: "K0EPI-7"))
    }

    /// A bare callsign is a wildcard over its own SSIDs.
    func testABareCallsignAnswersOnAnyOfItsSSIDs() {
        XCTAssertEqual(listener(callsign: "K0EPI").decide(called: "K0EPI", isInitiator: false),
                       .answer)
        XCTAssertEqual(listener(callsign: "K0EPI").decide(called: "K0EPI-7", isInitiator: false),
                       .answer)
        // But not over a different callsign that merely starts the same.
        XCTAssertEqual(listener(callsign: "K0EP").decide(called: "K0EPI", isInitiator: false),
                       .wrongCallsign(called: "K0EPI", expected: "K0EP"))
    }

    func testAddressMatchingIgnoresCaseAndWhitespace() {
        XCTAssertEqual(listener(callsign: " k0epi-7 ").decide(called: "k0epi-7", isInitiator: false),
                       .answer)
    }

    // MARK: - Busy

    /// One radio, one session. Answering mid-exchange would interleave
    /// two conversations on the same channel.
    func testABusyStationDoesNotAnswer() {
        XCTAssertEqual(listener(busy: true).decide(called: "K0EPI-7", isInitiator: false), .busy)
    }

    /// Arming is checked before the callsign so a station that is not
    /// armed never reports why it declined a call it was not listening
    /// for in the first place.
    func testUnarmedTakesPrecedenceOverAddressing() {
        XCTAssertEqual(listener(armed: false).decide(called: "W0ARP-10", isInitiator: false),
                       .notArmed)
    }

    // MARK: - Diagnosability

    /// A station that silently ignores callers is indistinguishable from
    /// a broken one, so every refusal explains itself.
    func testEveryRefusalExplainsItself() {
        let decisions: [WinlinkP2PListener.Decision] = [
            .notArmed,
            .wrongCallsign(called: "W0ARP-10", expected: "K0EPI-7"),
            .busy,
            .weInitiated,
        ]
        for decision in decisions {
            XCTAssertFalse(decision.explanation.isEmpty, "\(decision)")
        }
        XCTAssertTrue(
            WinlinkP2PListener.Decision.wrongCallsign(called: "W0ARP-10", expected: "K0EPI-7")
                .explanation.contains("W0ARP-10"))
    }
}
