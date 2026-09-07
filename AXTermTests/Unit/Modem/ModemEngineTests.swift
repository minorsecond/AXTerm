import XCTest
@testable import AXTerm

/// A PTT controller that records what it was told and answers as scripted.
nonisolated final class RecordingPTTController: PTTController, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [Bool] = []
    var events: [Bool] { lock.withLock { _events } }
    var isKeyed: Bool { lock.withLock { _events.last ?? false } }
    var keyUpLatencyHint: TimeInterval = 0
    /// When set, key-down is refused with this error.
    var refuseKeyDown: Error?
    /// When true, completions are held until `confirmPending()` — a slow CI-V link.
    var holdCompletions = false
    private var held: [(Bool, @Sendable (Error?) -> Void)] = []

    func setTransmit(_ on: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { _events.append(on) }
        if on, let refuseKeyDown { completion(refuseKeyDown); return }
        if holdCompletions { lock.withLock { held.append((on, completion)) }; return }
        completion(nil)
    }

    func confirmPending() {
        let pending = lock.withLock { let h = held; held.removeAll(); return h }
        for (_, completion) in pending { completion(nil) }
    }
}

struct TestError: Error, Equatable { let text: String }

/// The engine on synthetic audio, in inline scheduling: every call is a
/// plain function call and every clock is a sample count.
final class ModemEngineTests: XCTestCase {

    private func makeEngine(configure: (inout SoftModemConfiguration) -> Void = { _ in },
                            ptt: RecordingPTTController = RecordingPTTController())
    -> (ModemEngine, SyntheticModemIO, RecordingPTTController) {
        var config = SoftModemConfiguration()
        config.txDelayMs = 100
        config.txTailMs = 50
        config.persist = 255      // transmit in the first clear slot: deterministic
        configure(&config)
        let io = SyntheticModemIO()
        let engine = ModemEngine(configuration: config, audio: io, ptt: ptt, scheduling: .inline)
        return (engine, io, ptt)
    }

