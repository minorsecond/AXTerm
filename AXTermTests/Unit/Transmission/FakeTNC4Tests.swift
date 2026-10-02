//
//  FakeTNC4Tests.swift
//  AXTermTests
//
//  The fake TNC4 against what a real one said, then AXTerm's session driver
//  against the fake.
//
//  The driver tests are the point. Whatever AXTerm does to a TNC4 on
//  connect, during a session and on close, three things must hold:
//  - nothing is written to the TNC4's EEPROM (the TNC4 is shared with other
//    radios, and what one radio needs is wrong for the next);
//  - when the driver is idle the demodulator is running, so packets from
//    the air reach AXTerm;
//  - on close the TNC4 holds the settings it had before AXTerm connected.
//

import XCTest
@testable import AXTerm

final class FakeTNC4Tests: XCTestCase {

    // MARK: The fake against a real TNC4

    /// A fake set up like the TNC4 the captured replies came from.
    private func capturedUnit() -> (FakeTNC4, () -> [[UInt8]]) {
        var eeprom = FakeTNC4.Settings()
        eeprom.outputGain = 63
        eeprom.inputGain = 4
        eeprom.inputTwist = 3
        eeprom.outputTwist = 50
        eeprom.txDelay = 30
        eeprom.options = 0   // multiplex PTT
        let tnc = FakeTNC4(eeprom: eeprom)
        var parser = KISSFrameParser()
        var replies: [[UInt8]] = []
        tnc.toHost = { data in
            for frame in parser.feed(data) {
                if case .mobilinkdTelemetry(let bytes) = frame { replies.append(Array(bytes)) }
            }
        }
        tnc.connect()
        return (tnc, { replies })
    }

    /// Replies captured from a TNC4 Rev B on firmware 2.5.14 (2026-09-29;
    /// see MobilinkdDeviceStateTests).
    func testRepliesMatchTheCapturedTNC4ByteForByte() {
        let (tnc, replies) = capturedUnit()
        let asks: [[UInt8]] = [
            MobilinkdTNC.getFirmwareVersion(), MobilinkdTNC.getHardwareVersion(),
            MobilinkdTNC.getOutputGain(), MobilinkdTNC.getInputGain(),
            MobilinkdTNC.getInputTwist(), MobilinkdTNC.getOutputTwist(),
            MobilinkdTNC.getTimingValue(33), MobilinkdTNC.getPTTChannel(),
            MobilinkdTNC.pollBatteryLevel(), MobilinkdTNC.getModemType(), MobilinkdTNC.getModemTypes(),
        ]
        for ask in asks { tnc.receive(Data(ask)) }
        XCTAssertEqual(replies(), [
            [0x06, 0x28, 0x32, 0x2E, 0x35, 0x2E, 0x31, 0x34],
            [0x06, 0x29] + Array("Mobilinkd TNC4 Rev B".utf8),
            [0x06, 0x0C, 0x00, 0x3F],
            [0x06, 0x0D, 0x00, 0x04],
            [0x06, 0x19, 0x03],
            [0x06, 0x1B, 0x32],
            [0x06, 0x21, 0x1E],
            [0x06, 0x50, 0x01],
            [0x06, 0x06, 0x10, 0x7A],
            [0x06, 0xC1, 0x81, 0x01],
            [0x06, 0xC1, 0x83, 0x01, 0x03, 0x05],
        ])
    }

    /// Everything GET_ALL_VALUES sends parses into a complete device state.
    func testAllValuesFillsTheDeviceState() {
        let (tnc, replies) = capturedUnit()
        tnc.receive(Data(MobilinkdTNC.getAllValues()))
        var state = MobilinkdDeviceState()
        for reply in replies() { if let r = MobilinkdReply.parse(Data(reply)) { state.apply(r) } }
        XCTAssertNotNil(MobilinkdSettings(reportedBy: state))
        XCTAssertEqual(state.firmwareVersion, "2.5.14")
        XCTAssertEqual(state.macAddress, "00:1A:7D:DA:71:13")
        XCTAssertEqual(state.maxInputGain, 4)
        XCTAssertEqual(tnc.audio, .idle, "GET_ALL_VALUES leaves the demodulator off")
    }

