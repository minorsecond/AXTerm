//
//  TwoStationTransferTests.swift
//  AXTermTests
//
//  Two whole stations, each a real PacketEngine and SessionCoordinator,
//  joined by an in-memory KISS link. Everything between "Send" and the file
//  on disk is the production code: KISS framing, AX.25 connected mode with
//  its window and acks, AXDP or YAPP on top, the offer rules, the save.
//  Only the radio is fake, and it can be cut to test a lost link.
//
//  Nothing here transmits: the link carries bytes from one engine's memory
//  to the other's.
//

import XCTest
@testable import AXTerm

// MARK: - The fake radio

/// Two of these make a channel. Bytes one sends arrive at the other on the
/// next turn of the main run loop, the way a real link hands them over.
@MainActor
final class CrossKISSLink: KISSLink {
    private(set) var state: KISSLinkState = .disconnected
    weak var delegate: KISSLinkDelegate?
    weak var peer: CrossKISSLink?
    /// Radio silence: frames sent while this is set never arrive.
    var silenced = false
    private(set) var framesSent = 0

    var endpointDescription: String { "in-memory" }

    func open() {
        state = .connected
        delegate?.linkDidChangeState(.connected)
    }

    func close() {
        state = .disconnected
        delegate?.linkDidChangeState(.disconnected)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        framesSent += 1
        completion(nil)
        guard !silenced else { return }
        DispatchQueue.main.async { [weak peer] in
            guard let peer, !peer.silenced else { return }
            peer.delegate?.linkDidReceive(data)
        }
    }
}

/// Collects transfer notifications instead of posting them.
final class RecordingTransferNotifications: NotificationScheduling {
    private(set) var events: [TransferNotificationEvent] = []
    func scheduleWatchNotification(packet: Packet, match: WatchMatch) {}
    func scheduleMailNotification(packet: Packet) {}
    func scheduleMentionNotification(packet: Packet) {}
    func scheduleConnectionNotification(callsign: String) {}
    func scheduleTransferNotification(_ event: TransferNotificationEvent) { events.append(event) }
}

/// One station: settings, engine, coordinator, link, and a folder of its own
/// for received files.
@MainActor
final class TransferStation {
    let callsign: String
    let address: AX25Address
    let settings: AppSettingsStore
    let engine: PacketEngine
    let coordinator: SessionCoordinator
    let link: CrossKISSLink
    let folder: URL
    let notifications = RecordingTransferNotifications()
    /// Text the terminal would have shown.
    private(set) var terminalText = Data()

    init(callsign: String) {
        self.callsign = callsign
        self.address = CallsignNormalizer.toAddress(callsign)
        let defaults = TestDefaults.make("TwoStation-\(callsign)")
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        settings = AppSettingsStore(defaults: defaults)
        settings.adoptStationCallsign(callsign)
        // Pointed nowhere; the link factory below is what actually carries
        // the bytes, so nothing reaches a real TNC.
        settings.updateRadio(settings.radios[0].id) {
            $0.enabled = true
            $0.host = "127.0.0.1"
            $0.port = 9
        }
        let link = CrossKISSLink()
        self.link = link
        engine = PacketEngine(settings: settings, notificationScheduler: notifications,
                              linkFactory: { _ in link })
        coordinator = SessionCoordinator()
        coordinator.localCallsign = callsign
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: engine)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoStation-\(callsign)-\(UUID().uuidString)", isDirectory: true)
        coordinator.receivedFilesFolderOverride = folder

        // Quick timers, so a lost link is noticed in seconds, not minutes.
        let fast = AX25SessionConfig(windowSize: 4, paclen: 128, maxRetries: 3,
                                     rtoMin: 0.3, rtoMax: 0.8, initialRto: 0.5,
                                     t2AckDelay: 0.1, adaptiveTimeout: false)
        coordinator.sessionManager.getConfigForDestination = { _, _, _ in fast }
        coordinator.sessionManager.defaultConfig = fast
        // No radio key-up to floor T1 with (spec 7.3): the link here is in memory.
        coordinator.sessionManager.keyUpSeconds = nil
        coordinator.adaptiveTransmissionEnabled = false
        coordinator.transferWatchdogInterval = 0.2
        coordinator.yappResponseTimeout = 10

