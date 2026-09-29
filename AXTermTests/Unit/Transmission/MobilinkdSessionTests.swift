import XCTest
@testable import AXTerm

/// What AXTerm sends a TNC4 when a link comes up and goes down.
final class MobilinkdSessionTests: XCTestCase {

    private let reset = Data([0xC0, 0x06, 0x0B, 0xC0])

    private func levels(out: UInt16 = 63, input: UInt16 = 4, modem: UInt8 = 1) -> MobilinkdSession.Levels {
        MobilinkdSession.Levels(outputGain: out, inputGain: input, modemType: modem)
    }

    // MARK: KISS timing

    func testTimingFramesAreInTensOfMilliseconds() {
        let t = KISSTimingParameters(txDelayMs: 500, persistence: 63, slotTimeMs: 100, txTailMs: 50)
        XCTAssertEqual(t.frames(), [
            Data([0xC0, 0x01, 50, 0xC0]),
            Data([0xC0, 0x02, 63, 0xC0]),
            Data([0xC0, 0x03, 10, 0xC0]),
            Data([0xC0, 0x04, 5, 0xC0]),
            Data([0xC0, 0x05, 0, 0xC0]),
        ])
    }

    func testTimingClampsToWhatAByteCarries() {
        let t = KISSTimingParameters(txDelayMs: 5_000, persistence: 63, slotTimeMs: -10, txTailMs: 0)
        XCTAssertEqual(t.frames()[0], Data([0xC0, 0x01, 255, 0xC0]))
        XCTAssertEqual(t.frames()[2], Data([0xC0, 0x03, 0, 0xC0]))
    }

    /// The BLE link used to send a hardcoded 300 ms whatever the profile said.
    /// The IC-V8 needs about that long just to get on the air, so its packets
    /// went out with almost no preamble.
    func testABLEProfileCarriesItsOwnTXDelay() {
        var radio = RadioProfile(id: RadioID(), name: "IC-V8")
        radio.kind = .ble
        radio.txDelayMs = 500
        XCTAssertEqual(radio.bleConfig.timing.txDelayMs, 500)
        XCTAssertEqual(radio.bleConfig.timing.frames()[0], Data([0xC0, 0x01, 50, 0xC0]))
    }

    // MARK: Liveness probe

    func testTheProbeIsAFirmwareVersionQuery() {
        XCTAssertEqual(MobilinkdSession.probe, Data([0xC0, 0x06, 0x28, 0xC0]))
        XCTAssertTrue(MobilinkdSession.isProbeReply(Data([0x06, 0x28, 0x32, 0x2E, 0x35, 0x2E, 0x31, 0x34])))
        XCTAssertFalse(MobilinkdSession.isProbeReply(Data([0x06, 0x06, 0x10, 0x7A])), "a battery reply is not an answer")
    }

    // MARK: Reading levels

    func testTheReaderNeedsAllThreeAnswers() {
        var reader = MobilinkdSession.Reader()
        reader.observe(Data([0x06, 0x0C, 0x00, 0x3F]))
        reader.observe(Data([0x06, 0x0D, 0x00, 0x04]))
        XCTAssertNil(reader.levels, "no modem type yet")
        reader.observe(Data([0x06, 0xC1, 0x81, 0x01]))
        XCTAssertEqual(reader.levels, levels(out: 63, input: 4, modem: 1))
    }

    /// PacketEngine writes any input-gain reply into the radio profile, so the
    /// link must recognise its own and keep them.
    func testSessionRepliesAreRecognised() {
        XCTAssertTrue(MobilinkdSession.isSessionReply(Data([0x06, 0x0D, 0x00, 0x04])))
        XCTAssertTrue(MobilinkdSession.isSessionReply(Data([0x06, 0x0C, 0x00, 0x3F])))
        XCTAssertTrue(MobilinkdSession.isSessionReply(Data([0x06, 0xC1, 0x81, 0x01])))
        XCTAssertTrue(MobilinkdSession.isSessionReply(Data([0x06, 0x28, 0x32])))
        XCTAssertFalse(MobilinkdSession.isSessionReply(Data([0x06, 0x06, 0x10, 0x7A])), "battery belongs to the app")
        XCTAssertFalse(MobilinkdSession.isSessionReply(Data([0x06, 0x04, 0, 1, 0, 2, 0, 3, 0, 4])), "levels belong to the app")
    }

