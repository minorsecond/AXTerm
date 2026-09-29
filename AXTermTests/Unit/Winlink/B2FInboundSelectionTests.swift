import XCTest
@testable import AXTerm

/// The operator chooses which offered messages to spend airtime on.
///
/// The link is up throughout, with the remote waiting on our FS line, so
/// these tests care as much about what the engine does when nobody answers
/// as about what it does when somebody does.
final class B2FInboundSelectionTests: XCTestCase {

    // MARK: - Harness

    private final class Harness {
        let engine: B2FSessionEngine
        var actions = [B2FSessionEngine.Action]()
        var sentData = Data()

        init(config: B2FSessionEngine.Config) {
            engine = B2FSessionEngine(config: config)
        }

        func fire(_ event: B2FSessionEngine.Event) {
            let newActions = engine.handle(event)
            actions.append(contentsOf: newActions)
            for action in newActions {
                if case .send(let data) = action { sentData.append(data) }
            }
        }

        func receive(_ text: String) { fire(.bytesReceived(Data(text.utf8))) }

        var sentText: String { String(data: sentData, encoding: .isoLatin1) ?? "" }

        /// The FS line, without which nothing else in a session happens.
        var fsLine: String? {
            sentText.components(separatedBy: "\r").first { $0.hasPrefix("FS ") }
        }

        var offers: [B2FSessionEngine.InboundOffer]? {
            for action in actions {
                if case .requestInboundSelection(let offers, _, _) = action { return offers }
            }
            return nil
        }

        func contains(_ action: B2FSessionEngine.Action) -> Bool { actions.contains(action) }
    }

    private let banner = "KE7XO-10 Gateway\r\n[WL2K-5.0-B2FWIHJM$]\r\n;PQ: 23753528\r\nCMS via KE7XO >\r\n"

    private func makeHarness(
        policy: B2FSessionEngine.InboundSelectionPolicy = .ask(timeoutSeconds: 90, autoAcceptUnderBytes: 10 * 1024),
        partialInbound: [String: B2FSessionEngine.PartialInboundBody] = [:]
    ) -> Harness {
        Harness(config: .init(
            myCallsign: "K0EPI", password: "SECRET",
            partialInbound: partialInbound, inboundSelection: policy))
    }

    /// A proposal block for `(mid, compressed)` pairs, with the CRLF line
    /// endings a real gateway uses.
    private func proposalBlock(_ messages: [(mid: String, compressed: Int)]) -> String {
        let proposals = messages.map {
            B2FProposal.Proposal(
                kind: .encapsulatedMessage, mid: $0.mid,
                uncompressedSize: $0.compressed * 3, compressedSize: $0.compressed)
        }
        return B2FProposal.renderBlock(proposals).replacingOccurrences(of: "\r", with: "\r\n")
    }

    private func openSession(_ harness: Harness) {
        harness.fire(.connected)
        harness.receive(banner)
    }

    // MARK: - Asking

    func testOffersCarryTheAdvisoryMetadataAndHoldTheFSLine() throws {
        let harness = makeHarness()
        openSession(harness)

        harness.receive(";PM: WN6OTL BIGMSG000001 40000 K0EPI@winlink.org Roster Published\r\n")
        harness.receive(";PM: WN6OTL SMALLMSG0001 900 K0EPI@winlink.org Net Confirmation\r\n")
        harness.receive(proposalBlock([("BIGMSG000001", 40_000), ("SMALLMSG0001", 900)]))

        let offers = try XCTUnwrap(harness.offers)
        XCTAssertEqual(offers.count, 2)
        XCTAssertEqual(offers.first?.advisory?.subject, "Roster Published")
        XCTAssertEqual(offers.first?.advisory?.destination, "WN6OTL")
        XCTAssertEqual(offers.first?.bytesOnTheAir, 40_000)
        XCTAssertEqual(offers.last?.advisory?.subject, "Net Confirmation")

        // Nothing may go out until the operator has answered: the FS line
        // is the commitment.
        XCTAssertNil(harness.fsLine, harness.sentText)
        XCTAssertEqual(harness.engine.state, .awaitingInboundSelection)
        XCTAssertTrue(harness.contains(.startTimer(.selection, seconds: 90)))
        XCTAssertTrue(harness.contains(.cancelTimer(.response)))
    }