        coordinator.sessionManager.onDataReceived = { [weak self] _, data in
            self?.terminalText.append(data)
        }
    }

    func connectLink(to other: TransferStation) {
        link.peer = other.link
        engine.connectUsingSettings()
    }

    var session: AX25Session? { coordinator.connectedSessions.first }

    func transfer(named name: String) -> BulkTransfer? {
        coordinator.transfers.last { $0.fileName == name }
    }

    func savedData(_ transfer: BulkTransfer?) -> Data? {
        transfer?.savedFilePath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    func tearDown() {
        coordinator.transferWatchdogTask?.cancel()
        try? FileManager.default.removeItem(at: folder)
    }
}

// MARK: - Tests

private struct WaitTimeout: Error {
    let what: String
}

@MainActor
final class TwoStationTransferTests: XCTestCase {

    private var a: TransferStation!
    private var b: TransferStation!

    override func setUp() async throws {
        a = TransferStation(callsign: "K0AAA-1")
        b = TransferStation(callsign: "K0BBB-2")
        a.connectLink(to: b)
        b.connectLink(to: a)
        XCTAssertEqual(a.engine.status, .connected)
        XCTAssertEqual(b.engine.status, .connected)
        try await connect()
        // AXTerm to AXTerm: each has heard the other speak AXDP.
        a.coordinator.markImplicitlyConfirmedAXDP(for: b.callsign)
        b.coordinator.markImplicitlyConfirmedAXDP(for: a.callsign)
    }

    override func tearDown() async throws {
        a?.tearDown()
        b?.tearDown()
        // Let queued main-actor work drain before the stations go.
        try? await Task.sleep(nanoseconds: 50_000_000)
        a = nil
        b = nil
    }

    // MARK: Helpers

