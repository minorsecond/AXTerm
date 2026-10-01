//
//  ModemTransmitTailTests.swift
//  AXTermTests
//
//  What the sound modem does after the last sample of a transmission, and
//  how it tells Warbler from a radio. On 2026-09-30 the IC-705, keyed
//  through Warbler, stayed on the air about 0.7 s after each frame: 300 ms
//  of trailing silence from AXTerm moved Warbler's last-audio time, and
//  Warbler then waited out the radio's buffer after it. A TNC4 answered
//  inside that window and was not heard. Warbler already holds a client's
//  unkey until the audio has played, so a Warbler client needs neither the
//  silence nor its own drain margin. A radio reached directly still does.
//

import XCTest
@testable import AXTerm

final class ModemTransmitTailTests: XCTestCase {

    // MARK: - Telling Warbler from a radio

    private func bytes(_ hex: String) -> Data {
        let chars = Array(hex)
        var out = [UInt8]()
        var i = 0
        while i + 1 < chars.count {
            if let b = UInt8(String(chars[i...(i + 1)]), radix: 16) { out.append(b) }
            i += 2
        }
        return Data(out)
    }

    /// Capabilities as Warbler's virtual IC-705 builds them
    /// (`icom_packet.cpp`, `capabilities` and `replyIdFor`): the reply ID has
    /// 0x10 0x80 at 7 and 8 and Warbler's address at 10 to 15.
    private func warblerCapabilities(address: [UInt8] = [0x02, 0x57, 0x42, 0x4C, 0x45, 0x52]) -> Data {
        var b = [UInt8](repeating: 0, count: 168)
        b[0] = 0xA8
        var reply = [UInt8](repeating: 0, count: 16)
        reply[7] = 0x10
        reply[8] = 0x80
        reply.replaceSubrange(10..<16, with: address)
        b.replaceSubrange(66..<82, with: reply)
        b.replaceSubrange(82..<88, with: Array("IC-705".utf8))
        b[146] = 0x01
        b[148] = 0xA4
        return Data(b)
    }

    /// A real IC-705's capabilities, the capture pinned in
    /// `IcomLANPacketTests.testParsesRealCapabilities`.
    private var realIC705Capabilities: Data {
        bytes("a8000000000003000b4bd82cdd17905000000098020200010000e665710c3fdb00000000000000000000000000000000000000000000000000000000000000000001000000000000001080000090c7155d0d49432d373035000000000000000000000000000000000000000000000000000049434f4d5f56415544494f0000000000000000000000000000000000000000000707a4018b018b01010100004b000150009001000000")
    }

    func testWarblersCapabilitiesNameIt() {
        let caps = IcomLAN.parseCapabilities(warblerCapabilities())
        XCTAssertEqual(caps?.radioName, "IC-705", "Warbler calls itself an IC-705, so the name cannot tell")
        XCTAssertEqual(caps?.isWarbler, true)
    }

    func testARealIC705IsNotWarbler() {
        let caps = IcomLAN.parseCapabilities(realIC705Capabilities)
        XCTAssertEqual(caps?.radioName, "IC-705")
        XCTAssertEqual(caps?.isWarbler, false)
        XCTAssertEqual(Array(caps?.replyID[10..<13] ?? []), [0x00, 0x90, 0xC7], "Icom's address block")
    }

    func testOnlyWarblersWholeAddressCounts() {
        XCTAssertFalse(IcomLAN.isWarbler(replyID: [UInt8](repeating: 0, count: 16)))
        XCTAssertFalse(IcomLAN.parseCapabilities(warblerCapabilities(address: [0x02, 0x57, 0x42, 0x4C, 0x45, 0x00]))?.isWarbler ?? true)
        XCTAssertFalse(IcomLAN.isWarbler(replyID: [0, 0, 0, 0, 0, 0, 0, 0x10, 0x80, 0, 0x02, 0x57, 0x42]),
                       "a short reply ID is not Warbler")
        var shifted = [UInt8](repeating: 0, count: 16)
        shifted.replaceSubrange(9..<15, with: IcomLAN.warblerAddress)
        XCTAssertFalse(IcomLAN.isWarbler(replyID: shifted), "the address has to be where Warbler puts it")
    }