    /// The firmware's decoder goes back to waiting for a FEND after a frame,
    /// so two frames sharing one FEND lose the second. AXTerm's own writes
    /// give every frame both of its FENDs.
    func testFramesSharingAFENDLoseTheSecondAndAXTermNeverSendsThem() {
        let (tnc, replies) = capturedUnit()
        tnc.receive(Data([0xC0, 0x06, 0x0C, 0xC0, 0x06, 0x0D, 0xC0]))
        XCTAssertEqual(replies().count, 1, "the firmware drops the frame after a shared FEND")

        let (tnc2, replies2) = capturedUnit()
        let everything = MobilinkdSession.statusRequests.reduce(Data(), +)
        tnc2.receive(everything)
        // One reply per request. The last request is two frames, the
        // battery poll and RESET, and RESET is not answered.
        XCTAssertEqual(replies2().count, MobilinkdSession.statusRequests.count,
                       "a request was lost to a shared FEND")
        XCTAssertEqual(tnc2.audio, .demodulating, "the status read ends with RESET")
    }

    func testSaveAndAdjustWriteEEPROMAndNothingElseDoes() {
        let (tnc, _) = capturedUnit()
        let before = tnc.eeprom
        for frame in [MobilinkdTNC.setOutputGain(10), MobilinkdTNC.setInputGain(1),
                      MobilinkdTNC.setInputTwist(-2), MobilinkdTNC.setOutputTwist(70),
                      MobilinkdTNC.setPTTMultiplex(false), MobilinkdTNC.setModemType(.fsk9600)] {
            tnc.receive(Data(frame))
        }
        XCTAssertEqual(tnc.eepromWrites, 0)
        XCTAssertEqual(tnc.eeprom, before)
        tnc.powerCycle()
        XCTAssertEqual(tnc.ram, before, "RAM-only changes are gone after a power cycle")

        tnc.connect()
        tnc.receive(Data(MobilinkdTNC.saveEEPROM()))
        XCTAssertEqual(tnc.eepromWrites, 1)
        tnc.receive(Data([0xC0, 0x06, 0x2B, 0xC0]))
        XCTAssertEqual(tnc.eepromWrites, 2, "the firmware's auto-adjust saves too")
    }

    // MARK: AXTerm's session driver against the fake

    /// The driver on its own queue, wired to a fake TNC4 the way a link is:
    /// writes go to the TNC4, and what it sends comes back through observe.
    private final class Rig: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.fake-tnc4")
        let tnc: FakeTNC4
        var driver: MobilinkdSessionDriver!
        var wanted = MobilinkdSettings()
        private(set) var ready = false
        private(set) var silent = false
        private(set) var heardByHost = 0

        init(eeprom: FakeTNC4.Settings = FakeTNC4.Settings()) {
            tnc = FakeTNC4(eeprom: eeprom)
            driver = MobilinkdSessionDriver(hooks: .init(
                queue: queue,
                write: { [weak self] data in self?.tnc.receive(data) },
                writeSequence: { [weak self] frames, done in
                    frames.forEach { self?.tnc.receive($0) }
                    self?.queue.async { done() }
                },
                isConnected: { [weak self] in self?.ready ?? false },
                log: { _ in },
                ready: { [weak self] in self?.ready = true },
                silent: { [weak self] in self?.silent = true },
                wanted: { [weak self] in self?.wanted ?? MobilinkdSettings() }))
            tnc.toHost = { [weak self] data in
                guard let self else { return }
                // The transport hands the driver a copy and the app the rest.
                self.queue.async {
                    self.driver.observe(data)
                    if data.count > 2, data[1] == 0x00 { self.heardByHost += 1 }
                }
            }
        }

