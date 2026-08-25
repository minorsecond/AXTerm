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

        private var lineBuffer = Data()
        private var expectedBodies = 0
        private var bodyParser: FBBBlockCodec.Parser?
        private var sentOurMail = false
        private var closed = false

        func open() async throws {
            if failToOpen {
                throw WinlinkTransportError.connectTimeout("FAKE-RMS")
            }
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
                // Client answered our proposals: stream the bodies, then FF.
                guard sentOurMail else { return }
                for message in rmsOutbox {
                    let compressed = LZHUF.encodeB2F(try! message.encode())
                    emit(FBBBlockCodec.encode(title: message.subject, offset: 0, payload: compressed))
                }
                emit("FF\r")
                return
            }
            if upper == "FQ" {
                close()
                return
            }
            // ;FW / SID / ;PR — handshake lines, ignored by the fake.
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