    func testTheSessionNotesWarblerDuringTheHandshake() {
        let session = IcomLANSession(configuration: .init(host: "127.0.0.1", username: "u", password: "p"))
        XCTAssertFalse(session.viaWarbler)
        XCTAssertEqual(LANModemAudioIO.transmitTail(for: session), .radio)
        session.testReceiveControl(warblerCapabilities())
        XCTAssertTrue(session.viaWarbler)
        XCTAssertEqual(session.radioName, "IC-705")
        XCTAssertEqual(LANModemAudioIO.transmitTail(for: session), .warbler)
    }

    func testTheSessionKeepsARealRadioARadio() {
        let session = IcomLANSession(configuration: .init(host: "192.168.0.50", username: "u", password: "p"))
        session.testReceiveControl(realIC705Capabilities)
        XCTAssertFalse(session.viaWarbler)
        XCTAssertEqual(LANModemAudioIO.transmitTail(for: session), .radio)
    }

    func testThePolicyFollowsTheSession() {
        XCTAssertEqual(ModemTransmitTail.forIcomLAN(viaWarbler: true), .warbler)
        XCTAssertEqual(ModemTransmitTail.forIcomLAN(viaWarbler: false), .radio)
        XCTAssertTrue(ModemTransmitTail.radio.sendsTrailingSilence)
        XCTAssertTrue(ModemTransmitTail.radio.waitsForRadioBuffer)
        XCTAssertFalse(ModemTransmitTail.warbler.sendsTrailingSilence)
        XCTAssertFalse(ModemTransmitTail.warbler.waitsForRadioBuffer)
    }

    func testASoundDeviceDrivesTheRadioDirectly() {
        XCTAssertEqual(SyntheticModemIO().transmitTail, .radio)
        XCTAssertEqual(LANModemAudioIO(session: nil).transmitTail, .radio, "nothing is known before start")
    }

    // MARK: - Trailing silence on the network audio stream

    /// Frames a gate sends out of `count` empty ones after the transmission.
    private func silenceAfterTransmission(_ gate: inout TrailingSilenceGate, count: Int = 60) -> Int {
        (0..<count).filter { _ in gate.shouldSend(written: 0, moreToCome: false) }.count
    }

    func testADirectRadioGetsThreeHundredMillisecondsOfSilence() {
        var gate = TrailingSilenceGate(tail: .radio)
        XCTAssertTrue(gate.shouldSend(written: 320, moreToCome: true))
        XCTAssertTrue(gate.shouldSend(written: 320, moreToCome: false), "audio still in the ring")
        XCTAssertTrue(gate.shouldSend(written: 75, moreToCome: false), "the last frame, partly filled")
        XCTAssertEqual(silenceAfterTransmission(&gate), 15)
    }

    func testWarblerGetsNoSilenceAfterTheFlags() {
        var gate = TrailingSilenceGate(tail: .warbler)
        XCTAssertTrue(gate.shouldSend(written: 320, moreToCome: true))
        XCTAssertTrue(gate.shouldSend(written: 320, moreToCome: false), "audio still in the ring")
        XCTAssertTrue(gate.shouldSend(written: 75, moreToCome: false), "the last frame still goes, padded")
        XCTAssertEqual(silenceAfterTransmission(&gate), 0)
    }

    func testAnUnderrunInsideATransmissionIsSentAsSilence() {
        for tail in [ModemTransmitTail.radio, .warbler] {
            var gate = TrailingSilenceGate(tail: tail)
            XCTAssertTrue(gate.shouldSend(written: 320, moreToCome: true))
            // The engine fell behind for longer than any trailing allowance.
            for frame in 0..<40 {
                XCTAssertTrue(gate.shouldSend(written: 0, moreToCome: true),
                              "\(tail): underrun frame \(frame) keeps the stream's timing")
            }
            XCTAssertTrue(gate.shouldSend(written: 320, moreToCome: true), "\(tail): audio resumes in place")
        }
    }

    func testTheNextTransmissionStartsAtOnce() {
        for tail in [ModemTransmitTail.radio, .warbler] {
            var gate = TrailingSilenceGate(tail: tail)
            XCTAssertTrue(gate.shouldSend(written: 100, moreToCome: false))
            _ = silenceAfterTransmission(&gate)
            XCTAssertTrue(gate.shouldSend(written: 320, moreToCome: true), "\(tail): its first frame goes")
        }
    }

    func testAnIdleWarblerLinkSendsNothing() {
        var gate = TrailingSilenceGate(tail: .warbler)
        XCTAssertEqual(silenceAfterTransmission(&gate), 0)
    }

