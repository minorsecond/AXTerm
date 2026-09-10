import XCTest
@testable import AXTerm

/// A CI-V transport whose radio is a script: it answers each written
/// command as told, or not at all.
nonisolated final class FakeCIVTransport: CIVTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var state: CIVTransportState = .closed
    var onBytes: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (CIVTransportState) -> Void)?

    /// Every frame written, in order.
    private var _written: [CIVFrame] = []
    var written: [CIVFrame] { lock.withLock { _written } }
    /// How to answer a command byte: bytes to send back after `delay`.
    var responder: (@Sendable (CIVFrame) -> [UInt8]?)?
    var replyDelay: TimeInterval = 0.005
    var writeError: Error?
    var modemLines: [(dtr: Bool?, rts: Bool?)] = []

    func open() { state = .open; onStateChange?(state) }
    func close() { state = .closed; onStateChange?(state) }
    func fail(_ reason: String) { state = .failed(reason); onStateChange?(state) }

    func write(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        if let writeError { completion(writeError); return }
        guard let frame = CIVFrame.parse([UInt8](data)) else { completion(nil); return }
        lock.withLock { _written.append(frame) }
        completion(nil)
        if let reply = responder?(frame) {
            DispatchQueue.global().asyncAfter(deadline: .now() + replyDelay) { [weak self] in
                self?.onBytes?(Data(reply))
            }
        }
    }

    func setModemLines(dtr: Bool?, rts: Bool?) {
        lock.withLock { modemLines.append((dtr, rts)) }
    }

    /// Inject bytes as if the radio sent them unprompted.
    func inject(_ bytes: [UInt8]) { onBytes?(Data(bytes)) }

    // Radio-side helpers.
    static let ok: [UInt8] = [0xFE, 0xFE, 0xE0, 0xA4, 0xFB, 0xFD]
    static let ng: [UInt8] = [0xFE, 0xFE, 0xE0, 0xA4, 0xFA, 0xFD]
    static func reply(_ command: UInt8, _ sub: UInt8?, _ data: [UInt8], from radio: UInt8 = 0xA4) -> [UInt8] {
        [0xFE, 0xFE, 0xE0, radio, command] + (sub.map { [$0] } ?? []) + data + [0xFD]
    }
}

/// The client: one request at a time, matched by order, with timeouts;
/// and the PTT controller's fail-safes on top of it.
final class CIVClientTests: XCTestCase {

    private func makeClient(timeout: TimeInterval = 0.2) -> (CIVClient, FakeCIVTransport) {
        let transport = FakeCIVTransport()
        let client = CIVClient(transport: transport, requestTimeout: timeout)
        client.open()
        return (client, transport)
    }

    /// A radio that answers like an IC-705 on 144.390 FM-D.
    private func ic705(_ frame: CIVFrame) -> [UInt8]? {
        switch (frame.command, frame.subcommand) {
        case (0x19, 0x00): return FakeCIVTransport.reply(0x19, 0x00, [0xA4])
        case (0x03, _): return FakeCIVTransport.reply(0x03, nil, CIVBCD.frequencyBytes(hz: 144_390_000))
        case (0x04, _): return FakeCIVTransport.reply(0x04, nil, [0x05, 0x01])
        case (0x1A, 0x06) where frame.data.isEmpty: return FakeCIVTransport.reply(0x1A, 0x06, [0x01, 0x01])
        case (0x15, 0x01): return FakeCIVTransport.reply(0x15, 0x01, [0x01])
        case (0x15, 0x02): return FakeCIVTransport.reply(0x15, 0x02, [0x01, 0x20])
        case (0x1C, 0x00) where frame.data.isEmpty: return FakeCIVTransport.reply(0x1C, 0x00, [0x00])
        default: return FakeCIVTransport.ok   // every set is accepted
        }
    }

    // MARK: - Asking the whole bus who is there

    /// The fault this exists for: every command times out, and "check the
    /// address and the CI-V settings" is two guesses. A radio living on
    /// another address answers a broadcast, and names itself.
    func testAProbeFindsARadioOnAnotherAddress() async {
        let (client, transport) = makeClient()
        transport.responder = { frame in
            guard frame.to == CIVFrame.broadcast, frame.command == 0x19 else { return nil }
            return FakeCIVTransport.reply(0x19, 0x00, [0x5E], from: 0x5E)
        }
        let found = await client.probeAddress()
        XCTAssertEqual(found, 0x5E, "the answering address is the one to configure")
        XCTAssertEqual(transport.written.first?.to, CIVFrame.broadcast,
                       "a probe is addressed to every radio, not to the one we already failed to reach")
    }

    /// The other half of the fork: nothing at all answers, so the address was
    /// never the problem.
    func testAProbeThatNothingAnswersReportsNothing() async {
        let (client, transport) = makeClient(timeout: 0.05)
        transport.responder = { _ in nil }
        let found = await client.probeAddress()
        XCTAssertNil(found)
    }

