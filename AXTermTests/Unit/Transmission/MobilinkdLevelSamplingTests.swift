//
//  MobilinkdLevelSamplingTests.swift
//  AXTermTests
//
//  The session driver's timed level recordings, against a link that only
//  records what is written. Every recording that starts a level stream has
//  to end with RESET, however it ends, because the stream leaves the TNC4's
//  demodulator off until one arrives.
//

import XCTest
@testable import AXTerm

final class MobilinkdLevelSamplingTests: XCTestCase {

    private let stream = Data(MobilinkdTNC.streamInputLevel())
    private let reset = Data(MobilinkdTNC.reset())

    /// A driver on its own queue, and everything it writes.
    private final class Rig: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.mobilinkd.sampling")
        private let lock = NSLock()
        private var _writes: [Data] = []
        var driver: MobilinkdSessionDriver!

        var writes: [Data] { lock.lock(); defer { lock.unlock() }; return _writes }

        init() {
            driver = MobilinkdSessionDriver(hooks: .init(
                queue: queue,
                write: { [weak self] data in self?.record(data) },
                writeSequence: { [weak self] frames, done in
                    frames.forEach { self?.record($0) }
                    done()
                },
                isConnected: { true },
                log: { _ in },
                ready: {},
                silent: {},
                wanted: { MobilinkdSettings() }))
            queue.sync { driver.isMobilinkd = true }
        }

        private func record(_ data: Data) {
            lock.lock()
            _writes.append(data)
            lock.unlock()
        }

        func on(_ body: @escaping (MobilinkdSessionDriver) -> Void) {
            queue.sync { body(driver) }
        }