    // MARK: Holding back the session's own replies

    func testEachRequestIsMatchedToTheReplyItDraws() {
        XCTAssertEqual(MobilinkdSession.replyKey(forRequest: Data(MobilinkdTNC.setInputGain(0))), 0x0D,
                       "a SET is answered like its GET")
        XCTAssertEqual(MobilinkdSession.replyKey(forRequest: Data(MobilinkdTNC.getInputGain())), 0x0D)
        XCTAssertEqual(MobilinkdSession.replyKey(forRequest: Data(MobilinkdTNC.setOutputGain(63))), 0x0C)
        XCTAssertEqual(MobilinkdSession.replyKey(forRequest: Data(MobilinkdTNC.setModemType(.afsk1200))), 0x81)
        XCTAssertEqual(MobilinkdSession.replyKey(forRequest: MobilinkdSession.probe), 0x28)
        XCTAssertNil(MobilinkdSession.replyKey(forRequest: reset), "RESET draws no reply")
        XCTAssertNil(MobilinkdSession.replyKey(forRequest: Data([0xC0, 0x01, 30, 0xC0])), "nor does KISS timing")
    }

    func testOnlyAsManyRepliesAsWereAskedForAreHeldBack() {
        var expected = MobilinkdSession.ExpectedReplies()
        expected.expect(repliesTo: [Data(MobilinkdTNC.getInputGain())])
        let reply = Data([0x06, 0x0D, 0x00, 0x04])
        XCTAssertTrue(expected.claim(reply), "the session's own reply")
        XCTAssertFalse(expected.claim(reply), "a second one is the app's, e.g. an auto-adjust result")
    }

    func testARepliesNobodyAskedForGoesThrough() {
        var expected = MobilinkdSession.ExpectedReplies()
        expected.expect(repliesTo: [Data(MobilinkdTNC.getOutputGain())])
        XCTAssertFalse(expected.claim(Data([0x06, 0x0D, 0x00, 0x04])), "asked for output gain, not input")
        XCTAssertFalse(expected.claim(Data([0x06, 0x06, 0x10, 0x7A])), "battery is never the session's")
    }

    /// A reply the TNC4 never sent must not swallow the app's later one.
    func testExpectationsExpire() {
        var expected = MobilinkdSession.ExpectedReplies()
        let t0 = Date()
        expected.expect(repliesTo: [Data(MobilinkdTNC.getInputGain())], now: t0)
        XCTAssertFalse(expected.claim(Data([0x06, 0x0D, 0x00, 0x04]),
                                      now: t0.addingTimeInterval(MobilinkdSession.ExpectedReplies.lifetime + 1)))
    }

    // MARK: Applying and restoring

    func testNothingIsSentWhenTheTNCAlreadyAgrees() {
        XCTAssertEqual(MobilinkdSession.frames(toReach: levels(), from: levels()), [])
    }

    func testOnlyWhatDiffersIsSent() {
        XCTAssertEqual(MobilinkdSession.frames(toReach: levels(out: 50), from: levels(out: 63)),
                       [Data(MobilinkdTNC.setOutputGain(50))],
                       "an output change alone needs no RESET")
    }

    /// Setting input gain leaves the TNC4 streaming levels, so RESET follows.
    func testAnInputGainChangeEndsWithReset() {
        XCTAssertEqual(MobilinkdSession.frames(toReach: levels(input: 0), from: levels(input: 4)),
                       [Data(MobilinkdTNC.setInputGain(0)), reset])
    }

    func testModemTypeGoesFirst() {
        let frames = MobilinkdSession.frames(toReach: levels(out: 50, input: 0, modem: 3), from: levels())
        XCTAssertEqual(frames.first, Data(MobilinkdTNC.setModemType(.fsk9600)))
        XCTAssertEqual(frames.last, reset)
        XCTAssertEqual(frames.count, 4)
    }

