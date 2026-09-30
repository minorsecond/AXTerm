//
//  ReceiveLevelMonitorTests.swift
//  AXTermTests
//
//  The monitor against a stand-in TNC4: calibration sends one beacon at
//  most, respects the ten-minute limit, changes nothing when it hears
//  nothing, and the drift watch samples only when the radio is idle.
//

import XCTest
@testable import AXTerm

@MainActor
final class ReceiveLevelMonitorTests: XCTestCase {

    /// Records what the monitor asks of the TNC4 and lets the test answer.
    private final class FakeControl: MobilinkdControlling, @unchecked Sendable {
        var isMobilinkd = true
        var mobilinkdActivity: MobilinkdActivity = .idle
        var requests: [LevelSampleRequest] = []
        var pending: (@Sendable (LevelSampleResult) -> Void)?
        var cancels = 0

        func refreshMobilinkdStatus() {}
        func startMeasuringInput() {}
        func stopMeasuringInput() {}
        func startTestTone(_ tone: MobilinkdTestTone, for seconds: TimeInterval) {}
        func stopTestTone() {}
        func saveSettingsToTNC() {}

        func sampleInputLevels(_ request: LevelSampleRequest,
                               completion: @escaping @Sendable (LevelSampleResult) -> Void) {
            requests.append(request)
            pending = completion
        }

        func cancelInputSampling() {
            cancels += 1
            let done = pending
            pending = nil
            done?(LevelSampleResult(outcome: .cancelled, samples: []))
        }

        func finish(_ result: LevelSampleResult) {
            let done = pending
            pending = nil
            done?(result)
        }
    }

    private let radio = RadioID(rawValue: "tnc4")
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var control: FakeControl!
    private var profile: RadioProfile!
    private var connected = true
    private var lastActivity: Date?
    private var beacons = 0
    private var beaconObstacle: String?
    private var managedGain: Int??
    private var notes: [String] = []
    private var store: ReceiveLevelStore!

    override func setUp() {
        super.setUp()
        control = FakeControl()
        profile = RadioProfile(id: radio, name: "TNC4 Mobilinkd")
        profile.aprsEnabled = true
        connected = true
        lastActivity = nil
        beacons = 0
        beaconObstacle = nil
        managedGain = nil
        notes = []
        store = ReceiveLevelStore(defaults: TestDefaults.make("receive-level-monitor"))
    }

    private func makeMonitor() -> ReceiveLevelMonitor {
        ReceiveLevelMonitor(dependencies: .init(
            control: { [unowned self] _ in self.connected ? self.control : nil },
            profile: { [unowned self] _ in self.profile },
            connectedRadios: { [unowned self] in self.connected ? [self.radio] : [] },
            lastActivity: { [unowned self] _ in self.lastActivity },
            currentGain: { [unowned self] _ in self.profile.tnc4.inputGain ?? 0 },
            gainRange: { _ in 0...4 },
            setManagedGain: { [unowned self] _, gain in
                self.managedGain = .some(gain)
                self.profile.tnc4.inputGain = gain
            },
            sendBeacon: { [unowned self] _ in
                if let obstacle = self.beaconObstacle { return obstacle }
                self.beacons += 1
                return nil
            },
            notify: { [unowned self] text, _ in self.notes.append(text) },
            log: { _, _ in },
            store: store,
            now: { [unowned self] in self.now },
            random: { 0.5 }))
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func digipeatWindow() -> [TNC4LevelSample] {
        var s = LevelSeries(seed: 21)
        s.noise(0.8)
        s.packet(seconds: 0.6)
        s.noise(1.8)
        s.packet(tone: 10_300, seconds: 0.8)
        s.noise(1.5)
        return s.samples
    }

    // MARK: Calibration

    func testCalibrationSendsOneBeaconAndAppliesTheGain() async {
        let monitor = makeMonitor()
        monitor.calibrate(radio)
        XCTAssertEqual(beacons, 1)
        XCTAssertEqual(control.requests.count, 1)
        guard case .afterNextTransmission(let timing, let delay, _) = control.requests.first?.start else {
            return XCTFail("calibration waits for the beacon")
        }
        XCTAssertEqual(timing, profile.kissTiming)
        XCTAssertEqual(delay, ReceiveLevelMonitor.calibrationDelay)
        XCTAssertTrue(monitor.isBusy(radio))

        control.finish(LevelSampleResult(outcome: .completed, samples: digipeatWindow()))
        await settle()

        XCTAssertEqual(managedGain, .some(1))
        guard case .finished(let report) = monitor.calibrations[radio] else { return XCTFail("no report") }
        XCTAssertTrue(report.succeeded)
        XCTAssertTrue(report.message.hasPrefix("Set to +6 dB. Heard 2 digipeats at 16% at 0 dB."), report.message)
        XCTAssertTrue(report.message.contains("+6 dB puts them near 32%."))
        XCTAssertFalse(report.evidence.isEmpty)
        let baseline = monitor.record(radio).baseline
        XCTAssertEqual(baseline?.gain, 1)
        XCTAssertEqual(baseline?.source, .beacon)
        XCTAssertEqual(baseline?.packets, 2)
        XCTAssertEqual(store.load(radio).lastCalibrationBeaconAt, now)
        XCTAssertEqual(notes.count, 1)

        // Undo puts the TNC4's own gain back.
        monitor.undoCalibration(radio)
        XCTAssertEqual(managedGain, .some(nil))
        XCTAssertNil(monitor.record(radio).baseline)
    }

    func testASecondCalibrationWithinTenMinutesSendsNothing() async {
        let monitor = makeMonitor()
        monitor.calibrate(radio)
        control.finish(LevelSampleResult(outcome: .completed, samples: digipeatWindow()))
        await settle()
        now = now.addingTimeInterval(9 * 60)
        monitor.calibrate(radio)
        XCTAssertEqual(beacons, 1)
        XCTAssertEqual(control.requests.count, 1)
        guard case .finished(let report) = monitor.calibrations[radio] else { return XCTFail() }
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.message.contains("next can go at"))
        XCTAssertNotNil(monitor.nextCalibrationAllowed(radio))

        now = now.addingTimeInterval(61)
        XCTAssertNil(monitor.nextCalibrationAllowed(radio))
        monitor.calibrate(radio)
        XCTAssertEqual(beacons, 2)
    }