    /// With echo-back on, our own broadcast comes back from the controller
    /// address. Reading that as an answer would report the radio as living
    /// at `E0` — us — and send the operator to configure a lie.
    func testAProbeDoesNotMistakeItsOwnEchoForAnAnswer() async {
        let (client, transport) = makeClient(timeout: 0.05)
        transport.responder = { frame in frame.encoded().map { $0 } }
        let found = await client.probeAddress()
        XCTAssertNil(found, "an echo is not an answer")
    }

    /// The relaxed acceptance belongs to the probe alone. An ordinary command
    /// answered by a foreign address is still not an answer — matching it
    /// would let a second radio on the bus drive this one's PTT.
    func testAnOrdinaryRequestIsStillNotAnsweredByAForeignAddress() async {
        let (client, transport) = makeClient(timeout: 0.05)
        transport.responder = { _ in FakeCIVTransport.reply(0x19, 0x00, [0x5E], from: 0x5E) }
        do {
            _ = try await client.identify()
            XCTFail("a reply from 5E must not satisfy a request addressed to A4")
        } catch {
            XCTAssertEqual(error as? CIVError, .timeout(command: 0x19))
        }
    }

    func testIdentifyAndReads() async throws {
        let (client, transport) = makeClient()
        transport.responder = { [self] in ic705($0) }
        let address = try await client.identify()
        XCTAssertEqual(address, 0xA4)
        let hz = try await client.readFrequency()
        XCTAssertEqual(hz, 144_390_000)
        let mode = try await client.readMode()
        XCTAssertEqual(mode.mode, .fm); XCTAssertEqual(mode.filter, 1)
        let dataMode = try await client.readDataMode()
        XCTAssertTrue(dataMode)
        let squelchOpen = try await client.readSquelchOpen()
        XCTAssertTrue(squelchOpen)
        let sMeter = try await client.readSMeter()
        XCTAssertEqual(sMeter, 120)
        let ptt = try await client.readPTT()
        XCTAssertFalse(ptt)
    }

    func testTheWrongRadioIsNamed() async {
        let (client, transport) = makeClient()
        transport.responder = { _ in FakeCIVTransport.reply(0x19, 0x00, [0x94]) }
        do {
            _ = try await client.identify()
            XCTFail("expected wrongRadio")
        } catch let error as CIVError {
            XCTAssertEqual(error, .wrongRadio(found: 0x94, expected: 0xA4))
            XCTAssertEqual(error.message, "found IC-7300 (94) on this port, expected IC-705 (A4)")
        } catch { XCTFail("\(error)") }
    }

    func testASetIsAcknowledgedOrRejected() async throws {
        let (client, transport) = makeClient()
        transport.responder = { frame in frame.command == 0x05 ? FakeCIVTransport.ng : FakeCIVTransport.ok }
        try await client.setPTT(true)
        XCTAssertEqual(transport.written.last, CIVCommand.setPTT(true))
        do {
            try await client.setFrequency(7_074_500)
            XCTFail("expected rejected")
        } catch let error as CIVError {
            XCTAssertEqual(error, .rejected(command: 0x05))
        }
    }

    func testATimeoutDoesNotBlockTheNextRequest() async throws {
        let (client, transport) = makeClient(timeout: 0.1)
        transport.responder = { frame in frame.command == 0x03 ? nil : FakeCIVTransport.ok }   // never answers frequency reads
        do {
            _ = try await client.readFrequency()
            XCTFail("expected timeout")
        } catch let error as CIVError {
            XCTAssertEqual(error, .timeout(command: 0x03))
        }
        try await client.setPTT(false)   // still works
        XCTAssertEqual(transport.written.count, 2)
    }

    func testUnsolicitedFramesNeverSatisfyARequest() async throws {
        let (client, transport) = makeClient(timeout: 0.3)
        var unsolicited: [CIVFrame] = []
        let lock = NSLock()
        client.onUnsolicited = { frame in lock.withLock { unsolicited.append(frame) } }
        transport.responder = { frame in
            // Answer the frequency read only after a transceive broadcast and an echo of our own frame.
            guard frame.command == 0x03 else { return FakeCIVTransport.ok }
            return nil
        }
        let task = Task { try await client.readFrequency() }
        try await Task.sleep(for: .milliseconds(30))
        transport.inject([0xFE, 0xFE, 0x00, 0xA4, 0x00] + CIVBCD.frequencyBytes(hz: 7_000_000) + [0xFD])   // transceive
        transport.inject([UInt8](CIVCommand.readFrequency().encoded()))                                  // our echo
        try await Task.sleep(for: .milliseconds(30))
        transport.inject(FakeCIVTransport.reply(0x03, nil, CIVBCD.frequencyBytes(hz: 144_390_000)))
        let answered = try await task.value
        XCTAssertEqual(answered, 144_390_000)
        XCTAssertEqual(unsolicited.count, 1, "the broadcast; the echo is dropped")
        XCTAssertEqual(unsolicited.first?.to, 0x00)
    }