        func on(_ body: @escaping (MobilinkdSessionDriver, FakeTNC4) -> Void) {
            queue.sync { body(driver, tnc) }
        }

        /// Lets queued replies and completions run.
        func settle(_ seconds: TimeInterval = 0.3) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { queue.sync {}; usleep(5_000) }
        }

        func connect() {
            on { driver, tnc in
                tnc.connect()
                driver.isMobilinkd = true
                driver.begin()
            }
            settle()
        }

        func close() {
            on { driver, tnc in
                for frame in driver.closingFrames() { tnc.receive(frame) }
                driver.linkClosed()
                tnc.disconnect()
            }
            settle(0.1)
        }

        /// A packet off the air, and whether AXTerm got it.
        func packetGetsThrough() -> Bool {
            let before = heardByHost
            on { _, tnc in tnc.heard(Data(repeating: 0x41, count: 20)) }
            settle(0.05)
            return heardByHost > before
        }
    }

    private func ownersSettings() -> FakeTNC4.Settings {
        var s = FakeTNC4.Settings()
        s.outputGain = 63; s.inputGain = 4; s.inputTwist = 3; s.outputTwist = 50; s.options = 0
        return s
    }

    func testConnectAppliesTheRadiosSettingsInRAMAndLeavesTheReceiverRunning() {
        let rig = Rig(eeprom: ownersSettings())
        rig.wanted = MobilinkdSettings(outputGain: 40, outputTwist: 60, inputGain: 1, inputTwist: -2,
                                       modemType: 1, pttMultiplex: false)
        rig.connect()
        XCTAssertTrue(rig.ready)
        rig.on { _, tnc in
            XCTAssertEqual(tnc.ram.outputGain, 40)
            XCTAssertEqual(tnc.ram.outputTwist, 60)
            XCTAssertEqual(tnc.ram.inputGain, 1)
            XCTAssertEqual(tnc.ram.inputTwist, -2)
            XCTAssertFalse(tnc.ram.pttMultiplex)
            XCTAssertEqual(tnc.eepromWrites, 0, "connecting saved to the TNC4's EEPROM")
            XCTAssertEqual(tnc.audio, .demodulating, "connecting left the TNC4 deaf")
        }
        XCTAssertTrue(rig.packetGetsThrough())
    }

    func testCloseLeavesTheTNC4AsItWasFound() {
        let owner = ownersSettings()
        let rig = Rig(eeprom: owner)
        rig.wanted = MobilinkdSettings(outputGain: 40, inputGain: 1, inputTwist: -2, pttMultiplex: false)
        rig.connect()
        rig.close()
        rig.on { _, tnc in
            XCTAssertEqual(tnc.ram, owner, "the TNC4 was not put back")
            XCTAssertEqual(tnc.eepromWrites, 0)
        }
    }

    func testAProfileThatManagesNothingChangesNothing() {
        let owner = ownersSettings()
        let rig = Rig(eeprom: owner)
        rig.connect()
        rig.on { _, tnc in XCTAssertEqual(tnc.ram, owner) }
        XCTAssertTrue(rig.packetGetsThrough())
        rig.close()
        rig.on { _, tnc in XCTAssertEqual(tnc.ram, owner) }
    }

    func testStatusMeasuringAndTonesAllEndWithTheReceiverRunning() {
        let rig = Rig(eeprom: ownersSettings())
        rig.connect()

        rig.on { driver, _ in driver.refreshStatus() }
        rig.settle()
        XCTAssertTrue(rig.packetGetsThrough(), "the status read left the TNC4 deaf")

        rig.on { driver, tnc in
            driver.startMeasuring()
            XCTAssertEqual(tnc.audio, .streamingLevels)
            driver.stopMeasuring()
        }
        XCTAssertTrue(rig.packetGetsThrough(), "measuring left the TNC4 deaf")

        rig.on { driver, tnc in
            driver.startTone(.both, for: 30)
            XCTAssertTrue(tnc.pttKeyed)
            driver.stopTone()
            XCTAssertFalse(tnc.pttKeyed, "the tone did not stop")
        }
        XCTAssertTrue(rig.packetGetsThrough(), "the tone left the TNC4 deaf")
    }

    func testClosingDuringAToneUnkeysTheRadio() {
        let rig = Rig(eeprom: ownersSettings())
        rig.connect()
        rig.on { driver, tnc in
            driver.startTone(.mark, for: 30)
            XCTAssertTrue(tnc.pttKeyed)
        }
        rig.close()
        rig.on { _, tnc in XCTAssertFalse(tnc.pttKeyed, "closing left the radio keyed") }
    }

    func testChangingTheProfileWhileMeasuringKeepsMeasuring() {
        let rig = Rig(eeprom: ownersSettings())
        rig.wanted = MobilinkdSettings(inputGain: 2)
        rig.connect()
        rig.on { driver, _ in driver.startMeasuring() }
        let old = rig.wanted
        rig.wanted = MobilinkdSettings(inputGain: 3)
        rig.on { driver, tnc in
            driver.wantedChanged(from: old)
            XCTAssertEqual(tnc.ram.inputGain, 3)
            XCTAssertEqual(tnc.audio, .streamingLevels, "the change ended the measurement")
            driver.stopMeasuring()
        }
        XCTAssertTrue(rig.packetGetsThrough())
    }

    /// Random sessions: profile changes, status reads, measurements and
    /// tones in any order, then close.
    @MainActor
    func testRandomSessionsNeverSaveAndAlwaysPutTheTNC4Back() {
        checkProperty("faketnc4.driver.sessions", cases: 60) { rng, violations in
            let owner = ownersSettings()
            let rig = Rig(eeprom: owner)
            func randomProfile() -> MobilinkdSettings {
                MobilinkdSettings(
                    outputGain: rng.chance(0.5) ? rng.int(in: 0...128) : nil,
                    outputTwist: rng.chance(0.4) ? rng.int(in: 0...100) : nil,
                    inputGain: rng.chance(0.5) ? rng.int(in: 0...4) : nil,
                    inputTwist: rng.chance(0.4) ? rng.int(in: -3...9) : nil,
                    modemType: rng.chance(0.2) ? rng.pick([1, 3]) : nil,
                    pttMultiplex: rng.chance(0.4) ? rng.chance(0.5) : nil)
            }
            rig.wanted = randomProfile()
            rig.connect()
            var log = ["connect \(rig.wanted)"]
            for _ in 0..<rng.int(in: 1...8) {
                switch rng.int(4) {
                case 0:
                    let old = rig.wanted
                    rig.wanted = randomProfile()
                    log.append("profile \(rig.wanted)")
                    rig.on { driver, _ in driver.wantedChanged(from: old) }
                    rig.settle(0.1)
                case 1:
                    log.append("status")
                    rig.on { driver, _ in driver.refreshStatus() }
                    rig.settle(0.1)
                case 2:
                    log.append("measure")
                    rig.on { driver, _ in driver.startMeasuring(); driver.stopMeasuring() }
                default:
                    log.append("tone")
                    rig.on { driver, _ in driver.startTone(.both, for: 30); driver.stopTone() }
                }
                if !rig.packetGetsThrough() {
                    violations.record("deaf after \(log.joined(separator: ", "))")
                }
            }
            rig.close()
            rig.on { _, tnc in
                violations.check(tnc.eepromWrites == 0, "saved to EEPROM: \(log.joined(separator: ", "))")
                violations.check(tnc.ram == owner, "not put back: \(tnc.ram) after \(log.joined(separator: ", "))")
                violations.check(!tnc.pttKeyed, "left keyed")
            }
        }
    }
}
