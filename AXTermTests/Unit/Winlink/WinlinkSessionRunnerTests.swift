import XCTest
import GRDB
@testable import AXTerm

/// End-to-end runner tests against an in-memory scripted RMS gateway:
/// real engine, real codecs, real store — only the radio link is fake.
@MainActor
final class WinlinkSessionRunnerTests: XCTestCase {

    // MARK: - Fake RMS

    /// Plays the gateway side of a B2F conversation in-process. Responses
    /// are delivered asynchronously (fresh main-actor task) like a real
    /// transport would.
    final class FakeRMSTransport: WinlinkTransport {
        var onReceive: ((Data) -> Void)?
        var onClose: ((String?) -> Void)?
        var onDeliveryProgress: ((Int, Int) -> Void)?
        var endpointDescription: String { "fake-rms" }

        /// Mail the RMS holds for the client.
        var rmsOutbox: [WinlinkB2Message] = []
        /// Mail the RMS received from the client (decoded).
        private(set) var rmsInbox: [WinlinkB2Message] = []
        /// Everything the client sent, as text (for handshake assertions).
        private(set) var clientTranscript = ""
        /// When set, the link drops right after the FS answer is sent.
        var dropAfterFS = false
        /// When true, refuse to open.
        var failToOpen = false
        /// When true, open succeeds but the banner never comes.
        var holdBanner = false
        /// When set, open takes this long to connect, like a SABM waiting
        /// for its UA, and fails if the transport is closed meanwhile.
        var connectDelay: TimeInterval = 0
        private(set) var openCalls = 0

        private var lineBuffer = Data()
        private var expectedBodies = 0
        private var bodyParser: FBBBlockCodec.Parser?
        private var sentOurMail = false
        private var closed = false