    private func connect() async throws {
        if let sabm = a.coordinator.sessionManager.connect(
            to: b.address, path: DigiPath(), radio: a.coordinator.primaryRadioID) {
            a.coordinator.sendFrame(sabm)
        }
        try await waitUntil("the link comes up") { self.a.session != nil && self.b.session != nil }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)", file: file, line: line)
                throw WaitTimeout(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Sends `data` from A to B, accepting on B, and returns both ends.
    @discardableResult
    private func send(_ data: Data, named name: String, by type: TransferProtocolType = .axdp,
                      accept: Bool = true, compression: TransferCompressionSettings = .disabled,
                      file: StaticString = #filePath, line: UInt = #line) async throws
        -> (sent: BulkTransfer?, received: BulkTransfer?) {
        let error = a.coordinator.startTransfer(to: b.callsign, fileName: name, data: data,
                                                transferProtocol: type, compressionSettings: compression)
        XCTAssertNil(error, file: file, line: line)
        try await waitUntil("\(name) is offered to B", file: file, line: line) {
            self.b.coordinator.pendingIncomingTransfers.contains { $0.fileName == name }
        }
        let offer = b.coordinator.pendingIncomingTransfers.first { $0.fileName == name }!
        XCTAssertEqual(offer.transferProtocol, type, file: file, line: line)
        XCTAssertEqual(offer.fileSize, data.count, file: file, line: line)
        if accept {
            b.coordinator.acceptIncomingTransfer(offer.id)
            try await waitUntil("\(name) finishes at both ends", file: file, line: line) {
                self.a.transfer(named: name)?.status == .completed
                    && self.b.transfer(named: name)?.status == .completed
            }
        }
        return (a.transfer(named: name), b.transfer(named: name))
    }

    private func pattern(_ count: Int, seed: UInt8 = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    // MARK: AXDP end to end

    func testAXDPDeliversEveryByteForEverySize() async throws {
        let chunk = 128
        let cases: [(String, Data)] = [
            ("empty.bin", Data()),
            ("one.bin", Data([0x5A])),
            ("one-chunk.bin", pattern(chunk)),
            ("many-chunks.bin", pattern(chunk * 9 + 17, seed: 3)),
            ("every-byte.bin", Data((0..<768).map { UInt8($0 & 0xFF) }))
        ]
        for (name, data) in cases {
            let (sent, received) = try await send(data, named: name)
            XCTAssertEqual(b.savedData(received), data, name)
            XCTAssertEqual(URL(fileURLWithPath: received?.savedFilePath ?? "").deletingLastPathComponent()
                            .standardizedFileURL, b.folder.standardizedFileURL, "\(name) lands in the transfers folder")
            XCTAssertEqual(sent?.transferProtocol, .axdp)
        }
    }

    func testAXDPWithCompressionStillDeliversTheOriginalBytes() async throws {
        let text = Data(String(repeating: "CQ CQ CQ de K0AAA ", count: 200).utf8)
        let (_, received) = try await send(text, named: "compressible.txt", compression: .withAlgorithm(.lz4))
        XCTAssertEqual(b.savedData(received), text)
    }

    // MARK: YAPP end to end

    func testYAPPDeliversEveryByteInBothDirections() async throws {
        let forward = Data((0..<1500).map { UInt8(($0 * 7) & 0xFF) }) + Data([0x05, 0x01, 0x18, 0x06, 0x05])
        let (sent, received) = try await send(forward, named: "FWD.BIN", by: .yapp)
        XCTAssertEqual(sent?.transferProtocol, .yapp)
        XCTAssertEqual(b.savedData(received), forward)

        // And back the other way, B sending to A.
        let back = Data((0..<256).map { UInt8($0) })
        XCTAssertNil(b.coordinator.startTransfer(to: a.callsign, fileName: "BACK.BIN", data: back,
                                                 transferProtocol: .yapp))
        try await waitUntil("A is offered BACK.BIN") {
            self.a.coordinator.pendingIncomingTransfers.contains { $0.fileName == "BACK.BIN" }
        }
        a.coordinator.acceptIncomingTransfer(a.coordinator.pendingIncomingTransfers[0].id)
        try await waitUntil("BACK.BIN finishes") {
            self.a.transfer(named: "BACK.BIN")?.status == .completed
                && self.b.transfer(named: "BACK.BIN")?.status == .completed
        }
        XCTAssertEqual(a.savedData(a.transfer(named: "BACK.BIN")), back)
    }

    func testYAPPBytesNeverReachTheTerminal() async throws {
        _ = try await send(pattern(600), named: "QUIET.BIN", by: .yapp)
        XCTAssertFalse(b.terminalText.contains(0x05), "SI stayed out of B's terminal")
        XCTAssertFalse(a.terminalText.contains(0x06), "RI and RF stayed out of A's terminal")
    }

    func testTheSessionIsTheTerminalsAgainAfterYAPP() async throws {
        _ = try await send(pattern(100), named: "DONE.BIN", by: .yapp)
        try await waitUntil("the claims are released") {
            !self.b.coordinator.sessionManager.hasDeliveryClaim(for: self.b.session!.key)
                && !self.a.coordinator.sessionManager.hasDeliveryClaim(for: self.a.session!.key)
        }
        let frames = a.coordinator.sessionManager.sendData(Data("73\r".utf8), to: b.address,
                                                            radio: a.coordinator.primaryRadioID)
        frames.forEach { a.coordinator.sendFrame($0) }
        try await waitUntil("text reaches B's terminal") { self.b.terminalText.contains(Data("73\r".utf8)) }
    }

    // MARK: Pause and resume

    func testAXDPPauseThenResumeCompletes() async throws {
        let data = pattern(128 * 40, seed: 9)
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "pause.bin", data: data,
                                                 compressionSettings: .disabled))
        try await waitUntil("B is offered pause.bin") { !self.b.coordinator.pendingIncomingTransfers.isEmpty }
        b.coordinator.acceptIncomingTransfer(b.coordinator.pendingIncomingTransfers[0].id)
        try await waitUntil("some chunks go out") { (self.a.transfer(named: "pause.bin")?.bytesSent ?? 0) > 1024 }

        let id = a.transfer(named: "pause.bin")!.id
        a.coordinator.pauseTransfer(id)
        XCTAssertEqual(a.transfer(named: "pause.bin")?.status, .paused)
        try await Task.sleep(nanoseconds: 400_000_000)
        let held = a.transfer(named: "pause.bin")!.bytesSent
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(a.transfer(named: "pause.bin")?.bytesSent, held, "nothing new is sent while paused")
        XCTAssertNotEqual(b.transfer(named: "pause.bin")?.status, .completed)
        assertReceiverWaits(for: "pause.bin")

        a.coordinator.resumeTransfer(id)
        try await waitUntil("pause.bin finishes after resuming") {
            self.a.transfer(named: "pause.bin")?.status == .completed
                && self.b.transfer(named: "pause.bin")?.status == .completed
        }
        XCTAssertEqual(b.savedData(b.transfer(named: "pause.bin")), data)
    }

    func testYAPPPauseThenResumeCompletes() async throws {
        let data = pattern(125 * 30, seed: 4)
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "YPAUSE.BIN", data: data,
                                                 transferProtocol: .yapp))
        try await waitUntil("B is offered YPAUSE.BIN") { !self.b.coordinator.pendingIncomingTransfers.isEmpty }
        b.coordinator.acceptIncomingTransfer(b.coordinator.pendingIncomingTransfers[0].id)
        try await waitUntil("some blocks go out") { (self.a.transfer(named: "YPAUSE.BIN")?.bytesSent ?? 0) > 500 }
        let id = a.transfer(named: "YPAUSE.BIN")!.id
        a.coordinator.pauseTransfer(id)
        try await Task.sleep(nanoseconds: 400_000_000)
        let held = a.transfer(named: "YPAUSE.BIN")!.bytesSent
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(a.transfer(named: "YPAUSE.BIN")?.bytesSent, held)
        assertReceiverWaits(for: "YPAUSE.BIN")
        a.coordinator.resumeTransfer(id)
        try await waitUntil("YPAUSE.BIN finishes") {
            self.b.transfer(named: "YPAUSE.BIN")?.status == .completed
                && self.a.transfer(named: "YPAUSE.BIN")?.status == .completed
        }
        XCTAssertEqual(b.savedData(b.transfer(named: "YPAUSE.BIN")), data)
    }

    /// B was never told about the pause. It says Receiving with a rate for
    /// a short silence, and waiting for A once the silence runs long.
    private func assertReceiverWaits(for name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let received = b.transfer(named: name) else {
            return XCTFail("B has no \(name)", file: file, line: line)
        }
        XCTAssertEqual(received.status, .sending, file: file, line: line)
        XCTAssertNil(received.secondsWaitingForSender(now: Date()),
                     "a second of quiet is an ordinary gap", file: file, line: line)
        XCTAssertTrue(received.showsLiveRate(now: Date()), file: file, line: line)
        let later = Date().addingTimeInterval(60)
        XCTAssertNotNil(received.secondsWaitingForSender(now: later),
                        "a minute of quiet is waiting for the sender", file: file, line: line)
        XCTAssertFalse(received.showsLiveRate(now: later), file: file, line: line)
    }

    // MARK: Cancel

    private func startLongAXDP(_ name: String) async throws {
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: name, data: pattern(128 * 80),
                                                 compressionSettings: .disabled))
        try await waitUntil("B is offered \(name)") { !self.b.coordinator.pendingIncomingTransfers.isEmpty }
        b.coordinator.acceptIncomingTransfer(b.coordinator.pendingIncomingTransfers[0].id)
        try await waitUntil("\(name) is under way at B") { (self.b.transfer(named: name)?.bytesSent ?? 0) > 256 }
    }

    func testAXDPCancelBySenderReachesTheReceiver() async throws {
        try await startLongAXDP("cancel-a.bin")
        a.coordinator.cancelTransfer(a.transfer(named: "cancel-a.bin")!.id)
        XCTAssertEqual(a.transfer(named: "cancel-a.bin")?.status, .cancelled)
        try await waitUntil("B hears the cancel") { self.b.transfer(named: "cancel-a.bin")?.status == .cancelled }
        XCTAssertNil(b.transfer(named: "cancel-a.bin")?.savedFilePath)
        XCTAssertTrue(b.notifications.events.contains(.canceledByPeer(fileName: "cancel-a.bin", peer: a.callsign)))
        XCTAssertFalse(a.notifications.events.contains { if case .canceledByPeer = $0 { return true }; return false },
                       "the operator who canceled is not told they canceled")
    }

    func testAXDPCancelByReceiverReachesTheSender() async throws {
        try await startLongAXDP("cancel-b.bin")
        b.coordinator.cancelTransfer(b.transfer(named: "cancel-b.bin")!.id)
        XCTAssertEqual(b.transfer(named: "cancel-b.bin")?.status, .cancelled)
        try await waitUntil("A hears the cancel") { self.a.transfer(named: "cancel-b.bin")?.status == .cancelled }
        let sentBefore = a.link.framesSent
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertLessThanOrEqual(a.link.framesSent - sentBefore, 8, "A stops sending chunks")
    }

    func testYAPPCancelOnEitherSideReachesTheOther() async throws {
        for canceler in ["sender", "receiver"] {
            let name = "YCAN-\(canceler).BIN"
            XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: name, data: pattern(125 * 60),
                                                     transferProtocol: .yapp))
            try await waitUntil("B is offered \(name)") {
                self.b.coordinator.pendingIncomingTransfers.contains { $0.fileName == name }
            }
            b.coordinator.acceptIncomingTransfer(b.coordinator.pendingIncomingTransfers.first { $0.fileName == name }!.id)
            try await waitUntil("\(name) under way") { (self.b.transfer(named: name)?.bytesSent ?? 0) > 250 }
            let (local, remote) = canceler == "sender" ? (a!, b!) : (b!, a!)
            local.coordinator.cancelTransfer(local.transfer(named: name)!.id)
            XCTAssertEqual(local.transfer(named: name)?.status, .cancelled)
            try await waitUntil("the other side of \(name) is canceled") {
                remote.transfer(named: name)?.status == .cancelled
            }
            // CA grace period, so the next round starts on a clean session.
            try await waitUntil("\(name) lets go of the session", timeout: 15) {
                self.a.coordinator.yappTransfers.isEmpty && self.b.coordinator.yappTransfers.isEmpty
            }
        }
    }

    // MARK: Link loss

    func testRadioSilenceFailsBothSidesWithAReason() async throws {
        b.coordinator.transferTimeouts.inboundStall = 3
        try await startLongAXDP("lost.bin")
        a.link.silenced = true
        b.link.silenced = true
        try await waitUntil("both sides give up", timeout: 30) {
            if case .failed = self.a.transfer(named: "lost.bin")?.status,
               case .failed = self.b.transfer(named: "lost.bin")?.status { return true }
            return false
        }
        guard case .failed(let senderReason) = a.transfer(named: "lost.bin")!.status,
              case .failed(let receiverReason) = b.transfer(named: "lost.bin")!.status else { return }
        XCTAssertEqual(senderReason, TransferLinkLoss.reason(peer: b.callsign, timedOut: true))
        XCTAssertFalse(receiverReason.isEmpty)
        XCTAssertTrue(a.notifications.events.contains { if case .failed = $0 { return true }; return false })
    }

    func testADisconnectMidTransferFailsBothSides() async throws {
        try await startLongAXDP("disc.bin")
        if let disc = a.coordinator.sessionManager.disconnect(session: a.session!) {
            a.coordinator.sendFrame(disc)
        }
        try await waitUntil("both sides fail") {
            if case .failed = self.a.transfer(named: "disc.bin")?.status,
               case .failed = self.b.transfer(named: "disc.bin")?.status { return true }
            return false
        }
        XCTAssertEqual(b.transfer(named: "disc.bin")?.status,
                       .failed(reason: TransferLinkLoss.reason(peer: a.callsign, timedOut: false)))
    }

    func testYAPPLinkLossFailsTheTransferAndFreesTheSession() async throws {
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "YLOST.BIN", data: pattern(125 * 60),
                                                 transferProtocol: .yapp))
        try await waitUntil("offered") { !self.b.coordinator.pendingIncomingTransfers.isEmpty }
        b.coordinator.acceptIncomingTransfer(b.coordinator.pendingIncomingTransfers[0].id)
        try await waitUntil("under way") { (self.b.transfer(named: "YLOST.BIN")?.bytesSent ?? 0) > 250 }
        if let disc = b.coordinator.sessionManager.disconnect(session: b.session!) {
            b.coordinator.sendFrame(disc)
        }
        try await waitUntil("both YAPP ends fail") {
            if case .failed = self.a.transfer(named: "YLOST.BIN")?.status,
               case .failed = self.b.transfer(named: "YLOST.BIN")?.status { return true }
            return false
        }
        XCTAssertTrue(a.coordinator.yappTransfers.isEmpty)
        XCTAssertTrue(b.coordinator.yappTransfers.isEmpty)
    }

    // MARK: Offers

    func testADeclinedOfferEndsBothSides() async throws {
        _ = try await send(pattern(300), named: "nope.bin", accept: false)
        let offer = b.coordinator.pendingIncomingTransfers[0]
        b.coordinator.declineIncomingTransfer(offer.id)
        try await waitUntil("A hears the decline") {
            if case .failed = self.a.transfer(named: "nope.bin")?.status { return true }
            return false
        }
        XCTAssertEqual(b.transfer(named: "nope.bin")?.status, .cancelled)
        XCTAssertTrue(b.coordinator.pendingIncomingTransfers.isEmpty)
    }

    func testTheAllowListAcceptsWithNoTerminalOnScreen() async throws {
        b.settings.allowCallsignForFileTransfer(a.callsign)
        let data = pattern(500)
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "trusted.bin", data: data,
                                                 compressionSettings: .disabled))
        try await waitUntil("trusted.bin arrives unasked") {
            self.b.transfer(named: "trusted.bin")?.status == .completed
        }
        XCTAssertTrue(b.coordinator.pendingIncomingTransfers.isEmpty, "nobody was asked")
        XCTAssertEqual(b.savedData(b.transfer(named: "trusted.bin")), data)
        XCTAssertFalse(b.notifications.events.contains { if case .offer = $0 { return true }; return false })
    }

    func testTheDenyListDeclinesWithNoTerminalOnScreen() async throws {
        b.settings.denyCallsignForFileTransfer(a.callsign)
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "blocked.bin", data: pattern(500),
                                                 compressionSettings: .disabled))
        try await waitUntil("A is refused") {
            if case .failed = self.a.transfer(named: "blocked.bin")?.status { return true }
            return false
        }
        guard case .failed(let reason) = b.transfer(named: "blocked.bin")?.status else {
            return XCTFail("B's row says why")
        }
        XCTAssertTrue(reason.contains("deny list"))
        XCTAssertTrue(b.coordinator.pendingIncomingTransfers.isEmpty)
    }

    func testOffersOverTheCapAreDeclinedForBothProtocols() async throws {
        b.settings.maxIncomingTransferBytes = 1_000
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "big.bin", data: pattern(2_000),
                                                 compressionSettings: .disabled))
        try await waitUntil("A is refused the big AXDP file") {
            if case .failed = self.a.transfer(named: "big.bin")?.status { return true }
            return false
        }
        guard case .failed(let reason) = b.transfer(named: "big.bin")?.status else { return XCTFail() }
        XCTAssertTrue(reason.contains("limit"))

        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "BIG.YAP", data: pattern(2_000),
                                                 transferProtocol: .yapp))
        try await waitUntil("A is refused the big YAPP file") {
            if case .failed = self.a.transfer(named: "BIG.YAP")?.status { return true }
            return false
        }
        guard case .failed(let yappReason) = a.transfer(named: "BIG.YAP")?.status else { return XCTFail() }
        XCTAssertTrue(yappReason.hasPrefix("The other station refused the file"))
    }

    func testAnOfferIsNotifiedAndTheResultToo() async throws {
        _ = try await send(pattern(200), named: "told.bin")
        XCTAssertTrue(b.notifications.events.contains(.offer(from: a.callsign, fileName: "told.bin", fileSize: 200)))
        XCTAssertTrue(b.notifications.events.contains(.completed(fileName: "told.bin", peer: a.callsign, direction: .inbound)))
        XCTAssertTrue(a.notifications.events.contains(.completed(fileName: "told.bin", peer: b.callsign, direction: .outbound)))
    }

    func testTheSecondOfferQuotesAirtimeFromTheFirst() async throws {
        // Big enough that the data phase lasts the second a rate needs:
        // 28 of the 720-byte chunks.
        _ = try await send(pattern(20_000), named: "first.bin")
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "second.bin", data: pattern(3_000),
                                                 compressionSettings: .disabled))
        try await waitUntil("second offer") { !self.b.coordinator.pendingIncomingTransfers.isEmpty }
        let offer = b.coordinator.pendingIncomingTransfers[0]
        XCTAssertNotNil(offer.estimatedAirtimeSeconds, "a rate was measured on the first transfer")
    }

    // MARK: Saving

    func testTheSameNameThreeTimesMakesThreeFiles() async throws {
        var names: [String] = []
        for round in 0..<3 {
            let (_, received) = try await send(Data("round \(round)".utf8), named: "same.txt")
            names.append(URL(fileURLWithPath: received?.savedFilePath ?? "").lastPathComponent)
            // Each round's row is found by name; clear finished rows between.
            b.coordinator.clearCompletedTransfers()
            a.coordinator.clearCompletedTransfers()
        }
        XCTAssertEqual(names, ["same.txt", "same 2.txt", "same 3.txt"])
        XCTAssertEqual(try Data(contentsOf: b.folder.appendingPathComponent("same.txt")), Data("round 0".utf8))
    }

    func testAHostileFileNameCannotLeaveTheFolder() async throws {
        let (_, axdp) = try await send(Data("x".utf8), named: "../../escape.txt")
        let axdpURL = URL(fileURLWithPath: axdp?.savedFilePath ?? "")
        XCTAssertEqual(axdpURL.deletingLastPathComponent().standardizedFileURL, b.folder.standardizedFileURL)
        XCTAssertEqual(axdpURL.lastPathComponent, "escape.txt")

        let (_, yapp) = try await send(Data("y".utf8), named: "..\\..\\EVIL.TXT", by: .yapp)
        let yappURL = URL(fileURLWithPath: yapp?.savedFilePath ?? "")
        XCTAssertEqual(yappURL.deletingLastPathComponent().standardizedFileURL, b.folder.standardizedFileURL)
        XCTAssertEqual(yappURL.lastPathComponent, "EVIL.TXT")
    }

    // MARK: Text that looks like YAPP

    func testYAPPBytesInsideOrdinaryTextStartNothing() async throws {
        let packets = [
            Data("Next file: \u{05}\u{01} done\r".utf8),
            Data([0x05, 0x01, 0x0D]),
            Data([0x0D, 0x05, 0x01])
        ]
        for packet in packets {
            let frames = a.coordinator.sessionManager.sendData(packet, to: b.address,
                                                                radio: a.coordinator.primaryRadioID)
            frames.forEach { a.coordinator.sendFrame($0) }
        }
        let expected = packets.reduce(Data(), +)
        try await waitUntil("all the text reaches B's terminal") { self.b.terminalText.count >= expected.count }
        XCTAssertEqual(b.terminalText, expected, "every byte went to the terminal, in order")
        XCTAssertTrue(b.coordinator.yappAwaitingHeader.isEmpty)
        XCTAssertTrue(b.coordinator.transfers.isEmpty)
        XCTAssertFalse(b.coordinator.sessionManager.hasDeliveryClaim(for: b.session!.key))
    }

    func testAnSIDuringAnotherTransferIsNotTakenAsANewOne() async throws {
        try await startLongAXDP("busy.bin")
        let frames = a.coordinator.sessionManager.sendData(Data([0x05, 0x01]), to: b.address,
                                                            radio: a.coordinator.primaryRadioID)
        frames.forEach { a.coordinator.sendFrame($0) }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(b.coordinator.yappAwaitingHeader.isEmpty)
        XCTAssertEqual(b.coordinator.transfers.count, 1)
    }

    // MARK: Dispatch

    func testAProtocolWithNoSenderIsRefused() {
        let error = a.coordinator.startTransfer(to: b.callsign, fileName: "x.7p", data: Data([1]),
                                                transferProtocol: .sevenPlus)
        XCTAssertNotNil(error)
        XCTAssertTrue(a.coordinator.transfers.isEmpty, "nothing was queued under another protocol")
    }

    func testYAPPNeedsAConnectedSession() {
        let error = a.coordinator.startTransfer(to: "K0ZZZ-9", fileName: "x", data: Data([1]),
                                                transferProtocol: .yapp)
        XCTAssertEqual(error, "Cannot send file: YAPP requires a connected session. Connect to K0ZZZ-9 first.")
    }

    func testTheStartTransferURLEntryPointStillWorks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("url-entry-\(UUID().uuidString).bin")
        let data = pattern(400)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let started = await a.coordinator.startTransfer(to: b.callsign, fileURL: url, compressionSettings: .disabled)
        XCTAssertNil(started)
        try await waitUntil("offered") { !self.b.coordinator.pendingIncomingTransfers.isEmpty }
        b.coordinator.acceptIncomingTransfer(b.coordinator.pendingIncomingTransfers[0].id)
        try await waitUntil("done") { self.b.coordinator.transfers.first?.status == .completed }
        XCTAssertEqual(b.savedData(b.coordinator.transfers.first), data)
    }

    /// Smoke run 2026-10-03-1, issue 17: the read now happens off the main
    /// actor; a file that can't be read still says so and starts nothing.
    func testAnUnreadableFileSaysSoAndStartsNothing() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).bin")
        let error = await a.coordinator.startTransfer(to: b.callsign, fileURL: missing, compressionSettings: .disabled)
        XCTAssertEqual(error, "Failed to read file")
        XCTAssertTrue(a.coordinator.transfers.isEmpty)
    }
}
