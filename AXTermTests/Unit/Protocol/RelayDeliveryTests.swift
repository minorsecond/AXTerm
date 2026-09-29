import XCTest
@testable import AXTerm

/// What can honestly be said about where a sent message has got to.
///
/// A prompt relay is character streaming through connected nodes. AX.25
/// acknowledges exactly one hop: when DRLNOD sends `RR(nr:5)` it means
/// DRLNOD has the bytes and nothing more. KB5YZB-7, COSCO and BBSCBH
/// acknowledge nothing to us at all — there is no end-to-end receipt in the
/// chain. The only other evidence is a reply, which proves the far end got
/// it because it answered.
///
/// So: two states, both earned. Anything walking a message along the middle
/// hops would be invention.
final class RelayDeliveryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testAJustSentMessageIsInFlight() {
        var delivery = RelayDelivery(firstHop: "DRLNOD", destination: "BBSCBH")
        delivery.sent("Ross Wardrup", at: t0)

        XCTAssertEqual(delivery.state, .inFlight)
    }

    /// The one thing the link layer actually tells us.
    func testTheFirstHopAckMovesItToTheFirstHop() {
        var delivery = RelayDelivery(firstHop: "DRLNOD", destination: "BBSCBH")
        delivery.sent("Ross Wardrup", at: t0)
        delivery.acknowledgedByFirstHop(at: t0.addingTimeInterval(1.8))

        XCTAssertEqual(delivery.state, .atFirstHop)
        XCTAssertEqual(delivery.summary, "At DRLNOD · awaiting BBSCBH")
    }

    /// A reply is proof the far end received it, because it answered.
    func testAReplyFromTheDestinationProvesItArrived() {
        var delivery = RelayDelivery(firstHop: "DRLNOD", destination: "BBSCBH")
        delivery.sent("QTH Centennial, CO", at: t0)
        delivery.acknowledgedByFirstHop(at: t0.addingTimeInterval(1.8))
        delivery.answered(at: t0.addingTimeInterval(5.4))

        XCTAssertEqual(delivery.state, .answered)
        XCTAssertEqual(delivery.summary, "Answered by BBSCBH")
    }

    /// The link-layer ack can arrive after the reply on a slow path. Later
    /// evidence must not walk the state backwards.
    func testAnAckArrivingAfterTheReplyDoesNotUndoIt() {
        var delivery = RelayDelivery(firstHop: "DRLNOD", destination: "BBSCBH")
        delivery.sent("QTH", at: t0)
        delivery.answered(at: t0.addingTimeInterval(4))
        delivery.acknowledgedByFirstHop(at: t0.addingTimeInterval(5))

        XCTAssertEqual(delivery.state, .answered)
    }

    /// Sending again is a new question about a new message.
    func testSendingAgainResetsTheEvidence() {
        var delivery = RelayDelivery(firstHop: "DRLNOD", destination: "BBSCBH")
        delivery.sent("first", at: t0)
        delivery.answered(at: t0.addingTimeInterval(3))

        delivery.sent("second", at: t0.addingTimeInterval(10))
        XCTAssertEqual(delivery.state, .inFlight)
        XCTAssertEqual(delivery.text, "second")
    }

    /// Nothing sent yet is not a state to report on.
    func testNothingSentReportsNothing() {
        let delivery = RelayDelivery(firstHop: "DRLNOD", destination: "BBSCBH")
        XCTAssertEqual(delivery.state, .idle)
        XCTAssertNil(delivery.summary)
    }

    /// A direct connection has no chain, and "at DRLNOD · awaiting DRLNOD"
    /// would be nonsense. One hop means the ack *is* arrival.
    func testADirectLinkCollapsesToArrival() {
        var delivery = RelayDelivery(firstHop: "DRLNOD", destination: "DRLNOD")
        delivery.sent("N", at: t0)
        delivery.acknowledgedByFirstHop(at: t0.addingTimeInterval(1))

        XCTAssertEqual(delivery.state, .atFirstHop)
        XCTAssertEqual(delivery.summary, "Delivered to DRLNOD")
    }

    /// The middle of the chain is never claimed either way — that is the
    /// whole point of this type.
    func testTheChainMiddleIsNeverClaimed() {
        var delivery = RelayDelivery(firstHop: "DRLNOD", destination: "BBSCBH")
        delivery.sent("anything", at: t0)
        delivery.acknowledgedByFirstHop(at: t0.addingTimeInterval(1))

        XCTAssertFalse(delivery.summary?.contains("KB5YZB") ?? false)
        XCTAssertFalse(delivery.summary?.contains("COSCO") ?? false)
    }
}