    /// The limit survives a restart: it is stored with the record.
    func testTheLimitSurvivesARestart() {
        makeMonitor().calibrate(radio)
        XCTAssertEqual(beacons, 1)
        let fresh = makeMonitor()
        now = now.addingTimeInterval(60)
        fresh.calibrate(radio)
        XCTAssertEqual(beacons, 1)
    }

    func testNothingHeardChangesNothing() async {
        let monitor = makeMonitor()
        profile.tnc4.inputGain = 2
        monitor.calibrate(radio)
        var s = LevelSeries()
        s.noise(5.7)
        control.finish(LevelSampleResult(outcome: .completed, samples: s.samples))
        await settle()
        XCTAssertNil(managedGain)
        XCTAssertEqual(profile.tnc4.inputGain, 2)
        XCTAssertNil(monitor.record(radio).baseline)
        guard case .finished(let report) = monitor.calibrations[radio] else { return XCTFail() }
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.message.hasPrefix("No digipeater was heard"), report.message)
        XCTAssertTrue(report.message.contains("nothing was changed"))
    }

    func testABeaconThatCantGoCancelsTheRecording() {
        beaconObstacle = "No station position yet."
        let monitor = makeMonitor()
        monitor.calibrate(radio)
        XCTAssertEqual(control.cancels, 1)
        XCTAssertNil(store.load(radio).lastCalibrationBeaconAt, "no beacon, so no limit")
        guard case .finished(let report) = monitor.calibrations[radio] else { return XCTFail() }
        XCTAssertEqual(report.message, "The beacon wasn't sent: No station position yet.")
    }

    func testPacketChannelsNeverSendACalibrationBeacon() {
        profile.aprsEnabled = false
        let monitor = makeMonitor()
        monitor.calibrate(radio)
        XCTAssertEqual(beacons, 0)
        XCTAssertTrue(control.requests.isEmpty)
    }

    func testABusyTNC4IsLeftAlone() {
        control.mobilinkdActivity = .measuring
        let monitor = makeMonitor()
        monitor.calibrate(radio)
        XCTAssertEqual(beacons, 0)
        XCTAssertTrue(control.requests.isEmpty)
    }

    func testADisconnectMidCalibrationChangesNothing() async {
        let monitor = makeMonitor()
        monitor.calibrate(radio)
        control.finish(LevelSampleResult(outcome: .disconnected, samples: []))
        await settle()
        XCTAssertNil(managedGain)
        guard case .finished(let report) = monitor.calibrations[radio] else { return XCTFail() }
        XCTAssertFalse(report.succeeded)
    }

    // MARK: Drift watch

    func testTheWatchWaitsThenSamplesWhenIdle() async {
        let monitor = makeMonitor()
        monitor.tick()
        XCTAssertTrue(control.requests.isEmpty, "the first check waits a couple of minutes")
        now = now.addingTimeInterval(ReceiveLevelMonitor.firstWatchDelay + 60)
        lastActivity = now.addingTimeInterval(-2)
        monitor.tick()
        XCTAssertTrue(control.requests.isEmpty, "a frame 2 s ago: not now")
        now = now.addingTimeInterval(30)
        monitor.tick()
        XCTAssertEqual(control.requests.first, .now(for: ReceiveLevelMonitor.sampleSeconds))

        var s = LevelSeries(seed: 4)
        s.noise(2)
        control.finish(LevelSampleResult(outcome: .completed, samples: s.samples))
        await settle()
        let obs = monitor.record(radio).observations
        XCTAssertEqual(obs.count, 1)
        XCTAssertTrue((30_000...40_000).contains(obs.first?.noiseVpp ?? 0))

        // Next check about half an hour later, not sooner.
        now = now.addingTimeInterval(20 * 60)
        monitor.tick()
        XCTAssertEqual(control.requests.count, 1)
        now = now.addingTimeInterval(15 * 60)
        monitor.tick()
        XCTAssertEqual(control.requests.count, 2)
    }

    func testTheWatchCanBeTurnedOff() {
        let monitor = makeMonitor()
        monitor.setWatchEnabled(false, for: radio)
        monitor.tick()
        now = now.addingTimeInterval(3_600)
        monitor.tick()
        XCTAssertTrue(control.requests.isEmpty)
        XCTAssertFalse(store.load(radio).watchEnabled)
    }

    func testTheWatchSkipsABusyTNC4() {
        let monitor = makeMonitor()
        monitor.tick()
        now = now.addingTimeInterval(3_600)
        control.mobilinkdActivity = .sendingTone(.mark)
        monitor.tick()
        XCTAssertTrue(control.requests.isEmpty)
    }

    /// A louder radio after calibration raises a finding, logged to the
    /// console once.
    func testDriftAfterCalibrationBecomesAFinding() async {
        let monitor = makeMonitor()
        profile.tnc4.inputGain = 1
        var r = ReceiveLevelRecord()
        r.baseline = ReceiveLevelBaseline(at: now, gain: 1, toneVpp: 21_000, noiseVpp: 20_000)
        store.save(r, for: radio)

        monitor.tick()
        for _ in 0..<2 {
            now = now.addingTimeInterval(40 * 60)
            monitor.tick()
            var s = LevelSeries(seed: 9)
            s.noise(2, scale: 1.45) // about 50,000: +8 dB over 20,000
            control.finish(LevelSampleResult(outcome: .completed, samples: s.samples))
            await settle()
        }
        let finding = monitor.finding(for: radio)
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.message.contains("louder than when calibrated") ?? false, finding?.message ?? "")
        XCTAssertEqual(finding?.retune, .calibrate)
        XCTAssertEqual(notes.filter { $0.contains("louder") }.count, 1)
    }

    func testDigipeatsLearnedFromOurFrames() {
        let monitor = makeMonitor()
        for i in 0..<8 {
            let sent = now.addingTimeInterval(Double(i) * 600)
            monitor.noteTransmitted(radio: radio, isUI: true, viaDigipeaters: true, at: sent)
            monitor.noteEcho(radio: radio, digipeater: "WA0DE-3", at: sent.addingTimeInterval(2))
        }
        for i in 8..<11 {
            monitor.noteTransmitted(radio: radio, isUI: true, viaDigipeaters: true, at: now.addingTimeInterval(Double(i) * 600))
        }
        // Frames with no path, and connected-mode frames, are not chances.
        monitor.noteTransmitted(radio: radio, isUI: true, viaDigipeaters: false, at: now.addingTimeInterval(6_700))
        monitor.noteTransmitted(radio: radio, isUI: false, viaDigipeaters: true, at: now.addingTimeInterval(6_710))
        let finding = monitor.finding(for: radio, now: now.addingTimeInterval(7_200))
        XCTAssertTrue(finding?.message.hasPrefix("None of your last 3 frames on TNC4 Mobilinkd were heard repeated") ?? false,
                      finding?.message ?? "nil")
    }

    func testNoFindingForARadioThatIsntConnected() {
        let monitor = makeMonitor()
        connected = false
        XCTAssertNil(monitor.finding(for: radio))
    }

    // MARK: Passive

    func testPassiveRecommendationFromWatchPackets() async {
        profile.aprsEnabled = false
        let monitor = makeMonitor()
        monitor.tick()
        for seed in UInt64(1)...3 {
            now = now.addingTimeInterval(40 * 60)
            monitor.tick()
            var s = LevelSeries(seed: seed)
            s.noise(0.5)
            s.packet(seconds: 0.7)
            s.noise(0.7)
            control.finish(LevelSampleResult(outcome: .completed, samples: s.samples))
            await settle()
        }
        let advice = monitor.passiveAdvice(for: radio)
        XCTAssertEqual(advice?.packets, 3)
        XCTAssertEqual(advice?.recommendation.gain, 1)
        monitor.applyPassive(radio)
        XCTAssertEqual(managedGain, .some(1))
        XCTAssertEqual(monitor.record(radio).baseline?.source, .passive)
        XCTAssertEqual(beacons, 0)
    }
}