    /// A gateway need not describe what it offers. The proposal is still
    /// downloadable — the row just has a size and nothing else.
    func testAProposalWithNoAdvisoryIsStillOffered() {
        let harness = makeHarness()
        openSession(harness)
        harness.receive(proposalBlock([("QUIETMSG0001", 2_000)]))

        XCTAssertEqual(harness.offers?.count, 1)
        XCTAssertNil(harness.offers?.first?.advisory)
        XCTAssertEqual(harness.offers?.first?.compressedSize, 2_000)
    }

    // MARK: - Answering

    func testSelectingOneOfTwoAcceptsItAndDefersTheOther() {
        let harness = makeHarness()
        openSession(harness)
        harness.receive(proposalBlock([("BIGMSG000001", 40_000), ("SMALLMSG0001", 900)]))

        harness.fire(.inboundSelectionResolved(acceptedMIDs: ["SMALLMSG0001"]))

        // Answers are positional: one code per proposal, in order.
        XCTAssertEqual(harness.fsLine, "FS =Y")
        XCTAssertEqual(harness.engine.state, .receivingBodies)
        XCTAssertTrue(harness.contains(.cancelTimer(.selection)))
    }

    /// Skipping must never be `N`. A deferred message stays on the server
    /// and is offered again; a rejected one is gone.
    func testSkippingEverythingDefersAndNeverRejects() {
        let harness = makeHarness()
        openSession(harness)
        harness.receive(proposalBlock([("MSGAAAAAAAA01", 900), ("MSGBBBBBBBB02", 900)]))

        harness.fire(.inboundSelectionResolved(acceptedMIDs: []))

        XCTAssertEqual(harness.fsLine, "FS ==")
        XCTAssertFalse(harness.fsLine?.contains("N") ?? true)
        // Took nothing, so the gateway gets the turn back rather than
        // starting a body transfer.
        XCTAssertEqual(harness.engine.state, .awaitingRemoteProposals)
    }

    func testSelectingEverythingAcceptsEverything() {
        let harness = makeHarness()
        openSession(harness)
        harness.receive(proposalBlock([("MSGAAAAAAAA01", 900), ("MSGBBBBBBBB02", 40_000)]))

        harness.fire(.inboundSelectionResolved(acceptedMIDs: ["MSGAAAAAAAA01", "MSGBBBBBBBB02"]))
        XCTAssertEqual(harness.fsLine, "FS YY")
    }

    /// A MID the operator never saw offered cannot smuggle itself in.
    func testUnknownMIDsInTheAnswerAreIgnored() {
        let harness = makeHarness()
        openSession(harness)
        harness.receive(proposalBlock([("MSGAAAAAAAA01", 900)]))

        harness.fire(.inboundSelectionResolved(acceptedMIDs: ["SOMETHINGELSE"]))
        XCTAssertEqual(harness.fsLine, "FS =")
    }

    /// The sheet can still be open when the deadline passes or the link
    /// drops; answering then must do nothing rather than send a second FS.
    func testALateAnswerIsIgnored() {
        let harness = makeHarness()
        openSession(harness)
        harness.receive(proposalBlock([("MSGAAAAAAAA01", 900)]))
        harness.fire(.inboundSelectionResolved(acceptedMIDs: ["MSGAAAAAAAA01"]))

        let afterFirstAnswer = harness.sentText
        harness.fire(.inboundSelectionResolved(acceptedMIDs: []))
        XCTAssertEqual(harness.sentText, afterFirstAnswer)
    }

    // MARK: - Nobody at the radio

    /// The SHTF default: emergency traffic is small, so take what an
    /// unattended station can afford and leave the rest on the server.
    func testTheDeadlineTakesTheSmallOnesAndDefersTheRest() {
        let harness = makeHarness(
            policy: .ask(timeoutSeconds: 90, autoAcceptUnderBytes: 10 * 1024))
        openSession(harness)
        harness.receive(proposalBlock([
            ("BIGMSG000001", 40_000), ("SMALLMSG0001", 900), ("MEDIUMMSG001", 9_000),
        ]))

        harness.fire(.timerFired(.selection))

        XCTAssertEqual(harness.fsLine, "FS =YY")
        XCTAssertEqual(harness.engine.state, .receivingBodies)
    }

