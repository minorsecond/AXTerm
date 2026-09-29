import XCTest
@testable import AXTerm

/// The test tone: a steady mark through the same PTT and channel-access
/// path a frame takes, so what the operator hears while setting drive is
/// what a transmission does.
final class ModemTestToneTests: XCTestCase {

    private func makeEngine() -> (ModemEngine, SyntheticModemIO, RecordingPTTController) {
        var config = SoftModemConfiguration()
        config.txDelayMs = 100
        config.txTailMs = 50
        config.persist = 255
        let io = SyntheticModemIO()
        let ptt = RecordingPTTController()
        return (ModemEngine(configuration: config, audio: io, ptt: ptt, scheduling: .inline), io, ptt)
    }

    private func goertzel(_ audio: [Float], _ hz: Double) -> Double {
        let w = 2 * Double.pi * hz / 48_000
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in audio { let s = Double(x) + coeff * s1 - s2; s2 = s1; s1 = s }
        return (s1 * s1 + s2 * s2 - coeff * s1 * s2).squareRoot() / Double(max(audio.count, 1))
    }

    private func frame(_ text: String) -> Data {
        AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 7), to: AX25Address(call: "TEST", ssid: 0),
                                 via: DigiPath(), pid: 0xF0, payload: Data(text.utf8), displayInfo: text).encodeAX25()
    }

    func testTheToneKeysPlaysMarkForTheAskedTimeAndUnkeys() throws {
        let (engine, io, ptt) = makeEngine()
        try engine.start()
        try engine.requestTestTone(seconds: 0.5)
        io.pump(blocks: 1)
        XCTAssertEqual(ptt.events, [true], "keyed like a frame would be")
        XCTAssertTrue(engine.telemetrySnapshot().ptt)
        io.pump(blocks: 200)
        XCTAssertEqual(ptt.events, [true, false])
        XCTAssertEqual(engine.telemetrySnapshot().framesSent, 0, "a tone is not a frame")

        // 0.5 s at 1200 bd is 600 bits of 40 samples; the device keeps
        // pulling silence after, so count only the tone.
        let rendered = io.renderedOutput
        let first = rendered.firstIndex { abs($0) > 0.01 } ?? 0
        let last = rendered.lastIndex { abs($0) > 0.01 } ?? 0
        XCTAssertEqual(last - first, 600 * 40, accuracy: 600)
        let body = Array(rendered[first...].dropFirst(2000).prefix(20_000))
        XCTAssertGreaterThan(goertzel(body, 1200), 10 * goertzel(body, 2200), "mark, not space")
    }

    func testFramesWaitForTheToneThenGo() throws {
        let (engine, io, ptt) = makeEngine()
        try engine.start()
        try engine.requestTestTone(seconds: 0.2)
        io.pump(blocks: 1)
        let payload = frame("after the tone")
        try engine.enqueue(payload)
        io.pump(blocks: 400)
        XCTAssertEqual(ptt.events, [true, false, true, false], "two keyings: the tone, then the frame")
        XCTAssertEqual(engine.telemetrySnapshot().framesSent, 1)
        XCTAssertEqual(decodeAll(io.renderedOutput, sampleRate: 48_000), [payload])
    }

    func testTheToneNeedsARunningTransmitCapableModem() throws {
        let (engine, _, _) = makeEngine()
        XCTAssertThrowsError(try engine.requestTestTone(seconds: 1)) { XCTAssertEqual($0 as? ModemError, .notRunning) }
        try engine.start()
        var rxOnly = SoftModemConfiguration()
        rxOnly.mode = .g3ruh9600RxIF
        engine.update(configuration: rxOnly)
        XCTAssertThrowsError(try engine.requestTestTone(seconds: 1)) { XCTAssertEqual($0 as? ModemError, .txNotSupportedInMode) }
    }
}
