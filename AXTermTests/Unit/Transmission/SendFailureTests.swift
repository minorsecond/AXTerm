import XCTest
@testable import AXTerm

/// Telling "the radio is not there" apart from "something went wrong".
///
/// Both arrive at the same callback as an `Error`, and both used to be
/// reported at error level straight to Sentry. One night in September 2026
/// that produced thirty-two transport-level and twenty session-level reports,
/// every one saying a frame could not be sent, and nothing at all saying the
/// station had been off the air since eight in the evening.
final class SendFailureTests: XCTestCase {

    /// The one that is a consequence, not a fault. A node beaconing every half
    /// hour into a link that is down will keep discovering the link is down.
    func testNotConnectedIsALinkBeingDown() {
        XCTAssertTrue(SendFailure.isLinkDown(KISSTransportError.notConnected))
    }

    /// The link was up and the send went wrong on it. That is a real failure
    /// and keeps its report.
    func testASendThatFailedOnALiveLinkIsStillAFault() {
        XCTAssertFalse(SendFailure.isLinkDown(KISSTransportError.sendFailed("EPIPE")))
        XCTAssertFalse(SendFailure.isLinkDown(KISSTransportError.connectionFailed("refused")))
    }

    /// Anything else is a fault by default. Guessing that an unfamiliar error
    /// means the link is down would silence reports we have never seen.
    func testAnUnfamiliarErrorIsTreatedAsAFault() {
        struct Odd: Error {}
        XCTAssertFalse(SendFailure.isLinkDown(Odd()))
        XCTAssertFalse(SendFailure.isLinkDown(
            NSError(domain: "whatever", code: 1)))
    }
}