    /// Connecting always restarts the demodulator. On 2026-09-29 a TNC4 that
    /// had just connected passed up nothing until it did.
    func testConnectingAlwaysEndsWithOneReset() {
        XCTAssertEqual(MobilinkdSession.connectFrames(wanted: nil, found: nil), [reset])
        XCTAssertEqual(MobilinkdSession.connectFrames(wanted: levels(), found: levels()), [reset])
        let frames = MobilinkdSession.connectFrames(wanted: levels(input: 0), found: levels(input: 4))
        XCTAssertEqual(frames.filter { $0 == reset }.count, 1, "no doubled RESET")
        XCTAssertEqual(frames.last, reset)
    }

    /// The point of the whole exercise: a TNC4 shared with another radio goes
    /// back to its owner's settings when AXTerm lets go of it.
    func testRestoringPutsBackWhatWasFound() {
        let found = levels(out: 63, input: 4, modem: 1)
        let applied = levels(out: 63, input: 0, modem: 1)
        XCTAssertEqual(MobilinkdSession.restoreFrames(applied: applied, found: found),
                       [Data(MobilinkdTNC.setInputGain(4)), reset])
    }

    func testNothingToRestoreWhenNothingWasChanged() {
        XCTAssertEqual(MobilinkdSession.restoreFrames(applied: levels(), found: levels()), [])
        XCTAssertEqual(MobilinkdSession.restoreFrames(applied: nil, found: levels()), [])
        XCTAssertEqual(MobilinkdSession.restoreFrames(applied: levels(), found: nil), [],
                       "without knowing what it held, there is nothing to go back to")
    }

    /// The firmware accepts 1200, 9600 and M17 only, and so does the enum.
    /// An unknown type in `found` must not produce a frame.
    func testAnUnknownModemTypeIsNotSent() {
        XCTAssertEqual(MobilinkdSession.frames(toReach: levels(modem: 2), from: levels(modem: 1)), [])
    }
}

/// Profiles written before the gains were actually sent to the TNC.
final class MobilinkdProfileDefaultsTests: XCTestCase {

    private func decode(_ json: String) throws -> RadioProfile {
        try JSONDecoder().decode(RadioProfile.self, from: Data(json.utf8))
    }

    func testDefaultsMatchTheFirmware() {
        let radio = RadioProfile(id: RadioID(), name: "TNC4")
        XCTAssertEqual(radio.mobilinkdOutputGain, 63)
        XCTAssertEqual(radio.mobilinkdInputGain, 0)
        XCTAssertEqual(MobilinkdConfig().outputGain, 63)
        XCTAssertEqual(MobilinkdConfig().inputGain, 0)
    }

    /// 11 was the old default. It never reached a TNC with Mobilinkd mode off,
    /// and applying it now would make transmit audio far too quiet.
    func testTheOldBogusOutputDefaultIsReplaced() throws {
        let radio = try decode(#"{"id":"r1","name":"A","kind":"ble","mobilinkdEnabled":false,"mobilinkdOutputGain":11}"#)
        XCTAssertEqual(radio.mobilinkdOutputGain, 63)
    }

    /// With Mobilinkd mode on, 11 may be what the operator chose. Leave it.
    func testAChosenOutputGainIsKept() throws {
        let radio = try decode(#"{"id":"r1","name":"A","kind":"ble","mobilinkdEnabled":true,"mobilinkdOutputGain":11}"#)
        XCTAssertEqual(radio.mobilinkdOutputGain, 11)
    }
}

/// The startup watchdog decides whether a TNC4 has gone quiet.
final class MobilinkdStartupReceptionGuardChunkTests: XCTestCase {

    /// A battery reply and a packet can arrive in one BLE notification. The
    /// guard used to stop at the telemetry frame and miss the packet.
    func testAPacketAfterTelemetryInTheSameChunkCounts() {
        let guardian = MobilinkdStartupReceptionGuard()
        var chunk = Data([0xC0, 0x06, 0x06, 0x10, 0x7A, 0xC0])
        let ax25 = AX25.encodeUIFrame(from: AX25Address(call: "N0CALL"), to: AX25Address(call: "APRS"),
                                      via: [], info: Data("hi".utf8))
        chunk.append(KISS.encodeFrame(payload: ax25, port: 0))
        guardian.observeInboundChunk(chunk)
        XCTAssertTrue(guardian.hasSeenInboundKISSFrame)
        XCTAssertTrue(guardian.hasSeenInboundAX25)
    }
}
