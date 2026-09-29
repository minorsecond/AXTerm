import XCTest
@testable import AXTerm

/// Scripted-dialog tests for the B2F session state machine.
///
/// Each test plays the RMS side of a conversation and asserts on the
/// engine's emitted actions. `feedChunked` variants re-run dialogs with
/// bytes split at every boundary to prove chunking never matters.
final class B2FSessionEngineTests: XCTestCase {

    // MARK: - Harness

    /// Collects engine actions and exposes the concatenated outbound bytes.
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

        func receive(_ text: String) {
            fire(.bytesReceived(Data(text.utf8)))
        }

        func receive(_ data: Data) {
            fire(.bytesReceived(data))
        }

        var sentText: String { String(data: sentData, encoding: .isoLatin1) ?? "" }

        var completion: WinlinkExchangeSummary? {
            for action in actions {
                if case .complete(let summary) = action { return summary }
            }
            return nil
        }

        var failureReason: String? {
            for action in actions {
                if case .fail(let reason) = action { return reason }
            }
            return nil
        }

        func contains(_ action: B2FSessionEngine.Action) -> Bool {
            actions.contains(action)
        }
    }

    private func makeMessage(mid: String = "TESTMID00001", subject: String = "Test",
                             body: String = "Hello from the test suite.\r\n") -> WinlinkB2Message {
        WinlinkB2Message(
            mid: mid,
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 12:00")!,
            type: .privateMessage,
            from: "K0EPI",
            to: ["N0CALL"],
            cc: [],
            subject: subject,
            mbo: "K0EPI",
            body: Data(body.utf8),
            attachments: []
        )
    }

    private func prepare(_ message: WinlinkB2Message) throws -> B2FSessionEngine.PreparedOutbound {
        let encoded = try message.encode()
        return B2FSessionEngine.PreparedOutbound(
            message: message,
            compressed: LZHUF.encodeB2F(encoded),
            uncompressedSize: encoded.count)
    }

    /// The framed binary body an RMS would transmit for `message`.
    private func framedIncomingBody(for message: WinlinkB2Message, title: String = "t") throws -> Data {
        let compressed = LZHUF.encodeB2F(try message.encode())
        return FBBBlockCodec.encode(title: title, offset: 0, payload: compressed)
    }

    /// The FC/F> block an RMS would send proposing `messages`.
    private func remoteProposalBlock(for messages: [WinlinkB2Message]) throws -> String {
        let proposals = try messages.map { message -> B2FProposal.Proposal in
            let encoded = try message.encode()
            return B2FProposal.Proposal(
                kind: .encapsulatedMessage,
                mid: message.mid,
                uncompressedSize: encoded.count,
                compressedSize: LZHUF.encodeB2F(encoded).count)
        }
        return B2FProposal.renderBlock(proposals).replacingOccurrences(of: "\r", with: "\r\n")
    }

    private func makeHarness(password: String? = "SECRET",
                             outbound: [B2FSessionEngine.PreparedOutbound] = []) -> Harness {
        Harness(config: .init(myCallsign: "K0EPI", password: password, outbound: outbound))
    }

    private let standardBanner = "KE7XO-10 Gateway\r\n[WL2K-5.0-B2FWIHJM$]\r\n;PQ: 23753528\r\nCMS via KE7XO >\r\n"

    // MARK: - Handshake

    func testHandshakeSendsFWSIDAndSecureResponse() {
        let harness = makeHarness()
        harness.fire(.connected)
        XCTAssertTrue(harness.contains(.startTimer(.banner, seconds: 90)))

        harness.receive(standardBanner)

        let sent = harness.sentText
        XCTAssertTrue(sent.contains(";FW: K0EPI\r"), sent)
        XCTAssertTrue(sent.contains("[AXTerm-1.0-B2FHM$]\r"), sent)
        // Vector from wl2k-go: challenge 23753528 + SECRET.
        let expected = WinlinkSecureLogin.response(challenge: "23753528", password: "SECRET")
        XCTAssertTrue(sent.contains(";PR: \(expected)\r"), sent)
        XCTAssertTrue(sent.hasSuffix("FF\r"), "empty outbox ends handshake with FF: \(sent)")
    }

    func testHandshakeWithoutChallengeOmitsPR() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive("[WL2K-5.0-B2FWIHJM$]\r\n>\r\n")
        XCTAssertFalse(harness.sentText.contains(";PR:"))
        XCTAssertTrue(harness.sentText.contains(";FW: K0EPI\r"))
    }

    func testPromptWithoutNewlineTriggersHandshake() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive("[WL2K-5.0-B2FWIHJM$]\r\n;PQ: 111\r\n")
        XCTAssertFalse(harness.sentText.contains(";FW:"), "no prompt yet")
        harness.receive(">")
        XCTAssertTrue(harness.sentText.contains(";FW: K0EPI\r"))
    }

    func testB1FGatewayIsRefusedCleanly() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive("[BPQ-6.0.24-B1FWIHJM$]\r\n>\r\n")

        XCTAssertNotNil(harness.failureReason)
        XCTAssertTrue(harness.failureReason!.contains("B2F"), harness.failureReason!)
        XCTAssertTrue(harness.sentText.contains("FQ\r"))
        XCTAssertTrue(harness.contains(.requestDisconnect))
        XCTAssertEqual(harness.engine.state, .failed)
    }

    // MARK: - Empty exchange

    func testEmptyMailboxesBothSidesTerminateCleanly() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        XCTAssertTrue(harness.sentText.hasSuffix("FF\r"))

        harness.receive("FQ\r\n")
        let summary = harness.completion
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.succeeded)
        XCTAssertTrue(summary!.sentMIDs.isEmpty)
        XCTAssertTrue(summary!.receivedMIDs.isEmpty)
        XCTAssertTrue(harness.contains(.requestDisconnect))
    }

    func testRemoteFFAfterOurFFEndsSession() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive("FF\r\n")

        XCTAssertNotNil(harness.completion)
        // We answer their FF with FQ before dropping the link.
        XCTAssertTrue(harness.sentText.hasSuffix("FQ\r"))
    }

    // MARK: - Sending

    func testSendOnlyExchange() throws {
        let outbound = try prepare(makeMessage(mid: "OUTMSG000001"))
        let harness = makeHarness(outbound: [outbound])
        harness.fire(.connected)
        harness.receive(standardBanner)

        // Proposal block with checksum must be on the wire.
        XCTAssertTrue(harness.sentText.contains("FC EM OUTMSG000001 \(outbound.uncompressedSize) \(outbound.compressed.count) 0\r"))
        XCTAssertTrue(harness.sentText.contains("F> "))
        XCTAssertFalse(harness.sentText.contains("FF\r"), "FF only after the batch is resolved")

        harness.receive("FS Y\r\n")
        XCTAssertTrue(harness.contains(.outboundAccepted(mid: "OUTMSG000001", offset: 0)))
        XCTAssertTrue(harness.contains(.outboundBodySent(mid: "OUTMSG000001")))

        // The framed body must decode back to the original payload.
        let framed = FBBBlockCodec.encode(title: outbound.message.subject, offset: 0, payload: outbound.compressed)
        XCTAssertTrue(harness.contains(.send(framed)))
        XCTAssertTrue(harness.sentText.hasSuffix("FF\r"), "outbox drained → FF")

        harness.receive("FQ\r\n")
        let summary = try XCTUnwrap(harness.completion)
        XCTAssertEqual(summary.sentMIDs, ["OUTMSG000001"])
        XCTAssertTrue(summary.succeeded)
    }

    func testResumeOffsetFramesFromOffset() throws {
        let message = makeMessage(mid: "RESUME000001", body: String(repeating: "payload line\r\n", count: 100))
        let outbound = try prepare(message)
        let harness = makeHarness(outbound: [outbound])
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive("FS !100\r\n")

        XCTAssertTrue(harness.contains(.outboundAccepted(mid: "RESUME000001", offset: 100)))
        let framed = FBBBlockCodec.encode(title: message.subject, offset: 100, payload: outbound.compressed)
        XCTAssertTrue(harness.contains(.send(framed)))
    }

    func testRejectAndDeferAnswers() throws {
        let first = try prepare(makeMessage(mid: "REJECTED0001"))
        let second = try prepare(makeMessage(mid: "DEFERRED0001"))
        let harness = makeHarness(outbound: [first, second])
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive("FS N=\r\n")

        XCTAssertTrue(harness.contains(.outboundRejected(mid: "REJECTED0001")))
        XCTAssertTrue(harness.contains(.outboundDeferred(mid: "DEFERRED0001")))
        XCTAssertTrue(harness.sentText.hasSuffix("FF\r"))

        harness.receive("FQ\r\n")
        let summary = try XCTUnwrap(harness.completion)
        XCTAssertEqual(summary.rejectedMIDs, ["REJECTED0001"])
        XCTAssertEqual(summary.deferredMIDs, ["DEFERRED0001"])
        XCTAssertTrue(summary.sentMIDs.isEmpty)
    }

    func testSixMessagesAreProposedInTwoBatches() throws {
        let outbound = try (1...6).map { try prepare(makeMessage(mid: "BATCHMSG000\($0)")) }
        let harness = makeHarness(outbound: outbound)
        harness.fire(.connected)
        harness.receive(standardBanner)

        let firstBatchFCs = harness.sentText.components(separatedBy: "FC EM ").count - 1
        XCTAssertEqual(firstBatchFCs, 5, "first batch capped at 5 proposals")

        harness.receive("FS YYYYY\r\n")
        let allFCs = harness.sentText.components(separatedBy: "FC EM ").count - 1
        XCTAssertEqual(allFCs, 6, "sixth message proposed in a second batch")

        harness.receive("FS Y\r\n")
        XCTAssertTrue(harness.sentText.hasSuffix("FF\r"))
    }

    func testFSAnswerCountMismatchFailsSession() throws {
        let outbound = try prepare(makeMessage(mid: "OUTMSG000001"))
        let harness = makeHarness(outbound: [outbound])
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive("FS YY\r\n")

        XCTAssertNotNil(harness.failureReason)
        XCTAssertEqual(harness.engine.state, .failed)
    }

    // MARK: - Receiving

    func testReceiveOnlyExchange() throws {
        let incoming = makeMessage(mid: "INCOMING0001", subject: "Inbound", body: "Hi there!\r\n")
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)

        harness.receive(try remoteProposalBlock(for: [incoming]))
        XCTAssertTrue(harness.sentText.hasSuffix("FS Y\r"), harness.sentText)
        XCTAssertEqual(harness.engine.state, .receivingBodies)

        harness.receive(try framedIncomingBody(for: incoming))
        let receivedAction = harness.actions.compactMap { action -> WinlinkB2Message? in
            if case .messageFullyReceived(let message, _) = action { return message }
            return nil
        }.first
        XCTAssertEqual(receivedAction, incoming)

        harness.receive("FF\r\n")
        let summary = try XCTUnwrap(harness.completion)
        XCTAssertEqual(summary.receivedMIDs, ["INCOMING0001"])
        XCTAssertTrue(harness.sentText.hasSuffix("FQ\r"))
    }

    func testTurnPassesToUsAfterReceivingBatch() throws {
        // Field capture 2026-08-24 (CMS via W0ARP-10): after the gateway
        // finished transmitting its proposed message it went silent — per
        // FBB the data transfer hands the turn to the receiver, and the
        // gateway waits for our FF (or proposals). Sitting in
        // awaitingRemoteProposals instead left the link idle until the
        // gateway gave up and DISCed (~70 s).
        let incoming = makeMessage(mid: "INCOMING0001", subject: "Inbound", body: "Hi there!\r\n")
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)

        harness.receive(try remoteProposalBlock(for: [incoming]))
        harness.receive(try framedIncomingBody(for: incoming))

        XCTAssertTrue(harness.sentText.hasSuffix("FF\r"),
                      "batch drained → the turn is ours; we must send FF, not wait: \(harness.sentText.suffix(40))")

        // The gateway closes its turn with FQ and the session completes.
        harness.receive("FQ\r\n")
        let summary = try XCTUnwrap(harness.completion)
        XCTAssertEqual(summary.receivedMIDs, ["INCOMING0001"])
        XCTAssertNil(summary.failureReason)
    }

    func testReceiveTwoMessagesInOneBatch() throws {
        let first = makeMessage(mid: "INCOMING0001", body: "first\r\n")
        let second = makeMessage(mid: "INCOMING0002", body: "second\r\n")
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)

        harness.receive(try remoteProposalBlock(for: [first, second]))
        XCTAssertTrue(harness.sentText.hasSuffix("FS YY\r"))

        harness.receive(try framedIncomingBody(for: first))
        harness.receive(try framedIncomingBody(for: second))
        harness.receive("FF\r\n")

        let summary = try XCTUnwrap(harness.completion)
        XCTAssertEqual(summary.receivedMIDs, ["INCOMING0001", "INCOMING0002"])
    }

    func testBidirectionalExchange() throws {
        let outbound = try prepare(makeMessage(mid: "OUTMSG000001"))
        let incoming = makeMessage(mid: "INCOMING0001", body: "reply\r\n")
        let harness = makeHarness(outbound: [outbound])

        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive("FS Y\r\n")
        XCTAssertTrue(harness.sentText.hasSuffix("FF\r"))

        harness.receive(try remoteProposalBlock(for: [incoming]))
        harness.receive(try framedIncomingBody(for: incoming))
        harness.receive("FF\r\n")

        let summary = try XCTUnwrap(harness.completion)
        XCTAssertEqual(summary.sentMIDs, ["OUTMSG000001"])
        XCTAssertEqual(summary.receivedMIDs, ["INCOMING0001"])
    }

    func testByteAtATimeChunkingDoesNotMatter() throws {
        // The full receive-only dialog delivered one byte at a time.
        let incoming = makeMessage(mid: "INCOMING0001", body: "chunky\r\n")
        let harness = makeHarness()
        harness.fire(.connected)

        var script = Data(standardBanner.utf8)
        script.append(Data(try remoteProposalBlock(for: [incoming]).utf8))
        for byte in script { harness.receive(Data([byte])) }

        var binary = try framedIncomingBody(for: incoming)
        binary.append(Data("FF\r\n".utf8))
        for byte in binary { harness.receive(Data([byte])) }

        let summary = try XCTUnwrap(harness.completion)
        XCTAssertEqual(summary.receivedMIDs, ["INCOMING0001"])
        XCTAssertTrue(summary.succeeded)
    }

    func testRemoteChecksumMismatchFails() throws {
        let incoming = makeMessage(mid: "INCOMING0001")
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)

        var block = try remoteProposalBlock(for: [incoming])
        // Corrupt the F> checksum by flipping its bits.
        let range = try XCTUnwrap(block.range(of: "F> "))
        let originalHex = String(block[range.upperBound...].prefix(2))
        let corrupted = String(format: "%02X", UInt8(originalHex, radix: 16)! ^ 0xff)
        block = block.replacingOccurrences(of: "F> \(originalHex)", with: "F> \(corrupted)")
        harness.receive(block)

        XCTAssertNotNil(harness.failureReason)
        XCTAssertTrue(harness.failureReason!.contains("checksum"), harness.failureReason!)
    }

    func testOversizedRemoteProposalIsRejected() throws {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)

        let bogus = "FC EM HUGE00000001 99999999 99999999 0"
        let checksum = B2FChecksum.negatedByteSum(of: Array((bogus + "\r").utf8))
        harness.receive(bogus + "\r\n" + String(format: "F> %02X\r\n", checksum))

        XCTAssertTrue(harness.sentText.hasSuffix("FS N\r"), harness.sentText)
        XCTAssertEqual(harness.engine.state, .awaitingRemoteProposals, "stay in line mode after rejecting all")
    }

    func testPendingMessageAdvisoriesAreIgnored() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive(";PM: K0EPI SOMEMSGID001 512 someone@example.com Subject text\r\n")
        XCTAssertNil(harness.failureReason)
        XCTAssertEqual(harness.engine.state, .awaitingRemoteProposals)
    }

    // MARK: - CMS advisories

    /// Regression: the production CMS refuses unregistered client types
    /// with a "***" advisory and then drops the link. The failure must
    /// carry the real reason, not "link disconnected".
    func testUnknownClientRejectionSurfacesRealReason() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive("*** Unknown client types are not allowed on production CMS servers\r\n")

        let reason = harness.failureReason
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("Unknown client types"), reason!)
        XCTAssertEqual(harness.engine.state, .failed)
    }

    func testGatewayNoticeIncludedInLinkDropReason() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        // A notice that is not itself terminal…
        harness.receive("*** Rate limit reached, come back later\r\n")
        XCTAssertNil(harness.failureReason)
        // …but explains the disconnect that follows.
        harness.fire(.linkDisconnected)
        XCTAssertTrue(harness.failureReason!.contains("Rate limit reached"), harness.failureReason!)
    }

    func testConnectedNoticeIsHarmless() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive("*** K0EPI-7 Connected to CMS\r\n")
        harness.receive("[WL2K-5.0-B2FWIHJM$]\r\n;PQ: 23753528\r\n>\r\n")
        XCTAssertNil(harness.failureReason)
        XCTAssertTrue(harness.sentText.contains(";FW: K0EPI\r"))
    }

    /// Field replay (W0ARP-10 → CMS, Aug 23 2026): when an FS answer
    /// accepts nothing, the CMS takes the turn implicitly — its own FC
    /// proposals follow the FS in the same burst. The client must NOT
    /// send FF (it collides with the proposal and the CMS aborts with
    /// "Unexpected response to proposal"); it must answer FS and receive.
    func testImplicitTurnoverAfterAllDeclinedFS() throws {
        let outbound = try prepare(makeMessage(mid: "OUTMSG000001"))
        let harness = makeHarness(outbound: [outbound])
        harness.fire(.connected)
        harness.receive(standardBanner)

        let incoming = makeMessage(mid: "INCOMING0001", subject: "INQUIRY: LIST")
        harness.receive(";PM: K0EPI 6KFOMF87WJ8T 42548 SERVICE@winlink.org INQUIRY: LIST\r\n")

        let sentBefore = harness.sentText
        harness.receive("FS N\r\n" + (try remoteProposalBlock(for: [incoming])))
        let delta = String(harness.sentText.dropFirst(sentBefore.count))
        XCTAssertFalse(delta.contains("FF\r"), "FF collides with the implicit turnover: \(delta)")
        XCTAssertTrue(delta.contains("FS Y"), delta)

        harness.receive(try framedIncomingBody(for: incoming))
        harness.receive("FF\r\n")
        XCTAssertEqual(harness.completion?.receivedMIDs, ["INCOMING0001"])
        XCTAssertEqual(harness.completion?.rejectedMIDs, ["OUTMSG000001"])
    }

    /// Without a ;PM advisory the classic explicit turnover still applies:
    /// all-declined FS → we send FF as before.
    func testExplicitTurnoverStillUsedWithoutPendingMailAdvisory() throws {
        let outbound = try prepare(makeMessage(mid: "OUTMSG000001"))
        let harness = makeHarness(outbound: [outbound])
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive("FS N\r\n")
        XCTAssertTrue(harness.sentText.hasSuffix("FF\r"))
    }

    /// Gateway error text arriving while the engine expects binary blocks
    /// must surface as the real failure reason, not a framing error.
    func testGatewayErrorTextAtBinaryBoundarySurfacesReason() throws {
        let incoming = makeMessage(mid: "INCOMING0001")
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive(try remoteProposalBlock(for: [incoming]))
        XCTAssertTrue(harness.sentText.contains("FS Y"))
        harness.receive("*** [1] Unexpected response to proposal - Disconnecting (74.81.169.201)\r\n")
        XCTAssertNotNil(harness.failureReason)
        XCTAssertTrue(harness.failureReason!.contains("Unexpected response"), harness.failureReason!)
    }

    // MARK: - Failure paths

    func testBannerTimeoutFails() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.fire(.timerFired(.banner))
        XCTAssertNotNil(harness.failureReason)
        XCTAssertTrue(harness.contains(.requestDisconnect))
    }

    func testStaleTimerIsIgnoredAfterProgress() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.fire(.timerFired(.banner))  // stale: banner already handled
        XCTAssertNil(harness.failureReason)
    }

    func testLinkDropMidSessionFails() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.fire(.linkDisconnected)
        XCTAssertNotNil(harness.failureReason)
    }

    func testLinkDropAfterCompletionIsClean() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.receive("FQ\r\n")
        XCTAssertNotNil(harness.completion)
        harness.fire(.linkDisconnected)
        XCTAssertNil(harness.failureReason)
        XCTAssertEqual(harness.engine.state, .closed)
    }

    func testAbortSendsFQAndDisconnects() {
        let harness = makeHarness()
        harness.fire(.connected)
        harness.receive(standardBanner)
        harness.fire(.abortRequested)
        XCTAssertTrue(harness.sentText.hasSuffix("FQ\r"))
        XCTAssertTrue(harness.contains(.requestDisconnect))
        XCTAssertEqual(harness.completion, nil, "aborted sessions do not complete")
    }

    // MARK: - P2P (answering role)

    /// In a grid-down there is no CMS and no gateway to call. Two
    /// stations connect directly, and one of them has to answer — which
    /// means AXTerm has to speak the half of B2F it has never spoken.
    private func makeAnsweringHarness(
        outbound: [B2FSessionEngine.PreparedOutbound] = []
    ) -> Harness {
        Harness(config: .init(
            myCallsign: "K0EPI", password: nil, role: .answering, outbound: outbound))
    }

    /// The answering station speaks first: SID, then a prompt. Until it
    /// does, the caller has nothing to handshake against.
    func testAnsweringStationSendsBannerOnConnect() {
        let harness = makeAnsweringHarness()
        harness.fire(.connected)
        XCTAssertTrue(harness.sentText.contains("[AXTerm-"), harness.sentText)
        XCTAssertTrue(harness.sentText.contains("B2F"), "our SID must advertise B2F")
        XCTAssertTrue(harness.sentText.hasSuffix(">\r"),
                      "the caller waits for a prompt: \(harness.sentText)")
    }

    /// P2P carries no CMS challenge, so the answering side never sends
    /// `;PQ:` and never demands a `;PR:` response.
    func testAnsweringStationIssuesNoPasswordChallenge() {
        let harness = makeAnsweringHarness()
        harness.fire(.connected)
        XCTAssertFalse(harness.sentText.contains(";PQ:"), harness.sentText)
    }

    /// After the caller's handshake the answering station listens: in
    /// B2F the side that just handshook proposes first.
    func testAnsweringStationWaitsForTheCallersProposals() throws {
        let incoming = makeMessage(mid: "INCOMING0001", body: "from the field\r\n")
        let harness = makeAnsweringHarness()
        harness.fire(.connected)
        let bannerLength = harness.sentText.count

        harness.receive(";FW: W0ARP\r\n[Winlink Express-1.7.6.0-B2FHM$]\r\n")
        XCTAssertEqual(harness.sentText.count, bannerLength,
                       "nothing is sent until the caller proposes")

        harness.receive(try remoteProposalBlock(for: [incoming]))
        XCTAssertTrue(harness.sentText.hasSuffix("FS Y\r"), harness.sentText)

        harness.receive(try framedIncomingBody(for: incoming))
        harness.receive("FF\r\n")
        let summary = try XCTUnwrap(harness.completion)
        XCTAssertEqual(summary.receivedMIDs, ["INCOMING0001"])
    }

    /// The full P2P round trip: they send us one, we send them one, both
    /// sides close cleanly. This is the exchange that has to work when
    /// there is no infrastructure at all.
    func testAnsweringStationCompletesBidirectionalP2PExchange() throws {
        let outbound = try prepare(makeMessage(mid: "OUTMSG000001"))
        let incoming = makeMessage(mid: "INCOMING0001", body: "sitrep\r\n")
        let harness = makeAnsweringHarness(outbound: [outbound])

        harness.fire(.connected)
        harness.receive(";FW: W0ARP\r\n[Winlink Express-1.7.6.0-B2FHM$]\r\n")

        // They propose first; we accept and take their body.
        harness.receive(try remoteProposalBlock(for: [incoming]))
        harness.receive(try framedIncomingBody(for: incoming))

        // Their batch drained, so the turn is ours — we propose.
        XCTAssertTrue(harness.sentText.contains("FC EM OUTMSG000001"), harness.sentText)
        harness.receive("FS Y\r\n")
        XCTAssertTrue(harness.contains(.outboundAccepted(mid: "OUTMSG000001", offset: 0)))

        harness.receive("FF\r\n")
        let summary = try XCTUnwrap(harness.completion)
        XCTAssertEqual(summary.receivedMIDs, ["INCOMING0001"])
        XCTAssertEqual(summary.sentMIDs, ["OUTMSG000001"])
    }

    /// A caller whose SID lacks B2F cannot be talked to safely, and the
    /// answering side must say so rather than risk a B1 exchange.
    func testAnsweringStationRejectsANonB2FCaller() {
        let harness = makeAnsweringHarness()
        harness.fire(.connected)
        harness.receive(";FW: W0ARP\r\n[SomeBBS-1.0-B1FHM$]\r\n")
        XCTAssertNotNil(harness.failureReason)
    }

    /// A caller that connects and says nothing must not hold the channel
    /// open forever — in an emergency the frequency is shared.
    func testAnsweringStationTimesOutASilentCaller() {
        let harness = makeAnsweringHarness()
        harness.fire(.connected)
        XCTAssertTrue(harness.contains(.startTimer(.banner, seconds: 90)))
        harness.fire(.timerFired(.banner))
        XCTAssertNotNil(harness.failureReason)
    }

    /// The initiator role must be untouched by all of this.
    func testInitiatorRoleStillSendsNothingBeforeTheBanner() {
        let harness = makeHarness()
        harness.fire(.connected)
        XCTAssertTrue(harness.sentText.isEmpty,
                      "the calling station speaks only after the banner")
    }
}