    /// The link is healthy and the gateway is waiting for an FS line — a
    /// silent operator is not a protocol failure.
    func testTheDeadlineNeverFailsTheSession() {
        let harness = makeHarness()
        openSession(harness)
        harness.receive(proposalBlock([("BIGMSG000001", 40_000)]))
        harness.fire(.timerFired(.selection))

        XCTAssertNil(harness.actions.compactMap { action -> String? in
            if case .fail(let reason) = action { return reason }
            return nil
        }.first)
        XCTAssertEqual(harness.fsLine, "FS =")
    }

    func testAcceptAllPolicyNeverAsks() {
        let harness = makeHarness(policy: .acceptAll)
        openSession(harness)
        harness.receive(proposalBlock([("BIGMSG000001", 40_000), ("SMALLMSG0001", 900)]))

        XCTAssertNil(harness.offers)
        XCTAssertEqual(harness.fsLine, "FS YY")
        XCTAssertEqual(harness.engine.state, .receivingBodies)
    }

    // MARK: - Interaction with the rest of the protocol

    /// A proposal the engine would never buffer is settled without asking:
    /// it is not a choice anyone should be shown, and it still needs its
    /// own `N` in the positional answer.
    func testUnacceptableProposalsAreRefusedWithoutBeingOffered() {
        let harness = makeHarness()
        openSession(harness)
        // 99 MB — past the buffering ceiling.
        let block = "FC EM HUGE00000001 99999999 99999999 0\r\nFC EM SMALLMSG0001 2700 900 0\r\n"
        let checksum = B2FChecksum.negatedByteSum(of: Array(
            "FC EM HUGE00000001 99999999 99999999 0\rFC EM SMALLMSG0001 2700 900 0\r".utf8))
        harness.receive(block + String(format: "F> %02X\r\n", checksum))

        XCTAssertEqual(harness.offers?.count, 1)
        XCTAssertEqual(harness.offers?.first?.mid, "SMALLMSG0001")

        harness.fire(.inboundSelectionResolved(acceptedMIDs: ["SMALLMSG0001"]))
        XCTAssertEqual(harness.fsLine, "FS NY")
    }

    /// A resume must survive the detour through the operator: only the
    /// remainder costs airtime, and the offer says so.
    func testAResumedOfferKeepsItsOffsetThroughTheSelection() {
        let held = Data(repeating: 0x41, count: 400)
        let harness = makeHarness(partialInbound: [
            "RESUMEMSG001": .init(data: held, compressedSize: 1_000),
        ])
        openSession(harness)
        harness.receive(proposalBlock([("RESUMEMSG001", 1_000)]))

        XCTAssertEqual(harness.offers?.first?.resumeFrom, 400)
        XCTAssertEqual(harness.offers?.first?.bytesOnTheAir, 600)

        harness.fire(.inboundSelectionResolved(acceptedMIDs: ["RESUMEMSG001"]))
        XCTAssertEqual(harness.fsLine, "FS !400")
    }

    /// Deferring a resumable message must not throw away the prefix: it is
    /// still valid when the gateway offers the message again.
    func testDeferringAResumableMessageKeepsItsPrefix() {
        let held = Data(repeating: 0x41, count: 400)
        let harness = makeHarness(partialInbound: [
            "RESUMEMSG001": .init(data: held, compressedSize: 1_000),
        ])
        openSession(harness)
        harness.receive(proposalBlock([("RESUMEMSG001", 1_000)]))
        harness.fire(.inboundSelectionResolved(acceptedMIDs: []))

        XCTAssertEqual(harness.fsLine, "FS =")
        XCTAssertFalse(harness.contains(.discardPartialBody(mid: "RESUMEMSG001")))
    }

    /// A prefix that no longer matches the re-proposed size is dropped
    /// whatever the operator decides — that is bookkeeping, not a choice.
    func testAStalePrefixIsDiscardedEvenWhenTheMessageIsSkipped() {
        let held = Data(repeating: 0x41, count: 400)
        let harness = makeHarness(partialInbound: [
            "RESUMEMSG001": .init(data: held, compressedSize: 7_777),
        ])
        openSession(harness)
        harness.receive(proposalBlock([("RESUMEMSG001", 1_000)]))
        harness.fire(.inboundSelectionResolved(acceptedMIDs: []))

        XCTAssertTrue(harness.contains(.discardPartialBody(mid: "RESUMEMSG001")))
        XCTAssertEqual(harness.offers?.first?.resumeFrom, 0)
    }
}
