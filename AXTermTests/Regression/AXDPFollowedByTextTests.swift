import XCTest
@testable import AXTerm

/// A line of plain text that follows an AXDP message in the same delivery.
///
/// At the home retest (2026-10-10) the mailbox declined the iPad's photo with
/// an AXDP NACK (I-frame 6) and explained why in a line of text (I-frame 7).
/// Frame 6 was lost; 7 arrived first and was held; when 6 came again AX.25
/// delivered 6 and then the held 7 in one pass. Completing the NACK set the
/// terminal's "suppress AXDP bytes" flag, which is cleared asynchronously,
/// so frame 7's text was thrown away with it and the operator never saw why.
@MainActor
final class AXDPFollowedByTextTests: XCTestCase {

    private func makeTerminal() -> (SessionCoordinator, ObservableTerminalTxViewModel, AX25Session) {
        let coordinator = SessionCoordinator()
        let settings = AppSettingsStore(defaults: TestDefaults.make("AXDPFollowedByText"))
        let viewModel = ObservableTerminalTxViewModel(
            client: PacketEngine(settings: settings), settings: settings,
            sourceCall: "K0EPI-3", sessionManager: coordinator.sessionManager)
        viewModel.setupSessionCallbacks()
        TerminalAXDPWiring.connect(coordinator, to: viewModel)
        let peer = AX25Address(call: "K0EPI", ssid: 4)
        let session = coordinator.sessionManager.session(for: peer)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        return (coordinator, viewModel, session)
    }

    /// One in-order delivery, as AX.25 hands it over: reassembly first, then
    /// the terminal, for the same bytes.
    private func deliver(_ data: Data, on session: AX25Session, _ coordinator: SessionCoordinator) {
        coordinator.sessionManager.onDataDeliveredForReassembly?(session, data)
        coordinator.sessionManager.onDataReceived?(session, data)
    }

    func testTextRightAfterAnAXDPMessageIsShown() {
        let (coordinator, viewModel, session) = makeTerminal()
        var lines: [String] = []
        viewModel.onPlainTextChatReceived = { _, text, _ in lines.append(text) }

        let nack = AXDP.Message(type: .nack, sessionId: 0xB8B9A2CB, messageId: 1).encode()
        let reason = Data("Photo.jpg was declined: this station does not accept uploads.\r>\r".utf8)
        deliver(nack, on: session, coordinator)
        deliver(reason, on: session, coordinator)   // same pass, before any async work

        XCTAssertTrue(lines.contains("Photo.jpg was declined: this station does not accept uploads."), "\(lines)")
    }

    /// AXDP bytes still never show as text, however the frames were cut.
    func testAnAXDPMessageSplitAcrossDeliveriesShowsNoBytes() {
        let (coordinator, viewModel, session) = makeTerminal()
        var lines: [String] = []
        viewModel.onPlainTextChatReceived = { _, text, _ in lines.append(text) }

        let meta = AXDP.Message(
            type: .fileMeta, sessionId: 9, messageId: 0, totalChunks: 3,
            fileMeta: AXDPFileMeta(filename: "a-file-name.bin", fileSize: 300,
                                   sha256: Data(repeating: 0xAB, count: 32), chunkSize: 128)).encode()
        deliver(meta.prefix(20), on: session, coordinator)
        deliver(meta.dropFirst(20), on: session, coordinator)
        deliver(Data("after\r".utf8), on: session, coordinator)

        XCTAssertEqual(lines, ["after"])
    }

    /// Text and an AXDP message in one delivery: the text shows, the message
    /// does not.
    func testTextAroundAnAXDPMessageInOneDelivery() {
        let (coordinator, viewModel, session) = makeTerminal()
        var lines: [String] = []
        viewModel.onPlainTextChatReceived = { _, text, _ in lines.append(text) }

        var data = Data("before\r".utf8)
        data.append(AXDP.Message(type: .pong, sessionId: 1, messageId: 2).encode())
        data.append(Data("after\r".utf8))
        deliver(data, on: session, coordinator)

        XCTAssertEqual(lines, ["before", "after"])
    }
}