        /// One level report, as the TNC4 sends it.
        func report(vpp: UInt16) {
            // Values chosen clear of 0xC0 and 0xDB, so no KISS escaping.
            let v: [UInt8] = [UInt8(vpp >> 8), UInt8(vpp & 0xFF), 0x80, 0x00, 0x40, 0x00, 0xA0, 0x00]
            let frame = Data([0xC0, 0x06, 0x04] + v + [0xC0])
            queue.sync { driver.observe(frame) }
        }
    }

    private func sample(_ rig: Rig, _ request: LevelSampleRequest,
                        file: StaticString = #filePath, line: UInt = #line) -> XCTestExpectation {
        let done = expectation(description: "recording ended")
        rig.on { driver in
            driver.sampleLevels(request) { [weak self] result in
                self?.results.append(result)
                done.fulfill()
            }
        }
        return done
    }

    private var results: [LevelSampleResult] = []

    /// Every STREAM written is followed, somewhere later, by a RESET.
    private func assertEveryStreamEndsWithReset(_ writes: [Data], file: StaticString = #filePath, line: UInt = #line) {
        guard let lastStream = writes.lastIndex(of: stream) else { return }
        XCTAssertTrue(writes[(lastStream + 1)...].contains(reset), "a stream with no RESET after it: \(writes.map { Array($0) })",
                      file: file, line: line)
    }

    override func setUp() {
        super.setUp()
        results = []
    }

    func testARecordingStreamsCollectsAndEndsWithReset() {
        let rig = Rig()
        let done = sample(rig, .now(for: 0.4))
        XCTAssertEqual(rig.writes, [stream])
        XCTAssertEqual(rig.driver.activity, .sampling)
        rig.report(vpp: 0x2904)
        rig.report(vpp: 0x2A10)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(rig.writes, [stream, reset])
        XCTAssertEqual(results.first?.outcome, .completed)
        XCTAssertEqual(results.first?.samples.map(\.vpp), [0x2904, 0x2A10])
        XCTAssertEqual(rig.driver.activity, .idle)
    }

    func testCancelSendsReset() {
        let rig = Rig()
        let done = sample(rig, .now(for: 5))
        rig.report(vpp: 0x3000)
        rig.on { $0.cancelSampling() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(results.first?.outcome, .cancelled)
        XCTAssertEqual(rig.writes, [stream, reset])
        XCTAssertEqual(rig.driver.activity, .idle)
    }

    func testClosingTheLinkMidRecordingPutsResetInTheClosingFrames() {
        let rig = Rig()
        let done = sample(rig, .now(for: 5))
        var closing: [Data] = []
        rig.on { closing = $0.closingFrames() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(results.first?.outcome, .disconnected)
        XCTAssertEqual(closing.last, reset)
        assertEveryStreamEndsWithReset(rig.writes + closing)
        // Nothing left running that could write later.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(rig.writes, [stream])
    }

    /// The link dropped: nothing can be written, the recording reports it,
    /// and no timer writes into the next connection.
    func testALinkDropEndsTheRecordingWithNothingLeftBehind() {
        let rig = Rig()
        let done = sample(rig, .now(for: 0.3))
        rig.on { $0.connectionEnded() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(results.first?.outcome, .disconnected)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(rig.writes, [stream])
        XCTAssertEqual(results.count, 1)
    }

    /// Waits for the frame, starts after its estimated end, ends with RESET.
    func testAfterNextTransmissionStartsWhenTheFrameShouldBeDone() {
        let rig = Rig()
        let timing = KISSTimingParameters(txDelayMs: 0, persistence: 255, slotTimeMs: 0, txTailMs: 0)
        let done = sample(rig, LevelSampleRequest(
            start: .afterNextTransmission(timing: timing, delay: 0.05, armTimeout: 5), duration: 0.2))
        XCTAssertEqual(rig.writes, [], "nothing until the frame goes")
        XCTAssertEqual(rig.driver.activity, .sampling)
        // A 16-byte AX.25 frame: about 0.18 s on the air, plus 0.1 s of link.
        let frame = Data([0xC0, 0x00] + Array(repeating: 0x41, count: 16) + [0xC0])
        let sentAt = Date()
        rig.on { $0.willSend(frame) }
        let started = expectation(description: "stream asked for")
        DispatchQueue.global().async {
            while !rig.writes.contains(self.stream) { usleep(5_000) }
            started.fulfill()
        }
        wait(for: [started], timeout: 2)
        let waited = Date().timeIntervalSince(sentAt)
        XCTAssertGreaterThan(waited, 0.25)
        XCTAssertLessThan(waited, 0.9)
        rig.report(vpp: 0x2000)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(results.first?.outcome, .completed)
        XCTAssertEqual(rig.writes, [stream, reset])
        // Times count from the estimated end of the transmission.
        XCTAssertGreaterThan(results.first?.samples.first?.t ?? 0, 0.04)
    }

    func testNoTransmissionWritesNothing() {
        let rig = Rig()
        let done = sample(rig, LevelSampleRequest(
            start: .afterNextTransmission(timing: .default, delay: 0.3, armTimeout: 0.2), duration: 1))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(results.first?.outcome, .noTransmission)
        XCTAssertEqual(rig.writes, [])
        XCTAssertEqual(rig.driver.activity, .idle)
    }

    func testHardwareFramesDontCountAsTheTransmission() {
        let rig = Rig()
        let done = sample(rig, LevelSampleRequest(
            start: .afterNextTransmission(timing: .default, delay: 0.3, armTimeout: 0.3), duration: 1))
        rig.on { $0.willSend(Data(MobilinkdTNC.pollBatteryLevelAndResume())) }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(results.first?.outcome, .noTransmission)
    }

    /// A frame going out mid-recording: RESET first, so the demodulator is
    /// back for CSMA, and the recording keeps what it had.
    func testAFrameMidRecordingStopsItWithReset() {
        let rig = Rig()
        let done = sample(rig, .now(for: 5))
        rig.report(vpp: 0x2100)
        rig.on { $0.willSend(Data([0xC0, 0x00, 0x41, 0x42, 0xC0])) }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(results.first?.outcome, .interrupted)
        XCTAssertEqual(results.first?.samples.count, 1)
        XCTAssertEqual(rig.writes, [stream, reset])
    }

    /// The TNC4 ends a stream when it keys up or unkeys; ask again.
    func testAStreamThatStopsIsAskedForAgain() {
        let rig = Rig()
        let done = sample(rig, .now(for: 2.2))
        rig.report(vpp: 0x2000)
        wait(for: [done], timeout: 4)
        let streams = rig.writes.filter { $0 == stream }.count
        XCTAssertGreaterThanOrEqual(streams, 2)
        XCTAssertLessThanOrEqual(streams, 1 + MobilinkdSessionDriver.maxStreamRestarts)
        XCTAssertEqual(results.first?.restarts, streams - 1)
        XCTAssertEqual(rig.writes.last, reset)
    }

    func testATestToneMidRecordingResetsFirst() {
        let rig = Rig()
        let done = sample(rig, .now(for: 5))
        rig.on { $0.startTone(.mark, for: 1) }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(results.first?.outcome, .interrupted)
        XCTAssertEqual(rig.writes.prefix(2), [stream, reset])
        rig.on { $0.stopTone() }
    }

    func testASettingsChangeMidRecordingResetsFirst() {
        let rig = Rig()
        let done = sample(rig, .now(for: 5))
        rig.on { $0.wantedChanged(from: MobilinkdSettings(inputGain: 3)) }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(results.first?.outcome, .interrupted)
        XCTAssertEqual(rig.writes.prefix(2), [stream, reset])
    }

    func testBusyTNCIsNotRecorded() {
        let rig = Rig()
        rig.on { $0.startMeasuring() }
        let done = sample(rig, .now(for: 1))
        wait(for: [done], timeout: 1)
        XCTAssertEqual(results.first?.outcome, .unavailable)
        XCTAssertEqual(rig.writes, [stream], "only the measurement's own stream")
        rig.on { $0.stopMeasuring() }
    }

    func testOneRecordingAtATime() {
        let rig = Rig()
        let first = sample(rig, .now(for: 0.3))
        let second = sample(rig, .now(for: 0.3))
        wait(for: [second], timeout: 1)
        XCTAssertEqual(results.first?.outcome, .unavailable)
        wait(for: [first], timeout: 2)
        XCTAssertEqual(rig.writes, [stream, reset])
    }

    // MARK: Airtime

    func testDataFrameLengthsUnescapeAndSkipHardware() {
        let data = Data([0xC0, 0x06, 0x0B, 0xC0, 0xC0, 0x00, 0x41, 0xDB, 0xDC, 0x42, 0xC0, 0xC0, 0x10, 0x01, 0xC0])
        XCTAssertEqual(TNC4Airtime.dataFrameLengths(in: data), [3, 1])
    }

    func testTransmitSeconds() {
        let timing = KISSTimingParameters(txDelayMs: 500, persistence: 63, slotTimeMs: 100, txTailMs: 50)
        // 500 ms of flags, (60 + 4) bytes × 8 × 1.05 at 1200 bps, 50 ms of tail.
        XCTAssertEqual(TNC4Airtime.transmitSeconds(frameBytes: 60, timing: timing), 0.5 + 0.448 + 0.05, accuracy: 0.001)
    }
}
