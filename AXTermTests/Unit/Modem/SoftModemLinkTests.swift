import XCTest
@testable import AXTerm

/// The modem as a KISS link: KISS in, audio out; audio in, KISS out.
@MainActor
final class SoftModemLinkTests: XCTestCase {

    private final class Recorder: KISSLinkDelegate {
        var received: [Data] = []
        var states: [KISSLinkState] = []
        var errors: [String] = []
        func linkDidReceive(_ data: Data) { received.append(data) }
        func linkDidChangeState(_ state: KISSLinkState) { states.append(state) }
        func linkDidError(_ message: String) { errors.append(message) }
    }

    private func makeLink(configure: (inout SoftModemConfiguration) -> Void = { _ in },
                          io: SyntheticModemIO = SyntheticModemIO())
    -> (SoftModemLink, SyntheticModemIO, RecordingPTTController, Recorder) {
        var config = SoftModemConfiguration()
        config.txDelayMs = 100
        config.txTailMs = 50
        config.persist = 255
        configure(&config)
        let ptt = RecordingPTTController()
        // Deliver synchronously: the test runs on the main actor already.
        let link = SoftModemLink(configuration: config, audio: io, ptt: ptt,
                                 inputName: "USB Audio CODEC", outputName: "USB Audio CODEC",
                                 scheduling: .inline,
                                 deliver: { work in MainActor.assumeIsolated { work() } })
        let recorder = Recorder()
        link.delegate = recorder
        return (link, io, ptt, recorder)
    }

    private func ax25(_ text: String) -> Data {
        AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 7), to: AX25Address(call: "CQ", ssid: 0),
                                 via: DigiPath(), pid: 0xF0, payload: Data(text.utf8), displayInfo: text).encodeAX25()
    }

    func testOpenConnectsAndCloseDisconnects() {
        let (link, _, _, recorder) = makeLink()
        XCTAssertEqual(link.state, .disconnected)
        link.open()
        XCTAssertEqual(link.state, .connected)
        link.open()
        XCTAssertEqual(recorder.states, [.connecting, .connected], "open is idempotent")
        link.close()
        XCTAssertEqual(link.state, .disconnected)
        XCTAssertEqual(link.endpointDescription, "softmodem afsk1200 in:USB Audio CODEC out:USB Audio CODEC")
    }

    func testAFailedStartIsReported() {
        let io = SyntheticModemIO()
        io.startError = ModemAudioError.permissionDenied
        let (link, _, _, recorder) = makeLink(io: io)
        link.open()
        XCTAssertEqual(link.state, .failed)
        XCTAssertEqual(recorder.states, [.connecting, .failed])
        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertTrue(recorder.errors[0].contains("Microphone") || recorder.errors[0].contains("microphone"))
    }

    /// The whole loop: a KISS frame in, audio rendered, that audio captured,
    /// the same KISS frame delivered on the configured port.
    func testKISSInBecomesAudioAndAudioBecomesKISSOut() {
        let (link, io, ptt, recorder) = makeLink { $0.kissPort = 2 }
        link.open()
        let frame = ax25("round trip")
        var sendResult: Error? = TestError(text: "not called")
        link.send(KISS.encodeFrame(payload: frame, port: 2)) { sendResult = $0 }
        XCTAssertNil(sendResult, "accepted by the link")

        io.pump(blocks: 250)
        XCTAssertEqual(ptt.events, [true, false])
        let transmitted = io.renderedOutput
        XCTAssertFalse(transmitted.allSatisfy { $0 == 0 })

        // Feed the transmission back in as received audio.
        io.feed(transmitted)
        io.pump(blocks: 100)
        XCTAssertEqual(recorder.received, [KISS.encodeFrame(payload: frame, port: 2)])
    }

    func testSendBeforeOpenFails() {
        let (link, _, _, _) = makeLink()
        var result: Error?
        link.send(KISS.encodeFrame(payload: ax25("early")), completion: { result = $0 })
        XCTAssertEqual(result as? ModemError, .notRunning)
    }

    func testKISSCommandFramesTuneTheModem() {
        let (link, _, _, _) = makeLink()
        link.open()
        // TXDELAY 0x01 = 50 (×10 ms), P 0x02 = 128, SlotTime 0x03 = 20, TXtail 0x04 = 3, FullDuplex 0x05 = 1
        for (command, value): (UInt8, UInt8) in [(0x01, 50), (0x02, 128), (0x03, 20), (0x04, 3), (0x05, 1)] {
            link.send(Data([KISS.FEND, command, value, KISS.FEND])) { XCTAssertNil($0) }
        }
        let c = link.currentConfiguration
        XCTAssertEqual(c.txDelayMs, 500)
        XCTAssertEqual(c.persist, 128)
        XCTAssertEqual(c.slotTimeMs, 200)
        XCTAssertEqual(c.txTailMs, 30)
        XCTAssertTrue(c.fullDuplex)
    }

    func testAFullQueueIsAnError() {
        let (link, _, _, _) = makeLink { $0.maxQueuedFrames = 1 }
        link.open()
        link.send(KISS.encodeFrame(payload: ax25("one"))) { XCTAssertNil($0) }
        var second: Error?
        link.send(KISS.encodeFrame(payload: ax25("two"))) { second = $0 }
        XCTAssertEqual(second as? ModemError, .queueFull)
    }

    func testDeviceLossFailsTheLink() {
        let (link, io, _, recorder) = makeLink()
        link.open()
        io.simulateDeviceLost()
        XCTAssertEqual(link.state, .failed)
        XCTAssertEqual(recorder.states.last, .failed)
        XCTAssertEqual(recorder.errors, ["Audio device lost"])
    }

    func testTelemetryIsReadable() {
        let (link, io, _, _) = makeLink()
        link.open()
        io.pump(blocks: 5)
        XCTAssertEqual(link.telemetry.audioFormat?.sampleRate, 48_000)
        XCTAssertFalse(link.telemetry.ptt)
    }
}
