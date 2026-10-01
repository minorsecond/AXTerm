import XCTest
import GRDB
@testable import AXTerm

/// A text file typed out by the mailbox, saved at the calling station, and
/// the terminal's Capture switch.
///
/// Two stations, both real code from the session layer up. Station B is the
/// mailbox (`BBSService` over its coordinator's session manager), reached by
/// `BBSSimulatedCaller`. Every I-frame payload the caller takes delivery of is
/// handed, frame by frame, to station A's terminal model through the session
/// manager's own `onDataReceived` callback, the hook the terminal reads every
/// received byte from. Station A's coordinator is the place received files
/// are saved and listed, pointed at a temporary folder.
@MainActor
final class TextDownloadCaptureTests: XCTestCase {

    // Station B, the mailbox.
    private var root: URL!
    private var area: URL!
    private var store: SQLiteBBSMessageStore!
    private var settings: BBSSettings!
    private var coordinatorB: SessionCoordinator!
    private var library: BBSFileLibrary!
    private var service: BBSService!
    private var caller: BBSSimulatedCaller!

    // Station A, the caller.
    private var folderA: URL!
    private var coordinatorA: SessionCoordinator!
    private var terminal: ObservableTerminalTxViewModel!
    private var sessionA: AX25Session!

    private let mailboxAddress = AX25Address(call: "K0EPI", ssid: 2)
    private let callerAddress = AX25Address(call: "W0ARP", ssid: 1)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("text-download-\(UUID().uuidString)")
        area = root.appendingPathComponent("ops")
        folderA = root.appendingPathComponent("AXTerm Transfers")
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)

        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)
        settings = BBSSettings(defaults: TestDefaults.make("text-download-tests"))
        settings.onAir = true
        settings.callsign = "K0EPI-2"
        coordinatorB = SessionCoordinator()
        library = BBSFileLibrary(store: store)
        library.addArea(name: "OPS", about: "Nets", url: area)

        let appSettings = AppSettingsStore()
        let managerA = AX25SessionManager(localCallsign: callerAddress)
        terminal = ObservableTerminalTxViewModel(
            client: PacketEngine(settings: appSettings),
            settings: appSettings,
            sourceCall: "W0ARP-1",
            sessionManager: managerA)
        terminal.setupSessionCallbacks()
        coordinatorA = SessionCoordinator()
        coordinatorA.receivedFilesFolderOverride = folderA
        terminal.receivedTextSink = coordinatorA
        sessionA = connectedSession(to: mailboxAddress)
        terminal.setCurrentSession(sessionA)
    }

    override func tearDown() async throws {
        service?.shutdown(reason: "test over")
        service?.detach()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Harness

    private func connectedSession(to peer: AX25Address) -> AX25Session {
        let session = terminal.sessionManager.session(for: peer)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        return session
    }

    /// Station A receiving `bytes` on `session`, as the session layer hands them over.
    private func deliver(_ bytes: Data, on session: AX25Session? = nil) {
        terminal.sessionManager.onDataReceived?(session ?? sessionA, bytes)
    }

    private func deliver(_ text: String, on session: AX25Session? = nil) {
        deliver(Data(text.utf8), on: session)
    }

    /// The link to `session`'s station going down, as the session layer reports it.
    private func drop(_ session: AX25Session? = nil) async {
        terminal.sessionManager.onSessionStateChanged?(session ?? sessionA, .connected, .disconnected)
        // The terminal handles state changes on a main-actor task.
        for _ in 0..<50 { await Task.yield() }
    }

    /// Builds the mailbox, connects the caller, skips the first-call
    /// interview, and from then on passes everything B sends to A's terminal.
    private func connectToMailbox() async throws {
        let simulated = BBSSimulatedCaller(manager: coordinatorB.sessionManager,
                                           address: callerAddress, mailbox: mailboxAddress)
        caller = simulated
        coordinatorB.sessionManager.onSendFrame = { [weak simulated] frame in
            simulated?.outbox.append(frame)
        }
        service = BBSService(
            store: store,
            settings: settings,
            coordinator: coordinatorB,
            sendFrames: { [weak simulated] frames in simulated?.outbox.append(contentsOf: frames) },
            stationCallsign: { "K0EPI" },
            isWinlinkP2PArmed: { false },
            winlinkP2PCallsign: { "" },
            library: library,
            linkBytesPerSecond: { 1_000_000 })
        service.attach()
        caller.connect()
        let greeted = await caller.pump { self.caller.text.contains("not met you before") }
        XCTAssertTrue(greeted, caller.text)
        caller.type("A")
        let prompted = await caller.pump { self.caller.text.hasSuffix(">\r") }
        XCTAssertTrue(prompted, caller.text)
        caller.clearReceived()
        caller.onBytes = { [unowned self] bytes in self.deliver(bytes) }
    }

    @discardableResult
    private func command(_ line: String) async -> String {
        caller.clearReceived()
        caller.type(line)
        await caller.pump { self.caller.text.hasSuffix(">\r") }
        return caller.text
    }

    private func savedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folderA.path)) ?? []).sorted()
    }

    private func saved(_ name: String) -> Data? {
        try? Data(contentsOf: folderA.appendingPathComponent(name))
    }

    /// About 3 KB of the kind of text a file area holds.
    private func netScript() -> Data {
        let lines = (1...64).map { "\($0). Check-ins by suffix, then traffic, then the net closes." }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: - A marked download, end to end

    func testATextDownloadIsSavedByteIdenticalWithATransfersRow() async throws {
        let source = netScript()
        try source.write(to: area.appendingPathComponent("t3k_text.txt"))
        library.rescan()
        try await connectToMailbox()

        let reply = await command("D t3k_text.txt")
        XCTAssertTrue(reply.contains("--- BEGIN t3k_text.txt (\(source.count) bytes) ---"), reply)

        XCTAssertEqual(savedFiles(), ["t3k_text.txt"])
        XCTAssertEqual(saved("t3k_text.txt"), source, "byte for byte what the mailbox holds")

        XCTAssertEqual(coordinatorA.transfers.count, 1)
        let row = try XCTUnwrap(coordinatorA.transfers.first)
        XCTAssertEqual(row.fileName, "t3k_text.txt")
        XCTAssertEqual(row.direction, .inbound)
        XCTAssertEqual(row.transferProtocol, .text)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.fileSize, source.count)
        XCTAssertEqual(row.destination, "K0EPI-2")
        XCTAssertEqual(row.savedFilePath, folderA.appendingPathComponent("t3k_text.txt").path,
                       "the row's Quick Look, Show in Finder and Open act on this path")
    }

    func testTheLinesStillReachTheTranscript() async throws {
        try Data("Net at 1900\n".utf8).write(to: area.appendingPathComponent("n.txt"))
        library.rescan()
        try await connectToMailbox()
        var shown: [String] = []
        terminal.onPlainTextChatReceived = { _, line, _ in shown.append(line) }
        await command("D n.txt")
        XCTAssertTrue(shown.contains("--- BEGIN n.txt (12 bytes) ---"), "\(shown)")
        XCTAssertTrue(shown.contains("Net at 1900"), "\(shown)")
        XCTAssertTrue(shown.contains("--- END n.txt ---"), "\(shown)")
    }

    func testASecondCopyIsSavedBesideTheFirst() async throws {
        let source = netScript()
        try source.write(to: area.appendingPathComponent("t3k_text.txt"))
        library.rescan()
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try Data("last night's copy".utf8).write(to: folderA.appendingPathComponent("t3k_text.txt"))
        try await connectToMailbox()

        await command("D t3k_text.txt")
        XCTAssertEqual(savedFiles(), ["t3k_text 2.txt", "t3k_text.txt"])
        XCTAssertEqual(saved("t3k_text.txt"), Data("last night's copy".utf8), "never overwritten")
        XCTAssertEqual(saved("t3k_text 2.txt"), source)
        XCTAssertEqual(coordinatorA.transfers.first?.fileName, "t3k_text 2.txt")
    }

    func testAFileHoldingMarkerLikeLinesArrivesWhole() async throws {
        let source = Data("""
            Before.
            --- END tricky.txt ---
            --- BEGIN tricky.txt (5 bytes) ---

            After, with no final newline
            """.utf8)
        try source.write(to: area.appendingPathComponent("tricky.txt"))
        library.rescan()
        try await connectToMailbox()

        await command("D tricky.txt")
        XCTAssertEqual(saved("tricky.txt"), source)
        XCTAssertEqual(coordinatorA.transfers.map(\.status), [.completed])
    }

    func testAHostileNameIsSanitized() async throws {
        deliver("--- BEGIN ../../.ssh/authorized_keys (4 bytes) ---\rabc\r--- END ../../.ssh/authorized_keys ---\r")
        XCTAssertEqual(savedFiles(), ["authorized_keys"])
        XCTAssertEqual(saved("authorized_keys"), Data("abc\n".utf8))
    }

    // MARK: - When it does not all arrive

    func testACountMismatchSavesWhatArrivedMarkedIncomplete() async throws {
        deliver("--- BEGIN short.txt (40 bytes) ---\rabc\r--- END short.txt ---\r>\r")
        XCTAssertTrue(savedFiles().isEmpty, "nothing is decided while the count could still be met")
        deliver("next command's output\rand more, well past the count\r")

        XCTAssertEqual(savedFiles(), ["short (incomplete).txt"])
        XCTAssertEqual(saved("short (incomplete).txt"), Data("abc\n".utf8))
        let row = try XCTUnwrap(coordinatorA.transfers.first)
        XCTAssertEqual(row.transferProtocol, .text)
        guard case .failed(let reason) = row.status else {
            return XCTFail("an incomplete file is never shown as completed: \(row.status)")
        }
        XCTAssertTrue(reason.contains("4 of 40 bytes"), reason)
        XCTAssertNotNil(row.savedFilePath, "what did arrive can still be opened")
    }

    func testALinkThatDropsMidFileSavesWhatArrivedMarkedIncomplete() async throws {
        deliver("--- BEGIN drop.txt (100 bytes) ---\rfirst line\rsecond")
        XCTAssertTrue(savedFiles().isEmpty)
        await drop()

        XCTAssertEqual(savedFiles(), ["drop (incomplete).txt"])
        XCTAssertEqual(saved("drop (incomplete).txt"), Data("first line\nsecond\n".utf8))
        guard case .failed(let reason) = coordinatorA.transfers.first?.status else {
            return XCTFail("shown as failed")
        }
        XCTAssertTrue(reason.contains("link"), reason)
    }

    func testALinkThatDropsRightAfterTheBeginSavesNothing() async throws {
        deliver("--- BEGIN empty.txt (100 bytes) ---\r")
        await drop()
        XCTAssertTrue(savedFiles().isEmpty)
        XCTAssertTrue(coordinatorA.transfers.isEmpty)
    }

    func testTwoStationsInterleavingDoNotMix() async throws {
        let other = AX25Address(call: "N0DEF", ssid: 3)
        let otherSession = connectedSession(to: other)
        let a = Data("alpha one\nalpha two\nalpha three\n".utf8)
        let b = Data("bravo one\nbravo two\n".utf8)
        let aLines = TextDownloadMarkers.markedLines(name: "a.txt", data: a)
        let bLines = TextDownloadMarkers.markedLines(name: "b.txt", data: b)

        // Line by line, alternating, with one line split across two frames.
        deliver(aLines[0] + "\r")
        deliver(bLines[0] + "\r", on: otherSession)
        deliver("alpha ")
        deliver(bLines[1] + "\r", on: otherSession)
        deliver("one\r")
        for line in aLines.dropFirst(2) { deliver(line + "\r") }
        for line in bLines.dropFirst(2) { deliver(line + "\r", on: otherSession) }

        XCTAssertEqual(saved("a.txt"), a)
        XCTAssertEqual(saved("b.txt"), b)
        XCTAssertEqual(Set(coordinatorA.transfers.map(\.destination)), ["K0EPI-2", "N0DEF-3"])
    }

    // MARK: - Capture

    func testCaptureSavesWhatTheStationSentWhileItWasOn() async throws {
        deliver("before capture\r")
        XCTAssertFalse(terminal.isCapturingCurrentSession)
        let before = Date()
        terminal.toggleCapture()
        let after = Date()
        XCTAssertTrue(terminal.isCapturingCurrentSession)

        deliver("Welcome to the mailbox\r\r")
        // An AXDP envelope is protocol, not something the station typed.
        deliver(AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode())
        terminal.clearAXDPReassemblyFlag(for: mailboxAddress)
        deliver("partial ")
        deliver("line\r\n")
        deliver("someone else\r", on: connectedSession(to: AX25Address(call: "N0DEF", ssid: 3)))

        let report = try XCTUnwrap(terminal.toggleCapture())
        XCTAssertFalse(terminal.isCapturingCurrentSession)
        deliver("after capture\r")

        let names = savedFiles()
        XCTAssertEqual(names.count, 1, "\(names)")
        let name = try XCTUnwrap(names.first)
        XCTAssertTrue(name.hasPrefix("K0EPI-2 ") && name.hasSuffix(".txt"), name)
        let expected = Set([before, after].map {
            SessionCapture.fileName(peer: "K0EPI-2", startedAt: $0, timeZone: .current)
        })
        XCTAssertTrue(expected.contains(name), "named from the station and the time the capture began: \(name)")
        XCTAssertEqual(saved(name), Data("Welcome to the mailbox\n\npartial line\n".utf8),
                       "the station's lines only: no AXDP envelope, no other station, nothing before or after")
        XCTAssertTrue(report.notice.contains(name), report.notice)
        XCTAssertTrue(report.notice.contains(ReceivedFileStore.folderName), report.notice)

        let row = try XCTUnwrap(coordinatorA.transfers.first)
        XCTAssertEqual(row.fileName, name)
        XCTAssertEqual(row.transferProtocol, .text)
        XCTAssertEqual(row.status, .completed)
    }

    func testCaptureStopsAndSavesWhenTheSessionEnds() async throws {
        terminal.toggleCapture()
        deliver("73, going QRT\r")
        await drop()
        XCTAssertFalse(terminal.isCapturing(peer: "K0EPI-2"))
        XCTAssertEqual(savedFiles().count, 1)
        XCTAssertEqual(savedFiles().first.flatMap { saved($0) }, Data("73, going QRT\n".utf8))
    }

    func testACaptureOfNothingSavesNoFileAndSaysSo() async throws {
        terminal.toggleCapture()
        let report = try XCTUnwrap(terminal.toggleCapture())
        XCTAssertTrue(savedFiles().isEmpty)
        XCTAssertTrue(coordinatorA.transfers.isEmpty)
        XCTAssertTrue(report.notice.contains("nothing"), report.notice)
    }

    func testCaptureIsPerSession() async throws {
        let other = connectedSession(to: AX25Address(call: "N0DEF", ssid: 3))
        terminal.toggleCapture()
        XCTAssertTrue(terminal.isCapturing(peer: "K0EPI-2"))
        XCTAssertFalse(terminal.isCapturing(peer: "N0DEF-3"))
        await drop(other)
        XCTAssertTrue(terminal.isCapturing(peer: "K0EPI-2"), "another link ending leaves this capture running")
    }

    func testCaptureAndAMarkedDownloadBothKeepTheText() async throws {
        terminal.toggleCapture()
        let marked = TextDownloadMarkers.markedLines(name: "n.txt", data: Data("Net at 1900\n".utf8))
        deliver(marked.joined(separator: "\r") + "\r")
        terminal.toggleCapture()
        XCTAssertEqual(saved("n.txt"), Data("Net at 1900\n".utf8))
        let capture = try XCTUnwrap(savedFiles().first { $0.hasPrefix("K0EPI-2 ") })
        XCTAssertEqual(saved(capture), Data((marked.joined(separator: "\n") + "\n").utf8))
    }
}
