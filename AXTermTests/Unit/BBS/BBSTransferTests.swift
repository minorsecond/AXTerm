import XCTest
import Combine
import GRDB
@testable import AXTerm

/// The mailbox's file area driven end to end: a simulated caller connects
/// over the real session layer, lists, downloads text and binaries, uploads,
/// and every way a transfer can end leaves the mailbox ready for the next
/// command.
///
/// Binaries are checked byte for byte at a real receiver (`YAPPProtocol`'s
/// own receive side), and every transfer runs over 128-byte I-frames, so a
/// 254-byte YAPP block always arrives in two pieces.
@MainActor
final class BBSTransferTests: XCTestCase {

    private var root: URL!
    private var area: URL!
    private var inbox: URL!
    private var store: SQLiteBBSMessageStore!
    private var settings: BBSSettings!
    private var coordinator: SessionCoordinator!
    private var library: BBSFileLibrary!
    private var service: BBSService!
    private var caller: BBSSimulatedCaller!

    /// Small, so "just under the cap" is a file a test can move quickly.
    private let cap = 64 * 1024
    private let mailboxAddress = AX25Address(call: "K0EPI", ssid: 2)
    private let callerAddress = AX25Address(call: "W0ARP", ssid: 1)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbs-transfer-\(UUID().uuidString)")
        area = root.appendingPathComponent("ops")
        inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)

        settings = BBSSettings(defaults: TestDefaults.make("bbs-transfer-tests"))
        settings.onAir = true
        settings.callsign = "K0EPI-2"
        settings.acceptUploads = false

        coordinator = SessionCoordinator()
        library = BBSFileLibrary(store: store, maxFileBytes: cap)
        try Data("Tuesday net preamble\nCheck-ins by suffix\n".utf8)
            .write(to: area.appendingPathComponent("notes.txt"))
        library.addArea(name: "OPS", about: "Nets", url: area)
    }

    override func tearDown() async throws {
        service?.shutdown(reason: "test over")
        service?.detach()
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds the mailbox, connects the caller, and skips the first-call
    /// interview the way an uninterested caller would, with `A`.
    private func connect(stallTimeout: TimeInterval = 180) async throws {
        if service == nil {
            let simulated = BBSSimulatedCaller(manager: coordinator.sessionManager,
                                               address: callerAddress,
                                               mailbox: mailboxAddress)
            caller = simulated
            // Frames the session layer releases on its own (a queue drained
            // by an acknowledgment) reach the radio here.
            coordinator.sessionManager.onSendFrame = { [weak simulated] frame in
                simulated?.outbox.append(frame)
            }
            service = BBSService(
                store: store,
                settings: settings,
                coordinator: coordinator,
                sendFrames: { [weak simulated] frames in
                    simulated?.outbox.append(contentsOf: frames)
                },
                stationCallsign: { "K0EPI" },
                isWinlinkP2PArmed: { false },
                winlinkP2PCallsign: { "" },
                library: library,
                transferStallTimeout: stallTimeout,
                // Fast enough that no file here trips the long-transfer
                // confirmation; that has its own shell tests.
                linkBytesPerSecond: { 1_000_000 })
            service.attach()
        }
        caller.onBytes = nil
        caller.clearReceived()
        caller.connect()
        let greeted = await caller.pump { self.caller.text.contains("not met you before") }
        XCTAssertTrue(greeted, "the mailbox answered: \(caller.text)")
        caller.type("A")
        let prompted = await caller.pump { self.caller.text.hasSuffix(">\r") }
        XCTAssertTrue(prompted, "at the prompt: \(caller.text)")
        caller.clearReceived()
    }

    /// Types a command and waits for the prompt after its answer.
    @discardableResult
    private func command(_ line: String) async -> String {
        caller.clearReceived()
        caller.type(line)
        await caller.pump { self.caller.text.hasSuffix(">\r") }
        return caller.text
    }

    private func writeFile(_ name: String, bytes: Data, in folder: URL? = nil) throws {
        try bytes.write(to: (folder ?? area).appendingPathComponent(name))
    }

    /// Bytes that exercise the framing: every value, YAPP control bytes
    /// included, in a pattern that is not periodic at the block size.
    private func binary(_ count: Int, seed: UInt32 = 7) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        })
    }

    /// Downloads `name` into a fresh YAPP receiver and returns it.
    private func download(_ name: String) async -> CallerYAPPReceiver {
        let receiver = CallerYAPPReceiver()
        caller.clearReceived()
        caller.onBytes = { [unowned self] bytes in
            receiver.consume(bytes)
            self.caller.pendingSends.append(contentsOf: receiver.toSend)
            receiver.toSend.removeAll()
        }
        caller.type("D \(name)")
        await caller.pump { receiver.completed != nil && receiver.textString.hasSuffix(">\r") }
        caller.onBytes = nil
        return receiver
    }

    private func assertIdle(_ message: String = "", file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertFalse(service.isTransferring, "no transfer holds the session \(message)",
                       file: file, line: line)
        XCTAssertNil(service.transfer, "nothing shown as running \(message)",
                     file: file, line: line)
    }

    // MARK: - Listing and text

    func testACallerListsAreasAndFiles() async throws {
        try writeFile("roster.bin", bytes: binary(3000))
        library.rescan()
        try await connect()

        let areas = await command("W")
        XCTAssertTrue(areas.contains("OPS"), areas)
        let files = await command("W OPS")
        XCTAssertTrue(files.contains("notes.txt"), files)
        XCTAssertTrue(files.contains("roster.bin"), files)
    }

    func testATextFileIsTypedOutInOrderWithThePromptLast() async throws {
        try await connect()
        let reply = await command("D notes.txt")

        let announce = try XCTUnwrap(reply.range(of: "notes.txt is text"))
        let start = try XCTUnwrap(reply.range(of: "--- BEGIN notes.txt (41 bytes) ---\r"), reply)
        let body = try XCTUnwrap(reply.range(of: "Check-ins by suffix"))
        let end = try XCTUnwrap(reply.range(of: "--- END notes.txt ---\r"), reply)
        XCTAssertTrue(announce.lowerBound < start.lowerBound
                      && start.lowerBound < body.lowerBound
                      && body.lowerBound < end.lowerBound,
                      "the announcement comes before the file, not after it: \(reply)")
        XCTAssertTrue(reply.hasSuffix(">\r"))
        assertIdle()
    }

    /// The marker lines carry the exact count of the text between them, with
    /// each CR the mailbox sends standing for one LF in the caller's copy.
    func testTheMarkersCarryTheExactCountOfWhatIsBetweenThem() async throws {
        try writeFile("crlf.txt", bytes: Data("one\r\n\r\nthree\r\nno newline".utf8))
        library.rescan()
        try await connect()
        let reply = await command("D crlf.txt")

        let start = try XCTUnwrap(reply.range(of: "--- BEGIN crlf.txt (21 bytes) ---\r"), reply)
        let end = try XCTUnwrap(reply.range(of: "--- END crlf.txt ---\r"), reply)
        let between = String(reply[start.upperBound..<end.lowerBound])
        XCTAssertEqual(between, "one\r\rthree\rno newline\r",
                       "CRLF goes out as one CR and blank lines are kept")
        XCTAssertEqual(between.utf8.count, 21 + 1,
                       "one CR per line; the count is one less because the file has no final newline")
    }

    /// A line in the file that looks like the end marker goes out as it is:
    /// the count, not the marker, says where the file ends.
    func testAFileHoldingAMarkerLikeLineIsSentUnchanged() async throws {
        try writeFile("tricky.txt", bytes: Data("a\n--- END tricky.txt ---\nb\n".utf8))
        library.rescan()
        try await connect()
        let reply = await command("D tricky.txt")
        XCTAssertTrue(reply.contains("--- BEGIN tricky.txt (27 bytes) ---\r"
                                     + "a\r--- END tricky.txt ---\rb\r--- END tricky.txt ---\r"),
                      reply)
    }

    /// A reply is one batch: the lines are packed into I-frames up to the
    /// paclen instead of costing a frame header each.
    func testATypedOutFileIsPackedIntoFewerFramesThanLines() async throws {
        let lines = (1...40).map { String(format: "Line %02d of the net script, padded out a bit.", $0) }
        let source = lines.joined(separator: "\n") + "\n"
        try writeFile("script.txt", bytes: Data(source.utf8))
        library.rescan()
        try await connect()

        var frames = 0
        caller.onBytes = { _ in frames += 1 }
        let reply = await command("D script.txt")
        caller.onBytes = nil

        XCTAssertTrue(reply.contains(lines.joined(separator: "\r") + "\r--- END script.txt ---\r"), reply)
        XCTAssertLessThan(frames, lines.count / 2,
                          "\(frames) frames for \(lines.count) lines: one frame per line would waste a header each")
    }

    // MARK: - Binary downloads

    func testBinaryDownloadsArriveByteIdenticalAtEverySize() async throws {
        // Around the 250-byte block, a multi-block file, and one byte under
        // the library's cap. Each one is a fresh D in the same call, so this
        // also proves the mailbox is ready again after every success.
        let sizes = [1, 249, 250, 251, 500, 4096 + 17, cap - 1]
        for (index, size) in sizes.enumerated() {
            try writeFile("file\(index).bin", bytes: binary(size, seed: UInt32(index + 1)))
        }
        library.rescan()
        try await connect()

        for (index, size) in sizes.enumerated() {
            let receiver = await download("file\(index).bin")
            XCTAssertEqual(receiver.completed, true, "size \(size): \(receiver.textString)")
            XCTAssertEqual(receiver.file?.count, size, "size \(size)")
            XCTAssertEqual(receiver.file, binary(size, seed: UInt32(index + 1)),
                           "size \(size) arrives byte for byte")
            XCTAssertEqual(receiver.metadata?.fileName, "file\(index).bin")
            XCTAssertTrue(receiver.textString.contains("Sending file\(index).bin"))
            XCTAssertTrue(receiver.textString.contains("file\(index).bin sent."),
                          receiver.textString)
            assertIdle("after \(size) bytes")
        }
    }

    func testAnEmptyFileIsNeitherListedNorSent() async throws {
        try writeFile("empty.bin", bytes: Data())
        try writeFile("shrinks.bin", bytes: binary(10))
        library.rescan()
        XCTAssertNil(library.index.files.first { $0.name == "empty.bin" },
                     "a zero-byte file is not offered")
        try await connect()

        // Emptied between the scan and the D: YAPP would send a header and
        // wait forever for a first block.
        try writeFile("shrinks.bin", bytes: Data())
        let reply = await command("D shrinks.bin")
        XCTAssertTrue(reply.contains("shrinks.bin is empty, so there is nothing to send."), reply)
        assertIdle()

        let next = await command("D notes.txt")
        XCTAssertTrue(next.contains("Check-ins by suffix"), "the next command works")
    }

    // MARK: - Every way a transfer ends

    func testAReceiverThatRefusesEndsTheTransferAndTheNextDownloadWorks() async throws {
        try writeFile("a.bin", bytes: binary(600))
        library.rescan()
        try await connect()

        let receiver = CallerYAPPReceiver()
        receiver.accepts = false
        caller.onBytes = { [unowned self] bytes in
            receiver.consume(bytes)
            self.caller.pendingSends.append(contentsOf: receiver.toSend)
            receiver.toSend.removeAll()
        }
        caller.type("D a.bin")
        await caller.pump { self.caller.text.contains("was not sent") && self.caller.text.hasSuffix(">\r") }
        // YAPP refuses with NR and its reason ("no" from this receiver).
        XCTAssertTrue(caller.text.contains("a.bin was not sent: The other station refused the file: no."),
                      caller.text)
        assertIdle()

        let again = await download("a.bin")
        XCTAssertEqual(again.file, binary(600), "a second D after a failure works")
        assertIdle()
    }

    func testTypingAStopsADownloadForACallerWithoutYAPP() async throws {
        try writeFile("a.bin", bytes: binary(600))
        library.rescan()
        try await connect()

        caller.clearReceived()
        caller.type("D a.bin")
        // The send-init arrives as noise to a caller with no YAPP.
        await caller.pump { self.caller.received.contains(YAPPControlChar.enq.rawValue) }
        XCTAssertTrue(service.isTransferring)
        XCTAssertEqual(service.transfer?.fileName, "a.bin")

        caller.type("A")
        await caller.pump { self.caller.text.hasSuffix(">\r") }
        XCTAssertTrue(caller.text.contains("Stopped."), caller.text)
        XCTAssertTrue(caller.received.contains(YAPPControlChar.can.rawValue),
                      "the caller's software is told with a CAN")
        assertIdle()

        let again = await download("a.bin")
        XCTAssertEqual(again.file, binary(600))
    }

    func testTheSysopCanStopATransfer() async throws {
        try writeFile("a.bin", bytes: binary(600))
        library.rescan()
        try await connect()

        caller.type("D a.bin")
        await caller.pump { self.service.isTransferring }
        service.sysopStopTransfer()
        await caller.pump { self.caller.text.hasSuffix(">\r") }
        XCTAssertTrue(caller.text.contains("The sysop stopped the transfer."), caller.text)
        assertIdle()

        let again = await download("a.bin")
        XCTAssertEqual(again.file, binary(600))
    }

    func testAStalledTransferTimesOutAndTheNextDownloadWorks() async throws {
        try writeFile("a.bin", bytes: binary(600))
        library.rescan()
        try await connect(stallTimeout: 0.3)

        caller.type("D a.bin")
        // Nobody answers the send-init.
        let stopped = await caller.pump(timeout: 5) {
            self.caller.text.contains("nothing was heard from you")
        }
        XCTAssertTrue(stopped, caller.text)
        XCTAssertTrue(caller.text.contains("The transfer stopped: nothing was heard from you "
                                           + "for 1 second."), caller.text)
        assertIdle()

        let again = await download("a.bin")
        XCTAssertEqual(again.file, binary(600))
    }

    func testADisconnectMidTransferClearsItAndNothingDialsTheCallerBack() async throws {
        try writeFile("a.bin", bytes: binary(5000))
        library.rescan()
        try await connect()

        caller.type("D a.bin")
        await caller.pump { self.service.isTransferring }
        caller.drain()
        caller.disconnect()
        await caller.pump { self.service.live == nil }
        assertIdle("after the link dropped")
        XCTAssertNil(service.live)

        // Anything addressed to the caller now would be the mailbox trying
        // to reach a station that left.
        let sabm = caller.outbox.filter { $0.displayInfo?.hasPrefix("SABM") == true }
        XCTAssertTrue(sabm.isEmpty, "the mailbox never calls a caller back")

        try await connect()
        let again = await download("a.bin")
        XCTAssertEqual(again.file, binary(5000), "a new call downloads normally")
    }

    // MARK: - Uploads

    private func enableUploads() {
        settings.acceptUploads = true
        settings.maxUploadBytes = 100 * 1024
        library.setInbox(url: inbox)
    }

    /// Types `U` and waits for the go-ahead, which ends without a prompt:
    /// the caller is not at one while the mailbox waits for their upload.
    private func armUpload() async {
        caller.clearReceived()
        caller.type("U")
        await caller.pump { self.caller.text.hasSuffix("upload now.\r") }
        XCTAssertTrue(caller.text.hasSuffix("Ready — start your upload now.\r"), caller.text)
    }

    /// Runs a YAPP upload from the caller and waits for the prompt after it.
    private func upload(_ name: String, _ data: Data) async throws -> CallerYAPPSender {
        await armUpload()

        let sender = CallerYAPPSender()
        caller.clearReceived()
        caller.onBytes = { [unowned self] bytes in
            sender.consume(bytes)
            self.caller.pendingSends.append(contentsOf: sender.toSend)
            sender.toSend.removeAll()
        }
        try sender.driver.startSending(fileName: name, fileData: data)
        caller.pendingSends.append(contentsOf: sender.toSend)
        sender.toSend.removeAll()
        await caller.pump { sender.completed != nil && sender.textString.hasSuffix(">\r") }
        caller.onBytes = nil
        return sender
    }

    private func inboxFile(_ name: String) -> Data? {
        try? Data(contentsOf: inbox.appendingPathComponent(name))
    }

    func testAYAPPUploadLandsInTheInboxByteForByte() async throws {
        enableUploads()
        try await connect()

        for (index, size) in [1, 300, 5000].enumerated() {
            let data = binary(size, seed: UInt32(40 + index))
            let sender = try await upload("up\(index).bin", data)
            XCTAssertEqual(sender.completed, true, sender.textString)
            XCTAssertTrue(sender.textString.contains("Received up\(index).bin"), sender.textString)
            XCTAssertEqual(inboxFile("up\(index).bin"), data, "size \(size)")
            assertIdle("after uploading \(size) bytes")
        }
        XCTAssertNil(library.index.files.first { $0.name.hasPrefix("up") },
                     "uploads are never served")
    }

    /// The confirmation waits until YAPP is done. On 2026-10-01 the mailbox
    /// wrote "Received ..." the moment it acknowledged end of file, while
    /// the caller's AXTerm was waiting for the acknowledgment of end of
    /// transmission. AXTerm hands everything to its YAPP driver until the
    /// transfer ends, so it read the line as a protocol error and marked a
    /// file that had arrived intact as failed.
    func testTheUploadIsConfirmedOnlyAfterTheYAPPExchangeEnds() async throws {
        enableUploads()
        try await connect()

        let sender = try await upload("order.bin", binary(300, seed: 7))
        let raw = sender.raw
        let ackEndTransmission = try XCTUnwrap(raw.range(of: Data([0x06, 0x04])),
                                               "the mailbox never acknowledged end of transmission")
        let confirmation = try XCTUnwrap(raw.range(of: Data("Received order.bin".utf8)))
        XCTAssertLessThan(ackEndTransmission.lowerBound, confirmation.lowerBound,
                          "the confirmation went out in the middle of the YAPP handshake")
    }

    func testAnUploadNeverReplacesAFileAlreadyInTheInbox() async throws {
        enableUploads()
        try Data("the operator's".utf8).write(to: inbox.appendingPathComponent("report.txt"))
        library.refreshInbox()
        try await connect()

        let sender = try await upload("REPORT.TXT", Data("from a caller".utf8))
        XCTAssertTrue(sender.textString.contains("Received REPORT-2.TXT"), sender.textString)
        XCTAssertEqual(inboxFile("report.txt"), Data("the operator's".utf8))
        XCTAssertEqual(inboxFile("REPORT-2.TXT"), Data("from a caller".utf8))
    }

    func testAPathInTheUploadNameCannotEscapeTheInbox() async throws {
        enableUploads()
        try await connect()

        let sender = try await upload("../../escape.sh", Data("echo hi".utf8))
        XCTAssertTrue(sender.textString.contains("Received escape.sh"), sender.textString)
        XCTAssertEqual(inboxFile("escape.sh"), Data("echo hi".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("escape.sh").path))

        let dots = try await upload("..", Data("x".utf8))
        XCTAssertTrue(dots.textString.contains("Upload refused — that filename cannot be used here."),
                      dots.textString)
        assertIdle()
    }

    func testAnUploadOverTheLimitIsRefusedFromItsHeader() async throws {
        enableUploads()
        settings.maxUploadBytes = 1024
        try await connect()

        let sender = try await upload("big.bin", binary(4096))
        XCTAssertEqual(sender.completed, false, "the caller's software is told with a CAN")
        XCTAssertTrue(sender.textString.contains("Upload refused — too large"), sender.textString)
        XCTAssertNil(inboxFile("big.bin"))
        assertIdle()

        let small = try await upload("small.bin", binary(100))
        XCTAssertEqual(inboxFile("small.bin"), binary(100), "the next upload works")
    }

    func testUploadsSwitchedOffAreRefusedBeforeTheCallerSendsAnything() async throws {
        try await connect()
        let reply = await command("U")
        XCTAssertTrue(reply.contains("Sorry — this station does not accept uploads."), reply)
        XCTAssertFalse(reply.contains("Ready"), "not told to start and then that they cannot")
        XCTAssertTrue(reply.hasSuffix(">\r"))
    }

    func testAnUploadLargerThanItsHeaderIsStopped() async throws {
        enableUploads()
        try await connect()
        await armUpload()

        // A hand-built sender that promises 10 bytes and sends 200.
        caller.clearReceived()
        caller.send(YAPPEncoder.sendInit())
        await caller.pump { self.caller.received.count >= 2 }      // RR
        caller.send(YAPPEncoder.header(name: "liar.bin", size: 10))
        await caller.pump { self.caller.received.count >= 4 }      // RF
        caller.send(YAPPEncoder.data(binary(200), checksum: false))
        await caller.pump { self.caller.text.hasSuffix(">\r") }

        XCTAssertTrue(caller.text.contains("The upload was larger than its header said"),
                      caller.text)
        XCTAssertNil(inboxFile("liar.bin"))
        assertIdle()
    }

    func testAFreshUploadAfterUAndThenACommandIsJustACommand() async throws {
        try await connect()
        enableUploads()
        await armUpload()
        let listing = await command("W")
        XCTAssertTrue(listing.contains("OPS"), "a caller who typed instead gets an answer")
        assertIdle()
    }

    // MARK: - AXDP from an AXTerm caller

    private func fileMeta(session: UInt32, name: String) -> Data {
        AXDP.Message(
            type: .fileMeta, sessionId: session, messageId: 0, totalChunks: 3,
            fileMeta: AXDPFileMeta(filename: name, fileSize: 300,
                                   sha256: Data(repeating: 0xAB, count: 32), chunkSize: 128)
        ).encode()
    }

    /// The first AXDP message in what the caller received, if any.
    private func axdpReply() -> AXDP.Message? {
        guard let start = caller.received.range(of: AXDP.magic)?.lowerBound else { return nil }
        return AXDP.Message.decodeMessage(from: caller.received.subdata(
            in: start..<caller.received.endIndex))
    }

    func testAnAXDPUploadIsDeclinedWithTheNACKAXTermUnderstands() async throws {
        enableUploads()
        try await connect()
        await armUpload()

        caller.clearReceived()
        caller.send(fileMeta(session: 0xC0FFEE, name: "photo.jpg"))
        await caller.pump { self.caller.text.hasSuffix(">\r") }

        let nack = try XCTUnwrap(axdpReply(), "an AXDP reply arrived")
        XCTAssertEqual(nack.type, .nack)
        XCTAssertEqual(nack.sessionId, 0xC0FFEE, "matched to the offer")
        XCTAssertEqual(nack.messageId, 1, "the decline form, as declineIncomingTransfer sends")
        XCTAssertTrue(caller.text.contains("takes uploads by YAPP only, so photo.jpg was declined"),
                      caller.text)
        assertIdle()

        let next = await command("W")
        XCTAssertTrue(next.contains("OPS"), "the mailbox is at its prompt again")
    }

    func testAnAXDPOfferWithoutUIsStillDeclinedAndMayArriveInPieces() async throws {
        try await connect()
        let meta = fileMeta(session: 42, name: "a-long-file-name-for-splitting.bin")
        caller.clearReceived()
        caller.send(meta.prefix(20))
        caller.drain()
        XCTAssertNil(axdpReply(), "nothing is said about half a message")
        caller.send(meta.dropFirst(20))
        await caller.pump { self.caller.text.hasSuffix(">\r") }

        XCTAssertEqual(axdpReply()?.sessionId, 42)
        XCTAssertEqual(caller.text.components(separatedBy: "was declined").count - 1, 1,
                       "declined once, not once per fragment")
    }

    func testAnAXDPChatLineIsReadAsATypedCommand() async throws {
        try await connect()
        caller.clearReceived()
        caller.send(AXDP.Message(type: .chat, sessionId: 0, messageId: 9,
                                 payload: Data("W".utf8)).encode())
        await caller.pump { self.caller.text.hasSuffix(">\r") }
        XCTAssertTrue(caller.text.contains("OPS"), caller.text)
    }

    // MARK: - What the operator sees

    func testTheOperatorSeesWhoWhatAndHowFar() async throws {
        try writeFile("a.bin", bytes: binary(2000))
        library.rescan()
        try await connect()

        let receiver = CallerYAPPReceiver()
        var seen: [BBSService.TransferStatus] = []
        let watch = service.$transfer.sink { if let status = $0 { seen.append(status) } }
        defer { watch.cancel() }
        caller.onBytes = { [unowned self] bytes in
            receiver.consume(bytes)
            self.caller.pendingSends.append(contentsOf: receiver.toSend)
            receiver.toSend.removeAll()
        }
        caller.type("D a.bin")
        await caller.pump { receiver.completed != nil }

        let first = try XCTUnwrap(seen.first)
        XCTAssertEqual(first.caller, "W0ARP-1")
        XCTAssertEqual(first.fileName, "a.bin")
        XCTAssertEqual(first.direction, .download)
        XCTAssertEqual(first.totalBytes, 2000)
        XCTAssertEqual(first.protocolName, "YAPP")
        XCTAssertEqual(seen.map(\.bytesDone).max(), 2000, "progress reached the end")
        XCTAssertEqual(seen.map(\.bytesDone), seen.map(\.bytesDone).sorted(),
                       "progress only moves forward")
        assertIdle()
    }
}
