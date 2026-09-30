import XCTest
@testable import AXTerm

/// The CI-V side of preparing a radio and putting it back, against a radio
/// that remembers its settings (`FakeIcomRadio`).
final class CIVClientPrepTests: XCTestCase {

    private func makeClient(_ radio: FakeIcomRadio, timeout: TimeInterval = 0.2) -> (CIVClient, FakeCIVTransport) {
        let transport = FakeCIVTransport()
        transport.replyDelay = 0
        transport.responder = radio.responder
        let client = CIVClient(transport: transport, requestTimeout: timeout)
        client.open()
        return (client, transport)
    }

    private func hex(_ frame: CIVFrame) -> String {
        frame.encoded().map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - Reading and writing raw values

    func testReadsEverySettingFromTheRadio() async {
        let radio = FakeIcomRadio()
        let (client, _) = makeClient(radio)
        let mode = await client.readPrepValue(.mode)
        let dataMod = await client.readPrepValue(.menuItem(119))
        let attenuator = await client.readPrepValue(.attenuator)
        let rfGain = await client.readPrepValue(.rfGain)
        let squelch = await client.readPrepValue(.squelch)
        let nr = await client.readPrepValue(.noiseReduction)
        let nb = await client.readPrepValue(.noiseBlanker)
        let anf = await client.readPrepValue(.autoNotch)
        let notch = await client.readPrepValue(.manualNotch)
        let tone = await client.readPrepValue(.toneSquelch)
        XCTAssertEqual(mode, [0x01, 0x02, 0x00, 0x00])
        XCTAssertEqual(dataMod, [0x00])
        XCTAssertEqual(attenuator, [0x20])
        XCTAssertEqual(rfGain, [0x01, 0x28])
        XCTAssertEqual(squelch, [0x00, 0x50])
        XCTAssertEqual(nr, [0x01])
        XCTAssertEqual(nb, [0x00])
        XCTAssertEqual(anf, [0x01])
        XCTAssertEqual(notch, [0x00])
        XCTAssertEqual(tone, [0x02])
    }

    func testARefusedReadIsNothing() async {
        let radio = FakeIcomRadio()
        radio["1641"] = nil   // the radio answers NG for a setting it has no value for
        let (client, _) = makeClient(radio)
        let value = await client.readPrepValue(.autoNotch)
        XCTAssertNil(value)
    }

    func testAMissingReplyIsNothing() async {
        let radio = FakeIcomRadio()
        radio.ignoreReads(of: "1641")
        let (client, _) = makeClient(radio, timeout: 0.1)
        let value = await client.readPrepValue(.autoNotch)
        XCTAssertNil(value)
    }

    func testAMalformedReplyIsNothing() async {
        let radio = FakeIcomRadio()
        radio.answerReads(of: "1641", with: [0x07])
        radio.answerReads(of: "1402", with: [0x02])
        radio.answerReads(of: "1A05:0119", with: [])
        let (client, _) = makeClient(radio)
        let anf = await client.readPrepValue(.autoNotch)
        let rf = await client.readPrepValue(.rfGain)
        let menu = await client.readPrepValue(.menuItem(119))
        XCTAssertNil(anf)
        XCTAssertNil(rf)
        XCTAssertNil(menu)
    }

    /// The mode is two reads; either one missing makes the whole value
    /// unknown, since restoring half of it would be a guess.
    func testTheModeNeedsBothReads() async {
        let radio = FakeIcomRadio()
        radio.ignoreReads(of: "1A06")
        let (client, _) = makeClient(radio, timeout: 0.1)
        let value = await client.readPrepValue(.mode)
        XCTAssertNil(value)
    }

    func testWritesAreAcknowledgedOrThrow() async throws {
        let radio = FakeIcomRadio()
        radio.refuseWrites(to: "1641")
        let (client, transport) = makeClient(radio)
        try await client.writePrepValue(.noiseReduction, [0x00])
        XCTAssertEqual(radio["1640"], [0x00])
        do {
            try await client.writePrepValue(.autoNotch, [0x00])
            XCTFail("an NG must throw")
        } catch {
            XCTAssertEqual(error as? CIVError, .rejected(command: 0x16))
        }
        let before = transport.written.count
        do {
            try await client.writePrepValue(.autoNotch, [0x09])
            XCTFail("a malformed value must not be sent")
        } catch {}
        XCTAssertEqual(transport.written.count, before, "nothing went out")
    }

    func testAnUnansweredWriteThrows() async {
        let transport = FakeCIVTransport()
        transport.replyDelay = 0
        transport.responder = { _ in nil }
        let client = CIVClient(transport: transport, requestTimeout: 0.1)
        client.open()
        do {
            try await client.writePrepValue(.autoNotch, [0x00])
            XCTFail("an unanswered write must throw")
        } catch {
            XCTAssertEqual(error as? CIVError, .timeout(command: 0x16))
        }
    }

    // MARK: - Reading the new receive settings for the audit

    func testTheAuditReadsTheNotchesAndTheToneSquelch() async {
        let radio = FakeIcomRadio()
        let (client, _) = makeClient(radio)
        let s = await client.readReceiveSettings(mode: .fm, filter: 1, dataMode: true, toneSquelchFunction: true)
        XCTAssertTrue(s.autoNotch)
        XCTAssertFalse(s.manualNotch)
        XCTAssertEqual(s.toneSquelch, .tsql)
        XCTAssertEqual(s.attenuatorDB, 20)
        XCTAssertTrue(s.answered)
    }

    func testTheToneSquelchIsNotAskedOfAnotherRadio() async {
        let radio = FakeIcomRadio()
        let (client, transport) = makeClient(radio)
        let s = await client.readReceiveSettings(mode: .fm, filter: 1, dataMode: true, toneSquelchFunction: false)
        XCTAssertEqual(s.toneSquelch, .off)
        XCTAssertFalse(transport.written.contains { $0.command == 0x16 && $0.subcommand == 0x5D })
    }

    /// A tone squelch value outside the guide's list is not judged.
    func testAnUnknownToneValueReadsAsOff() async {
        let radio = FakeIcomRadio()
        radio["165D"] = [0x05]
        let (client, _) = makeClient(radio)
        let s = await client.readReceiveSettings(mode: .fm, filter: 1, dataMode: true, toneSquelchFunction: true)
        XCTAssertEqual(s.toneSquelch, .off)
    }

    /// Benign defaults when the radio does not answer the new reads.
    func testUnreadNewSettingsStayBenign() async {
        let radio = FakeIcomRadio()
        radio["1641"] = nil; radio["1648"] = nil; radio["165D"] = nil
        let (client, _) = makeClient(radio)
        let s = await client.readReceiveSettings(mode: .fm, filter: 1, dataMode: true, toneSquelchFunction: true)
        XCTAssertFalse(s.autoNotch)
        XCTAssertFalse(s.manualNotch)
        XCTAssertEqual(s.toneSquelch, .off)
        XCTAssertTrue(s.answered, "the rest answered")
    }

    /// A radio that has stopped answering costs two timeouts, not nine.
    func testASilentRadioIsNotAskedNineTimes() async {
        let transport = FakeCIVTransport()
        transport.replyDelay = 0
        transport.responder = { _ in nil }
        let client = CIVClient(transport: transport, requestTimeout: 0.05)
        client.open()
        let s = await client.readReceiveSettings(mode: .fm, filter: 1, dataMode: true, toneSquelchFunction: true)
        XCTAssertFalse(s.answered)
        XCTAssertEqual(transport.written.count, 2)
    }

    // MARK: - Preparing

    func testPreparingRecordsTheOriginalOfEverythingItWrites() async {
        let radio = FakeIcomRadio()
        let (client, _) = makeClient(radio)
        let report = await client.prepareForPacket(.afsk1200, dataMod: .usb, quietTheBus: true,
                                                   clearsReceive: true, toneSquelchFunction: true)
        XCTAssertNil(report.failure)
        let byKey = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.setting, $0) })
        XCTAssertEqual(byKey[.mode]?.original, [0x01, 0x02, 0x00, 0x00], "USB FIL2, data off, read before the mode was set")
        XCTAssertEqual(byKey[.mode]?.applied, [0x05, 0x01, 0x01, 0x01])
        XCTAssertEqual(byKey[.menuItem(119)]?.original, [0x00])
        XCTAssertEqual(byKey[.menuItem(111)]?.original, [0x01])
        XCTAssertEqual(byKey[.menuItem(125)]?.original, [0x01])
        XCTAssertEqual(byKey[.menuItem(131)]?.original, [0x01])
        for item in [38, 39, 41, 42] { XCTAssertEqual(byKey[.menuItem(item)]?.original, [0x01]) }
        XCTAssertEqual(byKey[.attenuator]?.original, [0x20])
        XCTAssertEqual(byKey[.rfGain]?.original, [0x01, 0x28])
        XCTAssertEqual(byKey[.squelch]?.original, [0x00, 0x50])
        XCTAssertEqual(byKey[.noiseReduction]?.original, [0x01])
        XCTAssertNil(byKey[.noiseBlanker], "already off, so not written and not owed")
        XCTAssertEqual(byKey[.autoNotch]?.original, [0x01])
        XCTAssertNil(byKey[.manualNotch])
        XCTAssertEqual(byKey[.toneSquelch], .init(setting: .toneSquelch, original: [0x02], applied: [0x01]))

        // And the radio is now set up.
        XCTAssertEqual(radio["04"], [0x05, 0x01])
        XCTAssertEqual(radio["1A06"], [0x01, 0x01])
        XCTAssertEqual(radio["11"], [0x00])
        XCTAssertEqual(radio["1402"], [0x02, 0x55])
        XCTAssertEqual(radio["1403"], [0x00, 0x00])
        XCTAssertEqual(radio["1641"], [0x00])
        XCTAssertEqual(radio["165D"], [0x01], "TSQL becomes TONE: the transmit tone is kept")
        XCTAssertEqual(radio["1602"], [0x01], "the preamp is the operator's")
        XCTAssertTrue(report.changed.contains("auto notch off"), report.changed.joined(separator: ", "))
        XCTAssertTrue(report.changed.contains("tone squelch TSQL to TONE"))
    }

    func testAPreparedRadioOwesNothing() async {
        let radio = FakeIcomRadio(FakeIcomRadio.packetSetup())
        let (client, transport) = makeClient(radio)
        let report = await client.prepareForPacket(.afsk1200, dataMod: .usb, quietTheBus: true,
                                                   clearsReceive: true, toneSquelchFunction: true)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.changed, [])
        XCTAssertFalse(transport.written.contains { $0.command == 0x06 })
    }

    /// Without the receive clears, the old recipe: nothing about the notch
    /// or the attenuator is touched.
    func testConfigureForPacketLeavesTheReceiveSettingsAlone() async throws {
        let radio = FakeIcomRadio()
        let (client, _) = makeClient(radio)
        try await client.configureForPacket(.afsk1200, dataMod: .usb)
        XCTAssertEqual(radio["1641"], [0x01])
        XCTAssertEqual(radio["11"], [0x20])
    }

    func testTheToneSquelchIsLeftAloneWithoutConfirmation() async {
        let radio = FakeIcomRadio()
        let (client, transport) = makeClient(radio)
        let report = await client.prepareForPacket(.afsk1200, clearsReceive: true, toneSquelchFunction: false)
        XCTAssertEqual(radio["165D"], [0x02])
        XCTAssertFalse(report.entries.contains { $0.setting == .toneSquelch })
        XCTAssertFalse(transport.written.contains { $0.command == 0x16 && $0.subcommand == 0x5D })
    }

    /// A receive setting the radio will not report is not written blind:
    /// that change could not be put back.
    func testAnUnreadableReceiveSettingIsNotWritten() async {
        let radio = FakeIcomRadio()
        radio["1641"] = nil
        let (client, transport) = makeClient(radio)
        _ = await client.prepareForPacket(.afsk1200, clearsReceive: true, toneSquelchFunction: true)
        XCTAssertFalse(transport.written.contains { $0.command == 0x16 && $0.subcommand == 0x41 && !$0.data.isEmpty })
        XCTAssertEqual(radio["165D"], [0x01], "and the settings after it are still cleared")
    }

    func testARefusedReceiveClearDoesNotFailTheConnect() async {
        let radio = FakeIcomRadio()
        radio.refuseWrites(to: "1641")
        let (client, _) = makeClient(radio)
        let report = await client.prepareForPacket(.afsk1200, clearsReceive: true, toneSquelchFunction: true)
        XCTAssertNil(report.failure)
        XCTAssertFalse(report.entries.contains { $0.setting == .autoNotch }, "nothing changed, nothing owed")
        XCTAssertEqual(radio["165D"], [0x01])
    }

    /// Data mode refused after the mode was set: the connect reports the
    /// failure, and the mode change is still owed back.
    func testAFailureStillReportsWhatChanged() async {
        let radio = FakeIcomRadio()
        radio.refuseWrites(to: "1A06")
        let (client, _) = makeClient(radio)
        let report = await client.prepareForPacket(.afsk1200, clearsReceive: true, toneSquelchFunction: true)
        XCTAssertNotNil(report.failure)
        let mode = report.entries.first { $0.setting == .mode }
        XCTAssertEqual(mode?.original, [0x01, 0x02, 0x00, 0x00])
        XCTAssertEqual(mode?.applied, [0x05, 0x01, 0x00, 0x00], "FM with data off: where the radio actually landed")
    }

    // MARK: - Corrections

    func testACorrectionIsRecorded() async throws {
        let radio = FakeIcomRadio()
        let (client, _) = makeClient(radio)
        let entry = try await client.applyCorrection(.autoNotchOff, mode: .fm)
        XCTAssertEqual(entry, .init(setting: .autoNotch, original: [0x01], applied: [0x00]))
        XCTAssertEqual(radio["1641"], [0x00])
        let again = try await client.applyCorrection(.autoNotchOff, mode: .fm)
        XCTAssertNil(again, "already off: nothing to change")
    }

    /// The widest filter keeps data mode, which `06` alone would clear.
    func testTheWidestFilterKeepsDataMode() async throws {
        let radio = FakeIcomRadio()
        radio["04"] = [0x05, 0x03]; radio["1A06"] = [0x01, 0x03]
        let (client, _) = makeClient(radio)
        _ = try await client.applyCorrection(.widestFilter, mode: .fm)
        XCTAssertEqual(radio["04"], [0x05, 0x01])
        XCTAssertEqual(radio["1A06"], [0x01, 0x01])
    }

    func testAToneCorrectionNeedsToKnowWhatIsSet() async {
        let radio = FakeIcomRadio()
        radio.ignoreReads(of: "165D")
        let (client, _) = makeClient(radio, timeout: 0.1)
        do {
            _ = try await client.applyCorrection(.toneSquelchReceiveOff, mode: .fm)
            XCTFail("without the current value the transmit tone could be lost")
        } catch {}
        XCTAssertEqual(radio["165D"], [0x02])
    }

    func testABlindCorrectionStillHappensWhenTheReadFails() async throws {
        let radio = FakeIcomRadio()
        radio.ignoreReads(of: "1641")
        let (client, _) = makeClient(radio, timeout: 0.1)
        let entry = try await client.applyCorrection(.autoNotchOff, mode: .fm)
        XCTAssertNil(entry, "no original, so nothing to record")
        XCTAssertEqual(radio["1641"], [0x00])
    }

    // MARK: - Restoring

    func testARestorePutsEverythingBackInReverse() async {
        let radio = FakeIcomRadio()
        let original = radio.snapshot
        let (client, transport) = makeClient(radio)
        let report = await client.prepareForPacket(.afsk1200, dataMod: .usb, quietTheBus: true,
                                                   clearsReceive: true, toneSquelchFunction: true)
        let snapshot = RigPrepSnapshot(entries: report.entries)
        let start = transport.written.count
        let outcome = await client.restore(snapshot, deadline: Date().addingTimeInterval(10))

        XCTAssertEqual(outcome.restored.map(\.setting), snapshot.settings.reversed())
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(radio.snapshot, original, "every setting is back as the operator had it")

        let writes = transport.written.dropFirst(start).filter { frame in
            // A write carries data beyond what a read would.
            if frame.command == 0x1A, frame.subcommand == 0x05 { return frame.data.count > 2 }
            return !frame.data.isEmpty
        }
        XCTAssertEqual(writes.map(hex).suffix(2), ["FE FE A4 E0 06 01 02 FD", "FE FE A4 E0 1A 06 00 00 FD"],
                       "the mode goes last, and data mode after it")
        XCTAssertEqual(writes.map(hex).first, "FE FE A4 E0 16 5D 02 FD", "the last change is the first put back")
    }

    func testARestoreLeavesTheOperatorsChanges() async {
        let radio = FakeIcomRadio()
        let (client, _) = makeClient(radio)
        let report = await client.prepareForPacket(.afsk1200, clearsReceive: true, toneSquelchFunction: true)
        radio["1403"] = [0x00, 0x20]   // the operator nudged the squelch
        let outcome = await client.restore(RigPrepSnapshot(entries: report.entries), deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(outcome.changedByOperator.map(\.setting), [.squelch])
        XCTAssertEqual(radio["1403"], [0x00, 0x20], "theirs now")
        XCTAssertEqual(radio["1641"], [0x01], "the rest is put back")
    }

    func testARefusedRestoreStaysOwed() async {
        let radio = FakeIcomRadio()
        let (client, _) = makeClient(radio)
        let report = await client.prepareForPacket(.afsk1200, clearsReceive: true, toneSquelchFunction: true)
        radio.refuseWrites(to: "1641")
        let snapshot = RigPrepSnapshot(entries: report.entries)
        let outcome = await client.restore(snapshot, deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(outcome.failed.map(\.setting), [.autoNotch])
        XCTAssertEqual(RigPrepRestore.remaining(snapshot, after: outcome).settings, [.autoNotch])
        XCTAssertEqual(radio["165D"], [0x02], "a refusal does not stop the others")
    }

    func testARestoreOutOfTimeTriesNothingAndOwesEverything() async {
        let radio = FakeIcomRadio()
        let (client, transport) = makeClient(radio)
        let report = await client.prepareForPacket(.afsk1200, clearsReceive: true, toneSquelchFunction: true)
        let snapshot = RigPrepSnapshot(entries: report.entries)
        let start = transport.written.count
        let outcome = await client.restore(snapshot, deadline: Date().addingTimeInterval(-1))
        XCTAssertEqual(transport.written.count, start, "nothing sent")
        XCTAssertEqual(outcome.notAttempted.count, snapshot.entries.count)
        XCTAssertEqual(RigPrepRestore.remaining(snapshot, after: outcome), snapshot)
    }

    func testRestoringNothingSendsNothing() async {
        let radio = FakeIcomRadio()
        let (client, transport) = makeClient(radio)
        let outcome = await client.restore(RigPrepSnapshot(), deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(outcome, RigPrepRestore.Outcome())
        XCTAssertTrue(transport.written.isEmpty)
    }
}