    // MARK: - When the engine unkeys

    private struct Transmission {
        var output: [Float]
        var ptt: [Bool]
        /// The block the last nonzero sample went out in.
        var lastAudioBlock: Int
        /// The block during which PTT off was sent.
        var unkeyBlock: Int
        var firstAudioSample: Int
        var lastAudioSample: Int
        var underruns: UInt64
        var framesSent: UInt64
    }

    private let blockSize = 480
    private let txTailMs = 100
    private let txDelayMs = 100

    private func frame(_ text: String) -> Data {
        AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 2), to: AX25Address(call: "K0EPI", ssid: 3),
                                 via: DigiPath(), pid: 0xF0, payload: Data(text.utf8), displayInfo: text).encodeAX25()
    }

    /// One frame through the engine with the latencies a LAN link reports:
    /// a 300 ms radio buffer plus 100 ms (`LANModemAudioIO`) and the CI-V
    /// key-up hint of 30 ms (`CIVPTTController`).
    private func transmit(_ payload: Data, tail: ModemTransmitTail) throws -> Transmission {
        var config = SoftModemConfiguration()
        config.txDelayMs = txDelayMs
        config.txTailMs = txTailMs
        config.persist = 255
        let io = SyntheticModemIO(blockSize: blockSize)
        io.latency.outputSeconds = 0.4
        io.transmitTail = tail
        let ptt = RecordingPTTController()
        ptt.keyUpLatencyHint = 0.03
        let engine = ModemEngine(configuration: config, audio: io, ptt: ptt, scheduling: .inline)
        try engine.start()
        try engine.enqueue(payload)
        var unkeyBlock: Int?
        for block in 0..<400 {
            io.pump(blocks: 1)
            if unkeyBlock == nil, ptt.events.count >= 2 { unkeyBlock = block }
        }
        let output = io.renderedOutput
        let first = try XCTUnwrap(output.firstIndex { abs($0) > 1e-6 })
        let last = try XCTUnwrap(output.lastIndex { abs($0) > 1e-6 })
        let snapshot = engine.telemetrySnapshot()
        engine.stop()
        return Transmission(output: output, ptt: ptt.events, lastAudioBlock: last / blockSize,
                            unkeyBlock: try XCTUnwrap(unkeyBlock), firstAudioSample: first, lastAudioSample: last,
                            underruns: snapshot.txUnderruns, framesSent: snapshot.framesSent)
    }

    /// Bits in the whole transmission: TXDELAY flags, the frame, TXTAIL flags.
    private func transmissionBits(_ payload: Data) -> Int {
        var encoder = HDLCEncoder(baud: 1200, txDelayMs: txDelayMs, txTailMs: txTailMs)
        encoder.append(frame: payload)
        var bits = 0
        while encoder.nextBit() != nil { bits += 1 }
        return bits
    }

    func testADirectRadioKeepsTheKeyForItsBufferAndMargin() throws {
        let t = try transmit(frame("direct to the radio"), tail: .radio)
        XCTAssertEqual(t.ptt, [true, false])
        // Drained one block after the last sample, then 450 ms of margin:
        // 0.4 + 0.03 + 0.02 s at 48 kHz is 21 600 samples, 45 blocks.
        XCTAssertEqual(t.unkeyBlock - t.lastAudioBlock, 46, "the existing margin is unchanged")
    }

    func testWarblerIsUnkeyedAsSoonAsTheLastSampleIsHandedOver() throws {
        let t = try transmit(frame("through Warbler"), tail: .warbler)
        XCTAssertEqual(t.ptt, [true, false])
        // The block after the one that took the last sample: the engine
        // learns the ring is empty on its next pass and unkeys on that pass.
        XCTAssertEqual(t.unkeyBlock, t.lastAudioBlock + 1)
    }

    /// Through Warbler the radio is still on the air after our unkey, playing
    /// the audio Warbler holds. Receive stays muted, and the next key-down
    /// waits, as long as they did when the engine held the key itself:
    /// only PTT moves earlier.
    func testWarblerKeepsReceiveMutedAsLongAsBefore() throws {
        var config = SoftModemConfiguration()
        config.txDelayMs = txDelayMs
        config.txTailMs = txTailMs
        config.persist = 255
        let io = SyntheticModemIO(blockSize: blockSize)
        io.latency.outputSeconds = 0.4
        io.transmitTail = .warbler
        let ptt = RecordingPTTController()
        ptt.keyUpLatencyHint = 0.03
        let engine = ModemEngine(configuration: config, audio: io, ptt: ptt, scheduling: .inline)
        var decoded: [Data] = []
        engine.onFrameDecoded = { data, _ in decoded.append(data) }
        try engine.start()
        try engine.enqueue(frame("ours"))
        while ptt.events.count < 2 { io.pump(blocks: 1) }
        // 100 ms after the unkey, inside what used to be the drain margin:
        // our own audio may still be coming back from the radio.
        io.pump(blocks: 10)
        io.feed(AFSKModulator.synthesize(frames: [frame("echo")], sampleRate: 48_000, txDelayMs: 50))
        XCTAssertEqual(decoded, [], "still muted while the radio plays out")
        // Past the old margin plus the usual 50 ms mute, receive is back.
        io.pump(blocks: 50)
        io.feed(AFSKModulator.synthesize(frames: [frame("reply")], sampleRate: 48_000, txDelayMs: 50))
        io.pump(blocks: 10)
        XCTAssertEqual(decoded, [frame("reply")])
        engine.stop()
    }

    func testBothPoliciesSendTheWholeFrameAndItsTailFlags() throws {
        let payload = frame("the flags after the frame stay")
        let expectedSamples = transmissionBits(payload) * 40   // 48 kHz / 1200 bd
        for tail in [ModemTransmitTail.radio, .warbler] {
            let t = try transmit(payload, tail: tail)
            XCTAssertEqual(decodeAll(t.output, sampleRate: 48_000), [payload], "\(tail)")
            XCTAssertEqual(t.framesSent, 1, "\(tail)")
            let span = t.lastAudioSample - t.firstAudioSample + 1
            XCTAssertEqual(Double(span), Double(expectedSamples), accuracy: 40,
                           "\(tail): TXDELAY, the frame and TXTAIL all reached the link")
            // The last 100 ms is flags: the closing flag has company.
            let tailSamples = HDLCEncoder.flagCount(milliseconds: txTailMs, baud: 1200) * 8 * 40
            let tailSlice = Array(t.output[(t.lastAudioSample - tailSamples + 80)...t.lastAudioSample])
            let demod = AFSKDemodulator(inputSampleRate: 48_000, mode: ModemMode.afsk1200.parameters)
            var frames = 0
            demod.process(tailSlice) { if case .frame = $0 { frames += 1 } }
            XCTAssertEqual(frames, 0, "\(tail)")
            XCTAssertEqual(demod.activity, .flags, "\(tail): TXTAIL flags are on the air")
        }
    }

    func testNoGapOpensInsideTheTransmission() throws {
        // Several frames back to back, so the ring is refilled many times
        // while the tail policy could be looking for the end.
        let payloads = (0..<4).map { frame("frame \($0) " + String(repeating: "x", count: 120)) }
        for tail in [ModemTransmitTail.radio, .warbler] {
            var config = SoftModemConfiguration()
            config.txDelayMs = txDelayMs
            config.txTailMs = txTailMs
            config.persist = 255
            let io = SyntheticModemIO(blockSize: blockSize)
            io.latency.outputSeconds = 0.4
            io.transmitTail = tail
            let ptt = RecordingPTTController()
            let engine = ModemEngine(configuration: config, audio: io, ptt: ptt, scheduling: .inline)
            try engine.start()
            for p in payloads { try engine.enqueue(p) }
            io.pump(blocks: 800)
            XCTAssertEqual(ptt.events, [true, false], "\(tail): one key-down, one unkey")
            let out = io.renderedOutput
            let first = try XCTUnwrap(out.firstIndex { abs($0) > 1e-6 })
            let last = try XCTUnwrap(out.lastIndex { abs($0) > 1e-6 })
            var run = 0, longest = 0
            for v in out[first...last] {
                run = abs(v) <= 1e-6 ? run + 1 : 0
                longest = max(longest, run)
            }
            XCTAssertLessThanOrEqual(longest, 2, "\(tail): no silence inside the transmission")
            XCTAssertEqual(decodeAll(out, sampleRate: 48_000), payloads, "\(tail)")
            XCTAssertEqual(engine.telemetrySnapshot().txUnderruns, 0, "\(tail)")
            engine.stop()
        }
    }
}
