import XCTest
@testable import AXTerm

/// What AXTerm sends a TNC4 when a link comes up and goes down.
final class MobilinkdSessionTests: XCTestCase {

    private let reset = Data([0xC0, 0x06, 0x0B, 0xC0])

    /// What the TNC4 in these tests holds: its saved setup for another radio.
    private let owners = MobilinkdSettings(outputGain: 63, outputTwist: 50, inputGain: 4,
                                           inputTwist: 3, modemType: 1, pttMultiplex: true)

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
    func testABLEProfileCarriesItsOwnTimingAndSettings() {
        var radio = RadioProfile(id: RadioID(), name: "IC-V8")
        radio.kind = .ble
        radio.txDelayMs = 500
        radio.tnc4.inputGain = 0
        XCTAssertEqual(radio.bleConfig.timing.frames()[0], Data([0xC0, 0x01, 50, 0xC0]))
        XCTAssertEqual(radio.bleConfig.mobilinkdConfig?.settings.inputGain, 0)
    }

    // MARK: Liveness probe and level read

    func testTheProbeIsAFirmwareVersionQuery() {
        XCTAssertEqual(MobilinkdSession.probe, Data([0xC0, 0x06, 0x28, 0xC0]))
        XCTAssertTrue(MobilinkdSession.isProbeReply(Data([0x06, 0x28, 0x32, 0x2E, 0x35, 0x2E, 0x31, 0x34])))
        XCTAssertFalse(MobilinkdSession.isProbeReply(Data([0x06, 0x06, 0x10, 0x7A])), "a battery reply is not an answer")
    }

    /// Individual queries, none of which touch the TNC4's audio task.
    func testTheLevelReadIsSixQueries() {
        XCTAssertEqual(MobilinkdSession.readRequests, [
            Data([0xC0, 0x06, 0x0C, 0xC0]), Data([0xC0, 0x06, 0x1B, 0xC0]),
            Data([0xC0, 0x06, 0x0D, 0xC0]), Data([0xC0, 0x06, 0x19, 0xC0]),
            Data([0xC0, 0x06, 0xC1, 0x81, 0xC0]), Data([0xC0, 0x06, 0x50, 0xC0]),
        ])
        XCTAssertFalse(MobilinkdSession.readRequests.contains(Data(MobilinkdTNC.getAllValues())))
    }

    /// The managed values are known only once every one of them has arrived.
    func testSettingsAreReadFromTheDeviceReport() {
        var state = MobilinkdDeviceState()
        state.outputGain = 63; state.outputTwist = 50; state.inputGain = 4; state.inputTwist = 3; state.modemType = 1
        XCTAssertNil(MobilinkdSettings(reportedBy: state), "PTT style not in yet")
        state.pttMultiplex = true
        XCTAssertEqual(MobilinkdSettings(reportedBy: state), owners)
    }

    // MARK: Applying

    func testNothingIsSentForFieldsTheProfileLeavesAlone() {
        XCTAssertEqual(MobilinkdSettings.frames(toReach: MobilinkdSettings(), from: owners), [])
    }

    func testOnlyWhatDiffersIsSent() {
        XCTAssertEqual(MobilinkdSettings.frames(toReach: MobilinkdSettings(outputGain: 50), from: owners),
                       [Data(MobilinkdTNC.setOutputGain(50))], "an output change alone needs no RESET")
        XCTAssertEqual(MobilinkdSettings.frames(toReach: MobilinkdSettings(outputGain: 63), from: owners), [],
                       "already there")
    }

    /// Input gain and twist changes leave the TNC4 streaming levels.
    func testInputChangesEndWithReset() {
        XCTAssertEqual(MobilinkdSettings.frames(toReach: MobilinkdSettings(inputGain: 0), from: owners),
                       [Data(MobilinkdTNC.setInputGain(0)), reset])
        XCTAssertEqual(MobilinkdSettings.frames(toReach: MobilinkdSettings(inputTwist: 6), from: owners).last, reset)
    }

    func testModemTypeGoesFirstAndPTTNeedsNoReset() {
        let frames = MobilinkdSettings.frames(
            toReach: MobilinkdSettings(outputTwist: 40, modemType: 3, pttMultiplex: false), from: owners)
        XCTAssertEqual(frames, [Data(MobilinkdTNC.setModemType(.fsk9600)),
                                Data(MobilinkdTNC.setPTTMultiplex(false)),
                                Data(MobilinkdTNC.setOutputTwist(40)),
                                reset])
    }

    /// The firmware accepts 1200, 9600 and M17 only. An unknown type is never
    /// sent, and nothing restarts for a change that wasn't made.
    func testAnUnknownModemTypeIsNotSent() {
        XCTAssertEqual(MobilinkdSettings.frames(toReach: MobilinkdSettings(modemType: 2), from: owners), [])
    }