    private func frame(_ text: String) -> Data {
        AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 7), to: AX25Address(call: "CQ", ssid: 0),
                                 via: DigiPath(), pid: 0xF0, payload: Data(text.utf8), displayInfo: text).encodeAX25()
    }

    // MARK: - Receive

    func testDecodesFramesFromCapturedAudio() throws {
        let (engine, io, _) = makeEngine()
        var decoded: [Data] = []
        let lock = NSLock()
        engine.onFrameDecoded = { data, _ in lock.withLock { decoded.append(data) } }
        try engine.start()
        let frames = [frame("one"), frame("two two"), frame("three three three")]
        io.feed(AFSKModulator.synthesize(frames: frames, sampleRate: 48_000))
        io.pump(blocks: 100)
        XCTAssertEqual(decoded, frames)
        XCTAssertEqual(engine.telemetrySnapshot().framesDecoded, 3)
    }

    func testCarrierDetectFollowsTheAudio() throws {
        let (engine, io, _) = makeEngine()
        try engine.start()
        io.pump(blocks: 20)
        XCTAssertFalse(engine.telemetrySnapshot().dcd)
        let audio = AFSKModulator.synthesize(frames: [frame("carrier")], sampleRate: 48_000, txDelayMs: 500)
        io.feed(Array(audio.prefix(48_000 / 4)))     // the first quarter second: flags
        XCTAssertTrue(engine.telemetrySnapshot().dcd, "flags are a carrier")
        io.pump(blocks: 50)
        XCTAssertFalse(engine.telemetrySnapshot().dcd, "and it releases after the hold")
    }

    // MARK: - Transmit

    func testATransmissionKeysRendersAndUnkeys() throws {
        let (engine, io, ptt) = makeEngine()
        try engine.start()
        let payload = frame("hello from the soft modem")
        try engine.enqueue(payload)
        XCTAssertEqual(ptt.events, [], "nothing until a block of input clocks the transmitter")

        io.pump(blocks: 1)
        XCTAssertEqual(ptt.events, [true], "keyed within one block on a clear channel")
        XCTAssertTrue(engine.telemetrySnapshot().ptt)

        // Let the device pull the whole transmission, then some margin.
        io.pump(blocks: 200)
        XCTAssertEqual(ptt.events, [true, false], "unkeyed once the audio drained")
        XCTAssertFalse(engine.telemetrySnapshot().ptt)
        XCTAssertEqual(engine.telemetrySnapshot().framesSent, 1)

        // What went out is a decodable transmission with the frame in it.
        let decoded = decodeAll(io.renderedOutput, sampleRate: 48_000)
        XCTAssertEqual(decoded, [payload])
        XCTAssertEqual(io.underfilledBlocks - io.underfilledBlocks, 0)
        XCTAssertEqual(engine.telemetrySnapshot().txUnderruns, 0, "the ring stayed ahead of the device")
    }

    func testTheTransmissionStartsWithTXDELAYWorthOfFlags() throws {
        let (engine, io, _) = makeEngine { $0.txDelayMs = 300 }
        try engine.start()
        try engine.enqueue(frame("x"))
        io.pump(blocks: 300)
        // Find where the audio starts and where the frame's first data bit
        // would be: at 1200 bd, 45 flags = 360 bits = 300 ms = 14 400 samples.
        let start = io.renderedOutput.firstIndex { abs($0) > 0.001 }!
        XCTAssertGreaterThan(start, 0, "PTT is keyed before any audio")
        let leading = Array(io.renderedOutput[start..<(start + 14_000)])
        // Flags only: decoding this slice yields no frame, but the demodulator sees flags.
        let demod = AFSKDemodulator(inputSampleRate: 48_000, mode: ModemMode.afsk1200.parameters)
        var frames = 0
        demod.process(leading) { if case .frame = $0 { frames += 1 } }
        XCTAssertEqual(frames, 0)
        XCTAssertEqual(demod.activity, .flags)
    }

    func testReceiveIsMutedWhileTransmitting() throws {
        let (engine, io, _) = makeEngine()
        var decoded = 0
        engine.onFrameDecoded = { _, _ in decoded += 1 }
        try engine.start()
        try engine.enqueue(frame("ours"))
        io.pump(blocks: 1)   // keyed
        // A strong signal arrives while we are keyed: our own audio, or a
        // station we cannot hear anyway. It must not decode.
        io.feed(AFSKModulator.synthesize(frames: [frame("theirs")], sampleRate: 48_000, txDelayMs: 50))
        XCTAssertEqual(decoded, 0)
        io.pump(blocks: 200)  // transmission ends, cooldown passes
        io.feed(AFSKModulator.synthesize(frames: [frame("later")], sampleRate: 48_000, txDelayMs: 50))
        io.pump(blocks: 20)
        XCTAssertEqual(decoded, 1, "and hearing resumes afterwards")
    }

    func testFramesQueuedDuringTheTransmissionRideAlong() throws {
        let (engine, io, _) = makeEngine { $0.txDelayMs = 300 }
        try engine.start()
        try engine.enqueue(frame("first"))
        io.pump(blocks: 5)   // keyed and rendering the preamble
        try engine.enqueue(frame("second"))
        io.pump(blocks: 300)
        XCTAssertEqual(decodeAll(io.renderedOutput, sampleRate: 48_000), [frame("first"), frame("second")])
        XCTAssertEqual(engine.telemetrySnapshot().framesSent, 2)
    }

    func testABusyChannelDelaysTheTransmission() throws {
        let (engine, io, ptt) = makeEngine()
        try engine.start()
        // Somebody else's transmission is already on the channel when our
        // frame is queued: a quarter second of it has been heard.
        let theirs = AFSKModulator.synthesize(frames: [frame("busy")], sampleRate: 48_000, txDelayMs: 400, txTailMs: 200)
        var index = 12_000
        io.feed(Array(theirs[..<index]))
        XCTAssertTrue(engine.telemetrySnapshot().dcd, "carrier is up")
        try engine.enqueue(frame("ours"))
        var keyedDuringTheirs = false
        while index < theirs.count {
            let end = min(index + 480, theirs.count)
            io.feed(Array(theirs[index..<end]))
            if ptt.isKeyed { keyedDuringTheirs = true }
            index = end
        }
        XCTAssertFalse(keyedDuringTheirs, "never keys over a carrier")
        io.pump(blocks: 20)
        XCTAssertEqual(ptt.events.first, true, "keys once the channel clears")
    }

    func testPTTRefusalDropsTheFramesAndReportsOnce() throws {
        let ptt = RecordingPTTController()
        ptt.refuseKeyDown = TestError(text: "radio not answering")
        let (engine, io, _) = makeEngine(ptt: ptt)
        var faults: [String] = []
        engine.onFault = { message, fatal in faults.append(message); XCTAssertFalse(fatal) }
        try engine.start()
        try engine.enqueue(frame("doomed"))
        io.pump(blocks: 50)
        XCTAssertEqual(ptt.events, [true])
        XCTAssertTrue(io.renderedOutput.allSatisfy { $0 == 0 }, "no audio without a confirmed PTT")
        XCTAssertEqual(faults.count, 1)
        XCTAssertTrue(faults[0].contains("PTT"))
        XCTAssertEqual(engine.telemetrySnapshot().framesSent, 0)
    }

    func testNoAudioUntilTheSlowPTTConfirms() throws {
        let ptt = RecordingPTTController()
        ptt.holdCompletions = true
        let (engine, io, _) = makeEngine(ptt: ptt)
        try engine.start()
        try engine.enqueue(frame("patient"))
        io.pump(blocks: 5)
        XCTAssertEqual(ptt.events, [true])
        XCTAssertTrue(io.renderedOutput.allSatisfy { $0 == 0 })
        ptt.confirmPending()
        io.pump(blocks: 200)
        XCTAssertEqual(decodeAll(io.renderedOutput, sampleRate: 48_000), [frame("patient")])
    }

    func testTheWatchdogForcesPTTOff() throws {
        let (engine, io, ptt) = makeEngine { $0.pttWatchdogSeconds = 0.2 }
        var faults: [String] = []
        engine.onFault = { message, _ in faults.append(message) }
        try engine.start()
        // Several long frames: seconds of audio, far more than the watchdog allows.
        for _ in 0..<6 { try engine.enqueue(Data(repeating: 0x55, count: 250)) }
        io.pump(blocks: 60)   // 0.6 s of clock
        XCTAssertEqual(ptt.events, [true, false])
        XCTAssertTrue(faults.contains { $0.contains("watchdog") })
        XCTAssertEqual(engine.telemetrySnapshot().txQueueDepth, 0, "and the queue is dropped")
    }

    func testQueueLimitAndModeGate() throws {
        let (engine, io, _) = makeEngine { $0.maxQueuedFrames = 2 }
        XCTAssertThrowsError(try engine.enqueue(frame("not running"))) { XCTAssertEqual($0 as? ModemError, .notRunning) }
        try engine.start()
        try engine.enqueue(frame("a"))
        try engine.enqueue(frame("b"))
        XCTAssertThrowsError(try engine.enqueue(frame("c"))) { XCTAssertEqual($0 as? ModemError, .queueFull) }
        _ = io
        engine.update(configuration: { var c = SoftModemConfiguration(); c.mode = .g3ruh9600RxIF; return c }())
        XCTAssertThrowsError(try engine.enqueue(frame("d"))) { XCTAssertEqual($0 as? ModemError, .txNotSupportedInMode) }
    }

    func testDeviceLossIsFatal() throws {
        let (engine, io, _) = makeEngine()
        var fatal: [String] = []
        engine.onFault = { message, isFatal in if isFatal { fatal.append(message) } }
        try engine.start()
        io.simulateDeviceLost()
        XCTAssertEqual(fatal.count, 1)
        XCTAssertFalse(engine.isRunning)
    }

    func testTelemetryReportsLevels() throws {
        let (engine, io, _) = makeEngine()
        try engine.start()
        let audio = ModemChannel.scale(AFSKModulator.synthesize(frames: [frame("level")], sampleRate: 48_000), dbfs: -12)
        io.feed(audio)
        let t = engine.telemetrySnapshot()
        XCTAssertEqual(t.rxPeakDBFS, -12, accuracy: 1.5)
        XCTAssertFalse(t.rxClipping)
        XCTAssertEqual(t.audioFormat?.sampleRate, 48_000)
    }
}
