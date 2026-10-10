import XCTest
@testable import AXTerm

/// A long AXDP message shows that it is arriving.
///
/// At the home retest (2026-10-10) A (705) sent the iPad a large block of
/// text. AX.25 acknowledged every frame, but the terminal showed nothing until
/// the last one completed the message, so it looked as if nothing was coming.
/// The terminal now says who is sending and how much has arrived, and a
/// message the link cut off says it stopped.
@MainActor
final class AXDPIncomingProgressTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 4)

    private func chat(_ count: Int) -> Data {
        AXDP.Message(type: .chat, sessionId: 1, messageId: 7,
                     payload: Data(String(repeating: "x", count: count).utf8)).encode()
    }

    private func makeTerminal() -> (SessionCoordinator, ObservableTerminalTxViewModel, AX25Session) {
        let coordinator = SessionCoordinator()
        let settings = AppSettingsStore(defaults: TestDefaults.make("AXDPIncomingProgress"))
        let viewModel = ObservableTerminalTxViewModel(
            client: PacketEngine(settings: settings), settings: settings,
            sourceCall: "K0EPI-3", sessionManager: coordinator.sessionManager)
        viewModel.setupSessionCallbacks()
        TerminalAXDPWiring.connect(coordinator, to: viewModel)
        let session = coordinator.sessionManager.session(for: peer)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        return (coordinator, viewModel, session)
    }

    private func deliver(_ data: Data, on session: AX25Session, _ coordinator: SessionCoordinator) {
        coordinator.sessionManager.onDataDeliveredForReassembly?(session, data)
        coordinator.sessionManager.onDataReceived?(session, data)
    }

    // MARK: The reassembler

    func testAPartialMessageReportsHowMuchHasArrived() {
        var reassembler = AXDPStreamReassembler()
        let message = chat(2000)
        _ = reassembler.split(message.prefix(500))
        XCTAssertEqual(reassembler.partial, AXDPPartialMessage(type: .chat, received: 500, total: message.count))
        _ = reassembler.split(message.dropFirst(500))
        XCTAssertNil(reassembler.partial)
    }

    /// The size is in the header, the type in the first TLV after it.
    func testWhatIsKnownBeforeTheTypeArrives() {
        let message = chat(100)
        var noHeader = AXDPStreamReassembler()
        _ = noHeader.split(message.prefix(5))
        XCTAssertNil(noHeader.partial)

        var noType = AXDPStreamReassembler()
        _ = noType.split(message.prefix(7))
        XCTAssertEqual(noType.partial, AXDPPartialMessage(type: nil, received: 7, total: message.count))
    }

    func testPlainTextIsNoPartialMessage() {
        var reassembler = AXDPStreamReassembler()
        _ = reassembler.split(Data("hello there\rAX".utf8))
        XCTAssertNil(reassembler.partial)
    }

    // MARK: The terminal

    func testTheTerminalShowsAMessageArriving() {
        let (coordinator, viewModel, session) = makeTerminal()
        let message = chat(3000)
        deliver(message.prefix(1000), on: session, coordinator)
        XCTAssertEqual(viewModel.incomingMessage(from: peer),
                       AXDPPartialMessage(type: .chat, received: 1000, total: message.count))
        deliver(message.dropFirst(1000).prefix(1000), on: session, coordinator)
        XCTAssertEqual(viewModel.incomingMessage(from: peer)?.received, 2000)
        deliver(message.dropFirst(2000), on: session, coordinator)
        XCTAssertNil(viewModel.incomingMessage(from: peer))
    }

    /// File chunks have their own progress in Transfers.
    func testOnlyAChatMessageShowsInTheTerminal() {
        let (coordinator, viewModel, session) = makeTerminal()
        let chunk = AXDP.Message(type: .fileChunk, sessionId: 9, messageId: 1, chunkIndex: 0, totalChunks: 4,
                                 payload: Data(repeating: 0x55, count: 400)).encode()
        deliver(chunk.prefix(100), on: session, coordinator)
        XCTAssertNil(viewModel.incomingMessage(from: peer))
    }

    /// The status row under the history says who is sending and how much has
    /// come; a message going out takes the row first.
    func testTheStatusRow() {
        let partial = AXDPPartialMessage(type: .chat, received: 1200, total: 3400)
        XCTAssertEqual(InlineSendStatus.make(progress: nil, deliveredAtLineCount: nil, lineCount: 3,
                                             incoming: (from: "K0EPI-2", message: partial)),
                       .receiving(from: "K0EPI-2", amount: "1.2 of 3.4 KB"))
        XCTAssertEqual(InlineSendStatus.make(progress: nil, deliveredAtLineCount: 3, lineCount: 3,
                                             incoming: (from: "K0EPI-2", message: partial)),
                       .receiving(from: "K0EPI-2", amount: "1.2 of 3.4 KB"))
        XCTAssertEqual(AXDPPartialMessage(type: .chat, received: 300, total: 900).amount, "300 of 900 bytes")
    }

    /// A message the link cut off says so, once, and leaves the status row.
    func testAMessageCutOffByTheLinkSaysSo() {
        let (coordinator, viewModel, session) = makeTerminal()
        var stopped: [(String, AXDPPartialMessage)] = []
        coordinator.onAXDPMessageStoppedPartway = { from, partial in stopped.append((from.display, partial)) }
        let message = chat(3000)
        deliver(message.prefix(1000), on: session, coordinator)
        coordinator.sessionManager.onSessionStateChanged?(session, .connected, .disconnected)

        XCTAssertEqual(stopped.map(\.0), ["K0EPI-4"])
        XCTAssertNil(viewModel.incomingMessage(from: peer))
        XCTAssertEqual(stopped.first?.1.stoppedNotice(from: "K0EPI-4"),
                       "The message from K0EPI-4 stopped after 1.0 of 3.0 KB, when the connection ended.")
    }
}