    /// Connecting always restarts the demodulator. On 2026-09-29 a TNC4 that
    /// had just connected passed up nothing until it did.
    func testConnectingAlwaysEndsWithOneReset() {
        XCTAssertEqual(MobilinkdSession.connectFrames(wanted: nil, found: nil), [reset])
        XCTAssertEqual(MobilinkdSession.connectFrames(wanted: MobilinkdSettings(), found: owners), [reset])
        let frames = MobilinkdSession.connectFrames(wanted: MobilinkdSettings(inputGain: 0), found: owners)
        XCTAssertEqual(frames, [Data(MobilinkdTNC.setInputGain(0)), reset], "no doubled RESET")
    }

    // MARK: Restoring

    /// The point of the whole exercise: a TNC4 shared with another radio goes
    /// back to its owner's settings when AXTerm lets go of it, and only the
    /// fields AXTerm touched are written.
    func testRestoringPutsBackOnlyWhatWasChanged() {
        let applied = MobilinkdSettings(inputGain: 0)
        XCTAssertEqual(MobilinkdSession.restoreFrames(applied: applied, found: owners),
                       [Data(MobilinkdTNC.setInputGain(4)), reset])
    }

    func testNothingToRestoreWhenNothingWasChanged() {
        XCTAssertEqual(MobilinkdSession.restoreFrames(applied: nil, found: owners), [])
        XCTAssertEqual(MobilinkdSession.restoreFrames(applied: MobilinkdSettings(inputGain: 4), found: owners), [],
                       "set to what it already had")
        XCTAssertEqual(MobilinkdSession.restoreFrames(applied: MobilinkdSettings(inputGain: 0), found: nil), [],
                       "without knowing what it held, there is nothing to go back to")
    }

    // MARK: Combining

    func testMergingAndSubtracting() {
        let a = MobilinkdSettings(outputGain: 63, inputGain: 4)
        XCTAssertEqual(a.merging(MobilinkdSettings(inputGain: 0)), MobilinkdSettings(outputGain: 63, inputGain: 0))
        XCTAssertEqual(a.subtracting(MobilinkdSettings(inputGain: 0)), MobilinkdSettings(outputGain: 63))
        XCTAssertEqual(owners.restricted(to: MobilinkdSettings(inputGain: 0)), MobilinkdSettings(inputGain: 4))
    }
}

/// Profiles written before `tnc4` existed.
final class MobilinkdProfileMigrationTests: XCTestCase {

    private func decode(_ json: String) throws -> RadioProfile {
        try JSONDecoder().decode(RadioProfile.self, from: Data(json.utf8))
    }

    func testANewProfileManagesNothing() {
        XCTAssertTrue(RadioProfile(id: RadioID(), name: "TNC4").tnc4.isEmpty)
    }

    /// With Mobilinkd mode off the old scalars never reached a TNC, so they
    /// don't become settings (the old output default of 11 would have made
    /// transmit audio far too quiet).
    func testOldScalarsWithMobilinkdOffAreDropped() throws {
        let radio = try decode(#"{"id":"r1","kind":"ble","mobilinkdEnabled":false,"mobilinkdOutputGain":11,"mobilinkdInputGain":0}"#)
        XCTAssertTrue(radio.tnc4.isEmpty)
    }

    func testOldScalarsWithMobilinkdOnAreKept() throws {
        let radio = try decode(#"{"id":"r1","kind":"serial","mobilinkdEnabled":true,"mobilinkdOutputGain":40,"mobilinkdInputGain":2,"mobilinkdModemType":1}"#)
        XCTAssertEqual(radio.tnc4, MobilinkdSettings(outputGain: 40, inputGain: 2, modemType: 1))
    }

    func testTNC4SettingsSurviveJSON() throws {
        var radio = RadioProfile(id: RadioID(rawValue: "r1"), name: "IC-V8")
        radio.tnc4 = MobilinkdSettings(outputGain: 63, inputGain: 0, pttMultiplex: true)
        let back = try JSONDecoder().decode(RadioProfile.self, from: JSONEncoder().encode(radio))
        XCTAssertEqual(back.tnc4, radio.tnc4)
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

/// A TNC4 reply and another TNC's name share the SetHardware command.
final class MobilinkdReplyVersusTNCNameTests: XCTestCase {

    /// "(2.5.14" is the TNC4's firmware version behind a printable opcode.
    /// It must read as a version, not as a TNC naming itself.
    func testATNC4VersionIsNotATNCName() {
        let frame = Data([0x06, 0x28] + Array("2.5.14".utf8))
        XCTAssertEqual(MobilinkdReply.parse(frame), .firmwareVersion("2.5.14"))
    }

    /// Direwolf's answer starts with 'T' (84, the RX-polarity code) but is
    /// far longer than a one-byte flag, so it stays a name.
    func testDirewolfsAnswerIsNotAPolarityReply() {
        XCTAssertNil(MobilinkdReply.parse(Data([0x06] + Array("TNC:DIREWOLF 1.8".utf8))))
        XCTAssertNil(MobilinkdReply.parse(Data([0x06] + Array("DIREWOLF 1.8".utf8))))
    }
}
