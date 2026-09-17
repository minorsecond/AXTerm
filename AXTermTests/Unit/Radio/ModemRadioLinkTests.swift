#if os(macOS)
import XCTest
@testable import AXTerm

/// The modem radio's link with a scripted radio on the CI-V port: what
/// opening asks the radio, what a wrong radio does, how the radio's own
/// frequency reaches the status, and that a transmission keys over CI-V.
final class ModemRadioLinkTests: XCTestCase {

    /// A delegate that records off any thread.
    private nonisolated final class Spy: KISSLinkDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [KISSLinkState] = []
        private var _errors: [String] = []
        var states: [KISSLinkState] { lock.withLock { _states } }
        var errors: [String] { lock.withLock { _errors } }
        func linkDidReceive(_ data: Data) {}
        func linkDidChangeState(_ state: KISSLinkState) { lock.withLock { _states.append(state) } }
        func linkDidError(_ message: String) { lock.withLock { _errors.append(message) } }
    }

    /// An IC-705 on 144.390 FM-D that accepts every set.
    private nonisolated static func ic705(_ frame: CIVFrame) -> [UInt8]? {
        switch (frame.command, frame.subcommand) {
        case (0x19, 0x00): return FakeCIVTransport.reply(0x19, 0x00, [0xA4])
        case (0x03, _): return FakeCIVTransport.reply(0x03, nil, CIVBCD.frequencyBytes(hz: 144_390_000))
        case (0x04, _): return FakeCIVTransport.reply(0x04, nil, [0x05, 0x01])
        case (0x1A, 0x06) where frame.data.isEmpty: return FakeCIVTransport.reply(0x1A, 0x06, [0x01, 0x01])
        default: return FakeCIVTransport.ok
        }
    }

    private func config(ptt: ModemPTTMethod = .civ, setsMode: Bool = false, follows: Bool = false) -> ModemLinkConfig {
        var c = ModemLinkConfig()
        c.audioInputDeviceUID = "in"; c.audioInputDeviceName = "USB Audio CODEC"
        c.audioOutputDeviceUID = "out"; c.audioOutputDeviceName = "USB Audio CODEC"
        c.civSerialPath = "/dev/cu.usbmodem14201"
        c.pttMethod = ptt
        c.setsRadioModeOnConnect = setsMode
        c.followsRadioFrequency = follows
        c.txDelayMs = 100
        c.txTailMs = 50
        c.persistence = 255
        return c
    }

    private func makeLink(_ config: ModemLinkConfig, responder: @escaping @Sendable (CIVFrame) -> [UInt8]? = ModemRadioLinkTests.ic705)
    -> (ModemRadioLink, FakeCIVTransport, SyntheticModemIO, Spy) {
        let transport = FakeCIVTransport()
        transport.responder = responder
        let audio = SyntheticModemIO()
        // Default delivery: delegate calls hop to the main actor, where these
        // tests run, and land during the awaits.
        let link = ModemRadioLink(config: config, audio: audio, makeTransport: { _ in transport },
                                  scheduling: .inline)
        let spy = Spy()
        link.delegate = spy
        return (link, transport, audio, spy)
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private nonisolated func hex(_ frame: CIVFrame) -> String {
        frame.encoded().map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - Opening

    /// Opening identifies the radio and reads it. It does not rewrite its
    /// menus.
    ///
    /// Quieting the bus used to happen on every connect regardless of the
    /// "set the radio for packet" switch. CI-V Transceive is a persistent
    /// menu item and nothing here ever put it back, so an operator who
    /// switched that off to stop AXTerm touching their radio had it touched
    /// anyway, every time — and the app ended up advising them to turn on a
    /// setting it was switching off (2026-09-17).
    func testOpeningIdentifiesReadsTheRadioAndConnectsWithoutRewritingIt() async {
        let (link, transport, _, spy) = makeLink(config())
        link.open()
        XCTAssertEqual(link.state, .connecting, "CI-V first")
        await waitUntil { link.state == .connected }
        XCTAssertEqual(link.state, .connected)
        XCTAssertEqual(link.rigModel, "IC-705")
        XCTAssertEqual(link.endpointDescription, "IC-705 via USB Audio CODEC")
        XCTAssertEqual(link.rigStatus.frequencyHz, 144_390_000)
        XCTAssertEqual(link.rigStatus.modeLabel, "FM-D")

        let written = transport.written.map(hex)
        XCTAssertEqual(written.first, "FE FE A4 E0 19 00 FD", "who are you")
        XCTAssertFalse(written.contains("FE FE A4 E0 1A 05 01 31 00 FD"),
                       "CI-V Transceive is the operator's setting and survives us; "
                       + "do not switch it off unasked")
        XCTAssertFalse(written.contains { $0.hasPrefix("FE FE A4 E0 06") }, "the mode is the operator's unless asked")
        await waitUntil { spy.states.last == .connected }
        XCTAssertEqual(spy.states.last, .connected)
        XCTAssertTrue(spy.errors.isEmpty)
        link.close()
        XCTAssertEqual(link.state, .disconnected)
    }

    func testSetRadioOnConnectPushesThePacketSetup() async {
        let (link, transport, _, _) = makeLink(config(setsMode: true))
        link.open()
        await waitUntil { link.state == .connected }
        let written = transport.written.map(hex)
        XCTAssertTrue(written.contains("FE FE A4 E0 06 05 01 FD"), "FM, filter 1")
        XCTAssertTrue(written.contains("FE FE A4 E0 1A 06 01 01 FD"), "data mode on")
        XCTAssertTrue(written.contains("FE FE A4 E0 1A 05 01 19 01 FD"), "DATA MOD = USB")
        XCTAssertTrue(written.contains("FE FE A4 E0 1A 05 01 11 00 FD"), "AF squelch open")
        XCTAssertTrue(written.contains("FE FE A4 E0 1A 05 01 25 00 FD"), "USB SEND off")
        XCTAssertTrue(written.contains("FE FE A4 E0 1A 05 01 31 00 FD"),
                      "asked to set the radio up over a cable, the bus is still quieted")
        link.close()
    }

    func testTheWrongRadioFailsBeforeAudioIsTouched() async {
        let (link, _, audio, spy) = makeLink(config(), responder: { _ in FakeCIVTransport.reply(0x19, 0x00, [0x94]) })
        link.open()
        await waitUntil { link.state == .failed }
        await waitUntil { spy.states.last == .failed }
        XCTAssertEqual(link.state, .failed)
        XCTAssertEqual(spy.errors.count, 1)
        XCTAssertTrue(spy.errors[0].contains("IC-7300"), spy.errors[0])
        XCTAssertTrue(spy.errors[0].contains("expected IC-705"), spy.errors[0])
        XCTAssertFalse(audio.isRunning, "no audio device grabbed for a radio that is not ours")
        XCTAssertEqual(spy.states, [.connecting, .failed])
    }

    func testASilentPortFailsWithTheReason() async {
        let (link, _, _, spy) = makeLink(config(), responder: { _ in nil })
        link.open()
        await waitUntil(3) { link.state == .failed }
        await waitUntil { !spy.errors.isEmpty }
        XCTAssertEqual(link.state, .failed)
        XCTAssertEqual(spy.errors.first?.hasPrefix("Radio control failed:"), true)
    }

    func testNoPortMeansAudioOnly() async {
        var c = config(ptt: .none)
        c.civSerialPath = ""
        let (link, transport, _, _) = makeLink(c)
        link.open()
        await waitUntil { link.state == .connected }
        XCTAssertEqual(link.state, .connected)
        XCTAssertNil(link.rigModel)
        XCTAssertTrue(transport.written.isEmpty, "nothing to say to a radio we cannot reach")
        XCTAssertEqual(link.endpointDescription, "Sound modem via USB Audio CODEC")
        link.close()
    }

    // MARK: - The radio's own frequency

    func testTheRadioTuningReachesTheStatusUnasked() async {
        let (link, transport, _, _) = makeLink(config())
        var seen: [Int?] = []
        let lock = NSLock()
        link.onRigStatus = { status in lock.withLock { seen.append(status.frequencyHz) } }
        link.open()
        await waitUntil { link.state == .connected }
        // A transceive broadcast: to 00, from A4, command 00, the new frequency.
        transport.inject([0xFE, 0xFE, 0x00, 0xA4, 0x00] + CIVBCD.frequencyBytes(hz: 145_010_000) + [0xFD])
        await waitUntil { link.rigStatus.frequencyHz == 145_010_000 }
        XCTAssertEqual(link.rigStatus.frequencyHz, 145_010_000)
        XCTAssertEqual(lock.withLock { seen.last }, 145_010_000)
        // And a mode broadcast.
        transport.inject([0xFE, 0xFE, 0x00, 0xA4, 0x01, 0x01, 0x02, 0xFD])
        await waitUntil { link.rigStatus.mode == .usb }
        XCTAssertEqual(link.rigStatus.mode, .usb)
        XCTAssertEqual(link.rigStatus.filter, 2)
        link.close()
    }

    func testIdentifyOnTheLiveLinkAndOnAFreshPort() async throws {
        let (link, _, _, _) = makeLink(config())
        link.open()
        await waitUntil { link.state == .connected }
        let live = try await link.identifyRadio()
        XCTAssertEqual(live, "IC-705 (A4) \u{b7} 144.390 MHz FM-D")
        link.close()

        let fresh = FakeCIVTransport()
        fresh.responder = Self.ic705
        let answer = try await ModemRadioLink.identifyRadio(config: config(), makeTransport: { _ in fresh })
        XCTAssertEqual(answer, "IC-705 (A4) \u{b7} 144.390 MHz FM-D")
        XCTAssertEqual(fresh.state, .closed, "a throwaway question closes its port")
        XCTAssertEqual(fresh.written.first.map(hex), "FE FE A4 E0 19 00 FD")
    }

    // MARK: - Keying

    func testATransmissionKeysAndUnkeysOverCIV() async throws {
        let (link, transport, audio, _) = makeLink(config())
        link.open()
        await waitUntil { link.state == .connected }
        let frame = AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 5), to: AX25Address(call: "TEST"),
                                             via: DigiPath(), pid: 0xF0, payload: Data("hi".utf8), displayInfo: "hi").encodeAX25()
        let accepted = expectation(description: "accepted")
        link.send(KISS.encodeFrame(payload: frame, port: 0)) { error in XCTAssertNil(error); accepted.fulfill() }
        await fulfillment(of: [accepted], timeout: 2)

        // Clock the modem: it asks for PTT, waits for the radio's OK, plays, unkeys.
        audio.pump(blocks: 2)
        await waitUntil { transport.written.map(self.hex).contains("FE FE A4 E0 1C 00 01 FD") }
        XCTAssertTrue(transport.written.map(hex).contains("FE FE A4 E0 1C 00 01 FD"), "PTT on")
        await waitUntil { link.modem.telemetry.ptt }
        for _ in 0..<40 where !transport.written.map(self.hex).contains("FE FE A4 E0 1C 00 00 FD") {
            audio.pump(blocks: 10)
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(transport.written.map(hex).contains("FE FE A4 E0 1C 00 00 FD"), "PTT off")
        XCTAssertEqual(decodeAll(audio.renderedOutput, sampleRate: 48_000), [frame])
        link.close()
    }

    func testClosingWhileKeyedDropsPTT() async throws {
        let (link, transport, audio, _) = makeLink(config())
        link.open()
        await waitUntil { link.state == .connected }
        let frame = AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 5), to: AX25Address(call: "TEST"),
                                             via: DigiPath(), pid: 0xF0, payload: Data("long".utf8), displayInfo: "long").encodeAX25()
        link.send(KISS.encodeFrame(payload: frame, port: 0)) { _ in }
        audio.pump(blocks: 2)
        await waitUntil { link.modem.telemetry.ptt }
        XCTAssertTrue(link.modem.telemetry.ptt)
        link.close()
        await waitUntil { transport.written.map(self.hex).contains("FE FE A4 E0 1C 00 00 FD") }
        XCTAssertTrue(transport.written.map(hex).contains("FE FE A4 E0 1C 00 00 FD"), "never leave the radio keyed")
    }

    // MARK: - A silent CI-V port

    /// Over the WLAN nothing on the open path insists on a reply: the login
    /// names the radio, so `identify` and every setup command are allowed to
    /// fail quietly. That is deliberate, and it means a control channel that
    /// answers nothing at all reaches the operator as a bare "PTT failed:
    /// timeout" partway through their first transmission — the report that
    /// started this. Bring-up decides whether to say so up front instead.
    // MARK: - Losing the radio after it is up

    /// From the operator's log of 2026-09-09: the UDP sockets to the IC-705
    /// died at 11:48:49Z, the radio dropped the session, and AXTerm went on
    /// showing "connected" for two hours without receiving another frame.
    ///
    /// The session noticed. `LANCIVTransport` turned it into a failed
    /// transport, `CIVClient` failed the requests in flight — and there the
    /// news stopped, because nothing between the CI-V client and the link
    /// carried it any further. Everything before this point tests the failure
    /// path during `open()`; this is the one after it, which is the one an
    /// operator actually lives with.
    func testARigThatDiesAfterOpeningFailsTheLink() async {
        let (link, transport, _, spy) = makeLink(config())
        link.open()
        await waitUntil { link.state == .connected }

        transport.fail("Socket is not connected")

        await waitUntil { link.state == .failed }
        XCTAssertEqual(link.state, .failed, "the radio is gone; the link must say so")
        XCTAssertTrue(spy.states.contains(.failed), "the delegate was never told: \(spy.states)")
        XCTAssertTrue(spy.errors.contains { $0.contains("Socket is not connected") },
                      "the reason must reach the operator: \(spy.errors)")
    }

    /// A dead radio is a reason to try again — the same growing backoff a
    /// failed open uses. Losing the link is the more common case of the two
    /// and had no recovery at all.
    func testALostRadioIsRetried() async {
        let (link, transport, _, _) = makeLink(config())
        link.open()
        await waitUntil { link.state == .connected }
        transport.fail("Socket is not connected")
        await waitUntil { link.state == .failed }
        XCTAssertEqual(link.state, .failed, "the loss must register before recovery means anything")

        // The reconnect is scheduled, so the link comes back on its own.
        await waitUntil(8) { link.state == .connected }
        XCTAssertEqual(link.state, .connected, "no attempt was made to get the radio back")
    }

    /// ...but not after the operator has closed it. A reconnect that outlives
    /// `close()` re-keys a radio somebody deliberately released.
    func testAClosedLinkIsNotReconnected() async {
        let (link, transport, _, _) = makeLink(config())
        link.open()
        await waitUntil { link.state == .connected }
        link.close()
        transport.fail("Socket is not connected")

        await waitUntil(1) { link.state != .disconnected }
        XCTAssertEqual(link.state, .disconnected,
                       "a closed link must stay closed — not reopen, and not be "
                       + "reported as failed when the operator was the one who let go")
    }

    func testAnAnsweringRadioIsNotComplainedAbout() {
        XCTAssertNil(ModemRadioLink.civSilenceComplaint(identified: true, statusAnswered: true, address: 0xA4))
        XCTAssertNil(ModemRadioLink.civSilenceComplaint(identified: true, statusAnswered: false, address: 0xA4),
                     "identify alone proves the port")
        XCTAssertNil(ModemRadioLink.civSilenceComplaint(identified: false, statusAnswered: true, address: 0xA4),
                     "a frequency read alone proves it too — identify may be buried by the scope flood")
    }

    func testARadioThatAnswersNothingIsReportedWithTheAddressAsked() throws {
        let complaint = try XCTUnwrap(ModemRadioLink.civSilenceComplaint(identified: false, statusAnswered: false,
                                                                        address: 0xA4))
        XCTAssertTrue(complaint.contains("A4"), "the address we asked for is the first thing to check")
        XCTAssertTrue(complaint.lowercased().contains("receive works"),
                      "say what still works, so this does not read as a dead radio")
    }

    /// A radio that answers a broadcast from somewhere else is a
    /// misconfiguration with one fix, and the complaint should name it
    /// rather than list the things to go and check.
    func testABroadcastAnswerFromAnotherAddressNamesTheFix() throws {
        let complaint = try XCTUnwrap(ModemRadioLink.civSilenceComplaint(
            identified: false, statusAnswered: false, address: 0xA4, answeringAddress: 0x5E))
        XCTAssertTrue(complaint.contains("5E"), "the address that answered is the fix")
        XCTAssertTrue(complaint.contains("A4"), "and the one we were asking for is the mistake")
        XCTAssertFalse(complaint.contains("switched off"),
                       "CI-V plainly is not off — something just answered on it")
    }

    /// Silence to a broadcast rules the address out entirely, so the
    /// complaint must stop suggesting it as the thing to check.
    func testSilenceToABroadcastRulesTheAddressOut() throws {
        let complaint = try XCTUnwrap(ModemRadioLink.civSilenceComplaint(
            identified: false, statusAnswered: false, address: 0xA4, answeringAddress: nil))
        XCTAssertTrue(complaint.lowercased().contains("nothing answered a broadcast"),
                      "say that the wider question was asked, and drew a blank")
        XCTAssertTrue(complaint.contains("A4"))
    }

    /// A CI-V stream carrying traffic while nothing has been read means the
    /// radio is reachable and refusing to talk. Told to "check whether CI-V
    /// is reaching the radio", an operator goes looking at the network,
    /// which is the one thing already proven to work (2026-09-17).
    func testALiveStreamSaysTheRadioIsReachableAndIgnoringCIV() throws {
        let complaint = try XCTUnwrap(ModemRadioLink.civSilenceComplaint(
            identified: false, statusAnswered: false, address: 0xA4,
            answeringAddress: nil, civStreamSilence: 0.0))
        XCTAssertTrue(complaint.contains("stream itself is alive"), complaint)
        XCTAssertTrue(complaint.contains("switched off at the radio"), complaint)
        XCTAssertFalse(complaint.contains("not reaching it"),
                       "it plainly is reaching it — the stream is carrying traffic")
    }

    /// The opposite reading of the same silence, and the opposite fix.
    func testADeadStreamSaysItNeverCameUp() throws {
        let complaint = try XCTUnwrap(ModemRadioLink.civSilenceComplaint(
            identified: false, statusAnswered: false, address: 0xA4,
            answeringAddress: nil,
            civStreamSilence: ModemRadioLink.streamAliveWithin + 1))
        XCTAssertTrue(complaint.contains("never came up"), complaint)
        XCTAssertTrue(complaint.lowercased().contains("wait"),
                      "the radio holds its one session for a while — say so")
        XCTAssertFalse(complaint.contains("switched off at the radio"),
                       "nothing has been heard from the radio, so it cannot be blamed for its menus")
    }

    /// A serial CI-V radio has no stream to report on, so the wording must
    /// stay as it was rather than claim a measurement it does not have.
    func testNoStreamReportedKeepsTheOlderWording() throws {
        let complaint = try XCTUnwrap(ModemRadioLink.civSilenceComplaint(
            identified: false, statusAnswered: false, address: 0xA4,
            answeringAddress: nil, civStreamSilence: nil))
        XCTAssertTrue(complaint.contains("switched off at the radio or not reaching it"), complaint)
    }

    /// When the fault is ours, say so first and stop sending the operator to
    /// the radio's menus.
    ///
    /// The radio checks the low 16 bits of our session ID against the source
    /// port our packets actually come from. We reserve a port and pin to it,
    /// but the pin can fail to land, and then the radio refuses that stream
    /// without a word — identical silence to CI-V being switched off, and an
    /// operator who goes and turns CI-V Transceive on has changed nothing
    /// that matters (2026-09-17).
    func testAMissedSourcePortBlamesUsAndNotTheRadio() throws {
        let complaint = try XCTUnwrap(ModemRadioLink.civSilenceComplaint(
            identified: false, statusAnswered: false, address: 0xA4,
            answeringAddress: nil, civStreamSilence: 0.0, sourcePortMismatched: true))
        XCTAssertTrue(complaint.contains("could not hold the source port"), complaint)
        XCTAssertTrue(complaint.lowercased().contains("connect again"), complaint)
        XCTAssertFalse(complaint.contains("Transceive"),
                       "the radio's menus are not the problem and must not be offered as one")
        XCTAssertFalse(complaint.contains("switched off at the radio"), complaint)
    }

    /// Without that evidence the older readings stand.
    func testALandedPinStillReadsTheStream() throws {
        let complaint = try XCTUnwrap(ModemRadioLink.civSilenceComplaint(
            identified: false, statusAnswered: false, address: 0xA4,
            answeringAddress: nil, civStreamSilence: 0.0, sourcePortMismatched: false))
        XCTAssertTrue(complaint.contains("switched off at the radio"), complaint)
    }

    /// The awkward third case: the broadcast is answered by the very address
    /// we are using. The address is exonerated; the replies are going missing.
    func testAnAnswerFromOurOwnAddressExoneratesIt() throws {
        let complaint = try XCTUnwrap(ModemRadioLink.civSilenceComplaint(
            identified: false, statusAnswered: false, address: 0xA4, answeringAddress: 0xA4))
        XCTAssertTrue(complaint.lowercased().contains("the address is right"))
    }
}
#endif