    func testRequestsBeforeOpenFail() async {
        let transport = FakeCIVTransport()
        let client = CIVClient(transport: transport)
        do {
            _ = try await client.readFrequency()
            XCTFail("expected notOpen")
        } catch let error as CIVError {
            XCTAssertEqual(error, .notOpen)
        } catch { XCTFail("\(error)") }
    }

    func testConfigureForPacketSendsTheWholeRecipe() async throws {
        let (client, transport) = makeClient()
        transport.responder = { _ in FakeCIVTransport.ok }
        try await client.configureForPacket(.afsk1200)
        let commands = transport.written.map { $0.encoded().map { String(format: "%02X", $0) }.joined(separator: " ") }
        XCTAssertEqual(commands.first, "FE FE A4 E0 06 05 01 FD", "FM, FIL1")
        XCTAssertTrue(commands.contains("FE FE A4 E0 1A 06 01 01 FD"), "data mode on")
        XCTAssertTrue(commands.contains("FE FE A4 E0 1A 05 01 19 01 FD"), "DATA MOD = USB")
        XCTAssertTrue(commands.contains("FE FE A4 E0 1A 05 01 11 00 FD"), "AF SQL open")
        XCTAssertTrue(commands.contains("FE FE A4 E0 1A 05 01 25 00 FD"), "USB SEND off")
        XCTAssertTrue(commands.contains("FE FE A4 E0 1A 05 01 31 00 FD"), "transceive off")
        XCTAssertTrue(commands.contains("FE FE A4 E0 1A 05 00 41 00 FD"), "144 MHz TX delay off")
        XCTAssertEqual(commands.count, 10)
    }

    // MARK: - PTT controller

    func testPTTKeysAndUnkeysThroughCIV() async throws {
        let (client, transport) = makeClient()
        transport.responder = { _ in FakeCIVTransport.ok }
        let ptt = CIVPTTController(client: client, maxTransmitSeconds: 30)
        var transitions: [Bool] = []
        let lock = NSLock()
        ptt.onTransition = { keyed, _ in lock.withLock { transitions.append(keyed) } }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            ptt.setTransmit(true) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        XCTAssertTrue(ptt.isKeyed)
        XCTAssertEqual(transport.written.last, CIVCommand.setPTT(true))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            ptt.setTransmit(false) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        XCTAssertFalse(ptt.isKeyed)
        XCTAssertEqual(transport.written.last, CIVCommand.setPTT(false))
        XCTAssertEqual(transitions, [true, false])
    }

    func testARefusedKeyDownKeysNothingAndTriesToUnkey() async {
        let (client, transport) = makeClient(timeout: 0.1)
        transport.responder = { frame in frame.data == [0x01] ? FakeCIVTransport.ng : FakeCIVTransport.ok }
        let ptt = CIVPTTController(client: client)
        let error: Error? = await withCheckedContinuation { c in ptt.setTransmit(true) { c.resume(returning: $0) } }
        XCTAssertNotNil(error)
        XCTAssertFalse(ptt.isKeyed)
        // The refusal is followed by a defensive key-up.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.written.map(\.data), [[0x01], [0x00]])
    }

    func testTheWatchdogForcesTheTransmitterOff() async throws {
        let (client, transport) = makeClient()
        transport.responder = { _ in FakeCIVTransport.ok }
        let ptt = CIVPTTController(client: client, maxTransmitSeconds: 0.15)
        var notes: [String?] = []
        let lock = NSLock()
        ptt.onTransition = { _, note in lock.withLock { notes.append(note) } }
        _ = await withCheckedContinuation { c in ptt.setTransmit(true) { c.resume(returning: $0) } }
        XCTAssertTrue(ptt.isKeyed)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(ptt.isKeyed)
        XCTAssertTrue(transport.written.contains(CIVCommand.setPTT(false)))
        XCTAssertTrue(notes.compactMap { $0 }.contains { $0.contains("watchdog") })
    }

    func testLosingThePortWhileKeyedIsReported() async {
        let (client, transport) = makeClient()
        transport.responder = { _ in FakeCIVTransport.ok }
        let ptt = CIVPTTController(client: client)
        var notes: [String?] = []
        let lock = NSLock()
        ptt.onTransition = { _, note in lock.withLock { notes.append(note) } }
        _ = await withCheckedContinuation { c in ptt.setTransmit(true) { c.resume(returning: $0) } }
        transport.fail("USB unplugged")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(ptt.isKeyed)
        XCTAssertTrue(notes.compactMap { $0 }.contains { $0.contains("lost") })
    }

    func testSerialLinePTTRaisesTheLine() async {
        let transport = FakeCIVTransport()
        transport.open()
        let ptt = SerialLinePTTController(transport: transport, line: .rts)
        _ = await withCheckedContinuation { c in ptt.setTransmit(true) { c.resume(returning: $0) } }
        XCTAssertEqual(transport.modemLines.last?.rts, true)
        XCTAssertTrue(ptt.isKeyed)
        _ = await withCheckedContinuation { c in ptt.setTransmit(false) { c.resume(returning: $0) } }
        XCTAssertEqual(transport.modemLines.last?.rts, false)
        XCTAssertFalse(ptt.isKeyed)
    }
}