        func open() async throws {
            openCalls += 1
            let deadline = Date().addingTimeInterval(connectDelay)
            while Date() < deadline {
                if closed { throw WinlinkTransportError.connectTimeout("FAKE-RMS") }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if failToOpen {
                throw WinlinkTransportError.connectTimeout("FAKE-RMS")
            }
            guard !holdBanner else { return }
            emit("FAKE-RMS Gateway\r[WL2K-5.0-B2FWIHJM$]\r;PQ: 23753528\r>\r")
        }

        func send(_ data: Data) {
            clientTranscript += String(data: data, encoding: .isoLatin1) ?? ""
            if expectedBodies > 0 {
                consumeBinary(data)
            } else {
                consumeLines(data)
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            let handler = onClose
            Task { @MainActor in handler?(nil) }
        }

        func dropLink() {
            guard !closed else { return }
            closed = true
            let handler = onClose
            Task { @MainActor in handler?("carrier lost") }
        }

        private func emit(_ text: String) {
            emit(Data(text.unicodeScalars.map { UInt8($0.value & 0xff) }))
        }

        private func emit(_ data: Data) {
            guard !closed else { return }
            let handler = onReceive
            Task { @MainActor in handler?(data) }
        }

        private func consumeLines(_ data: Data) {
            lineBuffer.append(data)
            while let end = lineBuffer.firstIndex(where: { $0 == 0x0d || $0 == 0x0a }) {
                let line = String(data: lineBuffer.prefix(upTo: end), encoding: .isoLatin1) ?? ""
                lineBuffer = Data(lineBuffer.suffix(from: lineBuffer.index(after: end)))
                if !line.isEmpty { handleClientLine(line) }
                if expectedBodies > 0 {
                    // Remaining buffered bytes belong to binary bodies.
                    let leftover = lineBuffer
                    lineBuffer = Data()
                    if !leftover.isEmpty { consumeBinary(leftover) }
                    return
                }
            }
        }

        private var pendingClientProposals = [B2FProposal.Proposal]()

        private func handleClientLine(_ line: String) {
            let upper = line.uppercased()
            if upper.hasPrefix("FC") {
                if let proposal = B2FProposal.Proposal.parse(line) {
                    pendingClientProposals.append(proposal)
                }
                return
            }
            if upper.hasPrefix("F>") {
                let answers = String(repeating: "Y", count: pendingClientProposals.count)
                expectedBodies = pendingClientProposals.count
                pendingClientProposals.removeAll()
                bodyParser = FBBBlockCodec.Parser()
                emit("FS \(answers)\r")
                if dropAfterFS { dropLink() }
                return
            }
            if upper == "FF" {
                if !sentOurMail && !rmsOutbox.isEmpty {
                    sendOurProposals()
                } else {
                    emit("FQ\r")
                }
                return
            }
            if upper.hasPrefix("FS") {
                // Client answered our proposals: stream the bodies. The turn
                // is then the client's (FBB), so nothing more from us.
                guard sentOurMail else { return }
                for message in rmsOutbox {
                    let compressed = LZHUF.encodeB2F(try! message.encode())
                    emit(FBBBlockCodec.encode(title: message.subject, offset: 0, payload: compressed))
                }
                return
            }
            if upper == "FQ" {
                close()
                return
            }
            // ;FW / SID / ;PR — handshake lines, ignored by the fake.
        }

        /// FBB: the station that received the messages speaks next, with
        /// its own proposals or FF, as a CMS does.
        private func takeTurn() {
            if !sentOurMail && !rmsOutbox.isEmpty {
                sendOurProposals()
            } else {
                emit("FF\r")
            }
        }

        private func sendOurProposals() {
            sentOurMail = true
            let proposals = rmsOutbox.map { message -> B2FProposal.Proposal in
                let encoded = try! message.encode()
                return B2FProposal.Proposal(
                    kind: .encapsulatedMessage,
                    mid: message.mid,
                    uncompressedSize: encoded.count,
                    compressedSize: LZHUF.encodeB2F(encoded).count)
            }
            emit(B2FProposal.renderBlock(proposals))
        }

        private func consumeBinary(_ data: Data) {
            guard let parser = bodyParser else { return }
            for event in parser.feed(data) {
                switch event {
                case .completed(let payload):
                    if let decoded = try? LZHUF.decodeB2F(payload),
                       let message = try? WinlinkB2Message.parse(decoded) {
                        rmsInbox.append(message)
                    }
                    expectedBodies -= 1
                    if expectedBodies > 0 {
                        bodyParser = FBBBlockCodec.Parser()
                    } else {
                        bodyParser = nil
                        takeTurn()
                    }
                case .checksumFailure, .protocolError:
                    expectedBodies = 0
                    bodyParser = nil
                default:
                    break
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func makeMessage(mid: String, subject: String = "Runner test") -> WinlinkB2Message {
        WinlinkB2Message(
            mid: mid,
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 12:00")!,
            type: .privateMessage,
            from: "K0EPI",
            to: ["N0CALL"],
            cc: [],
            subject: subject,
            mbo: "K0EPI",
            body: Data("Runner body.\r\n".utf8),
            attachments: [])
    }

    private func runExchange(
        store: SQLiteWinlinkStore,
        transport: FakeRMSTransport
    ) async -> WinlinkExchangeSummary {
        let runner = WinlinkSessionRunner(store: store)
        return await runner.runExchange(
            transport: transport,
            myCallsign: "K0EPI",
            password: "SECRET",
            gatewayName: "FAKE-RMS",
            transportName: "test")
    }

    // MARK: - Waiting for an exchange to end

    /// Bug 40: after a link reset the answering side has to wait for the
    /// exchange on the old link to finish closing before it answers again.
    func testWaitUntilIdleReturnsOnceTheExchangeHasEnded() async throws {
        let store = try makeStore()
        let runner = WinlinkSessionRunner(store: store)
        let idleAtStart = await runner.waitUntilIdle(timeout: 1)
        XCTAssertTrue(idleAtStart, "nothing running")
        XCTAssertNil(runner.currentPeer)

        let transport = FakeRMSTransport()
        let exchange = Task { @MainActor in
            await runner.runExchange(transport: transport, myCallsign: "K0EPI-3", password: nil,
                                     gatewayName: "k0epi-2", transportName: "P2P")
        }
        while !runner.isRunning { await Task.yield() }
        XCTAssertEqual(runner.currentPeer, "K0EPI-2")

        let idle = await runner.waitUntilIdle(timeout: 10)
        XCTAssertTrue(idle)
        XCTAssertFalse(runner.isRunning)
        XCTAssertNil(runner.currentPeer)
        _ = await exchange.value
    }

    func testWaitUntilIdleGivesUpAtTheTimeout() async throws {
        let store = try makeStore()
        let runner = WinlinkSessionRunner(store: store)
        let transport = FakeRMSTransport()
        transport.holdBanner = true
        let exchange = Task { @MainActor in
            await runner.runExchange(transport: transport, myCallsign: "K0EPI-3", password: nil,
                                     gatewayName: "K0EPI-2", transportName: "P2P")
        }
        while !runner.isRunning { await Task.yield() }
        let idle = await runner.waitUntilIdle(timeout: 0.3)
        XCTAssertFalse(idle, "the exchange is still waiting for a banner")
        transport.dropLink()
        _ = await exchange.value
    }

    /// Pressing Abort while waiting for the banner has to end the exchange.
    func testAbortWhileWaitingForTheBannerEndsTheExchange() async throws {
        let store = try makeStore()
        let runner = WinlinkSessionRunner(store: store)
        let transport = FakeRMSTransport()
        transport.holdBanner = true
        let exchange = Task { @MainActor in
            await runner.runExchange(transport: transport, myCallsign: "K0EPI-3", password: nil,
                                     gatewayName: "K0EPI-2", transportName: "P2P")
        }
        while runner.phase != .exchanging { await Task.yield() }
        runner.abort()
        let idle = await runner.waitUntilIdle(timeout: 5)
        // Without this guard a regression hangs the whole test run.
        guard idle else { return XCTFail("the exchange must end after Abort") }
        let summary = await exchange.value
        XCTAssertTrue(summary.aborted)
        XCTAssertEqual(try store.sessionLogs(limit: 1).first?.result, "aborted")
    }

    /// Bug 46: Abort during "Preparing outbound mail…" went to an engine
    /// that did not exist yet and was dropped.
    func testAbortWhilePreparingEndsWithoutConnecting() async throws {
        let store = try makeStore()
        let runner = WinlinkSessionRunner(store: store)
        let transport = FakeRMSTransport()
        let exchange = Task { @MainActor in
            await runner.runExchange(transport: transport, myCallsign: "K0EPI-2", password: nil,
                                     gatewayName: "K0EPI-3", transportName: "P2P")
        }
        while runner.phase != .preparing { await Task.yield() }
        runner.abort()
        let idle = await runner.waitUntilIdle(timeout: 5)
        guard idle else { return XCTFail("Abort while preparing must end the exchange") }
        let summary = await exchange.value
        XCTAssertTrue(summary.aborted)
        XCTAssertNil(summary.failureReason)
        XCTAssertEqual(transport.openCalls, 0, "an aborted exchange does not call anyone")
    }

    /// Bug 46: Abort while the call is being placed has to stop the call,
    /// not wait out the connect timeout.
    func testAbortWhileConnectingCancelsTheCall() async throws {
        let store = try makeStore()
        let runner = WinlinkSessionRunner(store: store)
        let transport = FakeRMSTransport()
        transport.connectDelay = 30
        let exchange = Task { @MainActor in
            await runner.runExchange(transport: transport, myCallsign: "K0EPI-2", password: nil,
                                     gatewayName: "K0EPI-3", transportName: "P2P")
        }
        while runner.phase != .connecting { await Task.yield() }
        runner.abort()
        let idle = await runner.waitUntilIdle(timeout: 5)
        guard idle else {
            transport.close()
            return XCTFail("Abort while connecting must end the exchange")
        }
        let summary = await exchange.value
        XCTAssertTrue(summary.aborted)
        XCTAssertNil(summary.failureReason, "the operator stopped it; it did not fail")
        XCTAssertEqual(try store.sessionLogs(limit: 1).first?.result, "aborted")
    }

    // MARK: - Peer-to-peer

    /// Field case 2026-10-01: a peer exchange offered the peer the whole
    /// Outbox. Only mail addressed to the peer may go; the rest waits for a
    /// gateway.
    func testAPeerExchangeSendsOnlyMailAddressedToThePeer() async throws {
        let store = try makeStore()
        var forPeer = makeMessage(mid: "PEERONLY0001", subject: "For the peer")
        forPeer.to = ["K0EPI-3"]
        try store.saveDraft(forPeer)
        try store.queueDraft(mid: "PEERONLY0001")
        try store.saveDraft(makeMessage(mid: "PEERONLY0002", subject: "For the CMS"))
        try store.queueDraft(mid: "PEERONLY0002")

        let transport = FakeRMSTransport()
        let runner = WinlinkSessionRunner(store: store)
        let summary = await runner.runExchange(
            transport: transport, myCallsign: "K0EPI-2", password: nil,
            gatewayName: "K0EPI-3", transportName: "P2P", peer: "K0EPI-3")

        XCTAssertEqual(summary.sentMIDs, ["PEERONLY0001"])
        XCTAssertEqual(transport.rmsInbox.map(\.mid), ["PEERONLY0001"])
        XCTAssertEqual(try store.queuedOutboundMessages().map(\.mid), ["PEERONLY0002"])
    }

    // MARK: - Tests

    func testEmptyPollSucceeds() async throws {
        let store = try makeStore()
        let transport = FakeRMSTransport()
        let summary = await runExchange(store: store, transport: transport)

        XCTAssertNil(summary.failureReason)
        XCTAssertTrue(summary.succeeded)
        XCTAssertTrue(transport.clientTranscript.contains(";FW: K0EPI\r"))
        XCTAssertTrue(transport.clientTranscript.contains(";PR: "))

        let logs = try store.sessionLogs(limit: 5)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].result, "success")
    }

    func testOutboundMailIsSentAndMarkedSent() async throws {
        let store = try makeStore()
        try store.saveDraft(makeMessage(mid: "RUNNERSEND01"))
        try store.queueDraft(mid: "RUNNERSEND01")

        let transport = FakeRMSTransport()
        let summary = await runExchange(store: store, transport: transport)

        XCTAssertEqual(summary.sentMIDs, ["RUNNERSEND01"])
        XCTAssertEqual(transport.rmsInbox.map(\.mid), ["RUNNERSEND01"])
        XCTAssertEqual(transport.rmsInbox[0].subject, "Runner test")

        let stored = try XCTUnwrap(try store.message(mid: "RUNNERSEND01"))
        XCTAssertEqual(stored.state.state, .sent)
        XCTAssertEqual(stored.state.folderId, try store.folderID(for: .sent))
        XCTAssertTrue(try store.queuedOutboundMessages().isEmpty)
    }

    func testInboundMailLandsInInbox() async throws {
        let store = try makeStore()
        let transport = FakeRMSTransport()
        transport.rmsOutbox = [makeMessage(mid: "RUNNERRECV01", subject: "For you")]

        let summary = await runExchange(store: store, transport: transport)

        XCTAssertEqual(summary.receivedMIDs, ["RUNNERRECV01"])
        let inboxID = try store.folderID(for: .inbox)
        let summaries = try store.messages(inFolder: inboxID)
        XCTAssertEqual(summaries.map(\.mid), ["RUNNERRECV01"])
        XCTAssertFalse(summaries[0].isRead)
        XCTAssertEqual(try store.unreadInboxCount(), 1)
    }

    func testBidirectionalExchange() async throws {
        let store = try makeStore()
        try store.saveDraft(makeMessage(mid: "RUNNERSEND01"))
        try store.queueDraft(mid: "RUNNERSEND01")
        let transport = FakeRMSTransport()
        transport.rmsOutbox = [makeMessage(mid: "RUNNERRECV01")]

        let summary = await runExchange(store: store, transport: transport)

        XCTAssertEqual(summary.sentMIDs, ["RUNNERSEND01"])
        XCTAssertEqual(summary.receivedMIDs, ["RUNNERRECV01"])
        XCTAssertEqual(try store.message(mid: "RUNNERSEND01")?.state.state, .sent)
        XCTAssertEqual(try store.message(mid: "RUNNERRECV01")?.state.state, .received)
    }

    func testLinkDropRevertsSendingToQueued() async throws {
        let store = try makeStore()
        try store.saveDraft(makeMessage(mid: "RUNNERDROP01"))
        try store.queueDraft(mid: "RUNNERDROP01")

        let transport = FakeRMSTransport()
        transport.dropAfterFS = true
        let summary = await runExchange(store: store, transport: transport)

        XCTAssertNotNil(summary.failureReason)
        // The message must be back in the queue for the next session.
        let stored = try XCTUnwrap(try store.message(mid: "RUNNERDROP01"))
        XCTAssertEqual(stored.state.state, .queued)
        XCTAssertEqual(try store.queuedOutboundMessages().count, 1)

        let logs = try store.sessionLogs(limit: 5)
        XCTAssertEqual(logs.count, 1)
        XCTAssertNotNil(logs[0].errorText)
    }

    /// A session that dies partway still moved bytes, and the session log
    /// is the only record of how many. Reporting zero made the Stations
    /// list show 0 B/s for precisely the gateways that had done the most
    /// work, because interrupted transfers are the normal case on a
    /// gateway that caps session length.
    func testInterruptedSessionLogsTheBytesItActuallyMoved() async throws {
        let store = try makeStore()
        try store.saveDraft(makeMessage(mid: "RUNNERDROP02"))
        try store.queueDraft(mid: "RUNNERDROP02")

        let transport = FakeRMSTransport()
        transport.dropAfterFS = true
        let summary = await runExchange(store: store, transport: transport)

        XCTAssertNotNil(summary.failureReason)
        XCTAssertGreaterThan(summary.bytesReceived, 0,
                             "the gateway's banner and handshake were received")

        let logs = try store.sessionLogs(limit: 5)
        XCTAssertEqual(logs.count, 1)
        XCTAssertGreaterThan(logs[0].bytesReceived, 0,
                             "a failed session must not log zero bytes")
    }

    func testFailedOpenReportsFailure() async throws {
        let store = try makeStore()
        let transport = FakeRMSTransport()
        transport.failToOpen = true
        let summary = await runExchange(store: store, transport: transport)

        XCTAssertNotNil(summary.failureReason)
        XCTAssertTrue(summary.failureReason!.contains("connect failed"), summary.failureReason!)
        // Nothing reached the air, so there is genuinely nothing to count.
        XCTAssertEqual(summary.bytesReceived, 0)
        XCTAssertEqual(summary.bytesSent, 0)
    }
}
