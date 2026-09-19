import Combine
import XCTest
@testable import AXTerm

/// The manager with a sound modem among its radios: the factory's refusals
/// become reasons, the modem's telemetry and rig status land on the right
/// radio, and a setting that only changes a level does not reopen the link.
@MainActor
final class RadioManagerModemTests: XCTestCase {

    private func modem(_ id: String = "705") -> RadioProfile {
        var radio = RadioProfile(id: RadioID(rawValue: id), name: id)
        radio.kind = .modem
        radio.audioInputDeviceUID = "in-uid"
        radio.audioInputDeviceName = "USB Audio CODEC"
        radio.audioOutputDeviceUID = "out-uid"
        radio.audioOutputDeviceName = "USB Audio CODEC"
        return radio
    }

    private func direwolf() -> RadioProfile {
        var radio = RadioProfile(id: RadioID(rawValue: "base"), name: "Base")
        radio.kind = .tcp
        radio.host = "192.168.3.218"
        radio.port = 8001
        return radio
    }

    /// Wait for something to become true, and fail here if it never does.
    ///
    /// Failing here is the whole point. A helper that returns quietly on
    /// timeout lets the test carry on against a world that never arrived, and
    /// whatever assertion trips next gets the blame. That is how the sibling
    /// helper in `ModemRadioLinkTests` had a link that never finished
    /// connecting reported, over and over, as a modem that would not unkey.
    ///
    /// `what` is required for the same reason: "timed out" names nothing.
    @discardableResult
    private func waitUntil(_ what: String,
                           timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let met = condition()
        if !met {
            XCTFail("timed out after \(timeout)s waiting for: \(what)", file: file, line: line)
        }
        return met
    }

    // MARK: - Refusals

    /// A modem with no audio devices chosen has no link, and the radio says
    /// why instead of sitting at "disconnected" forever.
    func testAModemWithoutDevicesReportsWhyItHasNoLink() {
        let manager = RadioManager(linkFactory: RadioManager.defaultLinkFactory)
        var radio = modem()
        radio.audioInputDeviceUID = ""
        radio.audioOutputDeviceUID = ""
        _ = manager.reconcile([radio, direwolf()], open: false)
        XCTAssertEqual(manager.sessions.count, 1, "the Direwolf still gets its link")
        XCTAssertEqual(manager.unavailableReasons[radio.id], "Choose an audio input and output device for this radio.")
        XCTAssertNil(manager.unavailableReasons[RadioID(rawValue: "base")])
    }

    #if os(macOS)
    func testTheDefaultFactoryBuildsAModemRadioLink() {
        let link = RadioManager.defaultLinkFactory(modem())
        XCTAssertTrue(link is ModemRadioLink)
        XCTAssertEqual(link?.endpointDescription, "Sound modem via USB Audio CODEC")
    }
    #else
    func testTheDefaultFactoryRefusesAModemHere() {
        XCTAssertNil(RadioManager.defaultLinkFactory(modem()))
        XCTAssertEqual(RadioManager.unsupportedReason(for: modem()),
                       "The sound modem needs a Mac. Use this radio from AXTerm on your Mac, or reach a TNC over the network or Bluetooth here.")
    }
    #endif

    #if os(macOS)
    // MARK: - Telemetry and rig status through the layers

    private final class Spy: RadioManagerDelegate {
        var telemetry: [(String, ModemTelemetry)] = []
        var rig: [(String, RigStatus, String?)] = []
        func radioManager(_ manager: RadioManager, link: LinkSession, didReceiveBytes data: Data) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, didReceiveTelemetry frame: Data, port: UInt8) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, didReceiveUnknown command: UInt8, payload: Data) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, didChangeState state: KISSLinkState, from previous: KISSLinkState) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, didError message: String) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, droppedFrameOnUnassignedPort port: UInt8) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, didUpdateModemTelemetry telemetry: ModemTelemetry) {
            self.telemetry.append((link.key, telemetry))
        }
        func radioManager(_ manager: RadioManager, link: LinkSession, didUpdateRigStatus status: RigStatus, model: String?) {
            rig.append((link.key, status, model))
        }
    }

    /// A modem link over synthetic audio and no CI-V port, deterministic.
    private func makeModemLink(_ profile: RadioProfile, audio: SyntheticModemIO) -> ModemRadioLink {
        var config = profile.modemConfig!
        config.civSerialPath = ""
        return ModemRadioLink(config: config, audio: audio, scheduling: .inline)
    }

    /// The modem gets a synthetic-audio link; anything else the real one.
    private func factory(audio: SyntheticModemIO) -> (RadioProfile) -> KISSLink? {
        { [self] profile in
            profile.kind == .modem ? makeModemLink(profile, audio: audio) : RadioManager.defaultLinkFactory(profile)
        }
    }

    func testTheReasonClearsOnceTheRadioHasALink() {
        let audio = SyntheticModemIO()
        var factoryCalls = 0
        let manager = RadioManager(linkFactory: { [self] profile in
            factoryCalls += 1
            return profile.audioInputDeviceUID.isEmpty ? nil : makeModemLink(profile, audio: audio)
        })
        var radio = modem()
        radio.audioInputDeviceUID = ""
        _ = manager.reconcile([radio], open: false)
        XCTAssertNotNil(manager.unavailableReasons[radio.id])
        radio.audioInputDeviceUID = "in-uid"
        _ = manager.reconcile([radio], open: false)
        XCTAssertNil(manager.unavailableReasons[radio.id])
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(factoryCalls, 2)
    }

    /// Audio flows into the modem; its telemetry surfaces on the radio, not
    /// the link, and reaches the delegate.
    func testModemTelemetryLandsOnTheRadio() async {
        let audio = SyntheticModemIO()
        let manager = RadioManager(linkFactory: factory(audio: audio))
        let spy = Spy()
        manager.delegate = spy
        let radio = modem()
        _ = manager.reconcile([radio, direwolf()], open: false)
        // The Direwolf's link is a real TCP link left closed; only the modem opens.
        manager.open(radio.id)
        await waitUntil("the modem radio's link to connect") { manager.sessions.values.contains { $0.link is ModemRadioLink && $0.state == .connected } }

        audio.feed([Float](repeating: 0, count: 480 * 12))
        await waitUntil("modem telemetry to reach this radio") { manager.modemTelemetry[radio.id] != nil }
        let telemetry = manager.modemTelemetry[radio.id]
        XCTAssertNotNil(telemetry, "telemetry republished per radio")
        XCTAssertEqual(telemetry?.ptt, false)
        XCTAssertNil(manager.modemTelemetry[RadioID(rawValue: "base")], "the Direwolf has no modem")
        XCTAssertFalse(spy.telemetry.isEmpty)
        XCTAssertEqual(spy.telemetry.first?.0, radio.linkKey)

        // The modem is ours: it identifies itself without a KISS query.
        let session = manager.sessions[radio.linkKey]
        XCTAssertEqual(session?.tncIdentity?.hasPrefix("AXTerm Sound Modem"), true)
        XCTAssertEqual(session?.tncIdentity?.hasSuffix("afsk1200"), true)
        manager.closeAll()
    }

    /// A level change applies in place: the same link, still connected.
    func testALevelChangeDoesNotReopenTheLink() async {
        let audio = SyntheticModemIO()
        var factoryCalls = 0
        let manager = RadioManager(linkFactory: { [self] profile in
            factoryCalls += 1
            return makeModemLink(profile, audio: audio)
        })
        var radio = modem()
        _ = manager.reconcile([radio], open: true)
        await waitUntil("the link to connect") { manager.sessions.values.first?.state == .connected }
        let link = manager.sessions[radio.linkKey]?.link as? ModemRadioLink
        XCTAssertNotNil(link)

        radio.txAudioLevel = 50
        radio.txDelayMs = 400
        _ = manager.reconcile([radio], open: true)
        XCTAssertEqual(factoryCalls, 1, "same signature, same link")
        XCTAssertTrue(manager.sessions[radio.linkKey]?.link === link)
        XCTAssertEqual(manager.sessions[radio.linkKey]?.state, .connected)
        XCTAssertEqual(link?.config.txAudioLevel, 50)
        XCTAssertEqual(link?.config.txDelayMs, 400)
        XCTAssertEqual(link?.modem.currentConfiguration.txDelayMs, 400)

        // A mode change is a new modem behind the same link object: the
        // audio pair (the key) is unchanged, so the manager keeps the
        // session and the link rebuilds itself.
        radio.modemMode = .afsk300
        _ = manager.reconcile([radio], open: true)
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(manager.sessions[radio.linkKey]?.link === link)
        await waitUntil("the link to connect") { manager.sessions[radio.linkKey]?.state == .connected }
        XCTAssertEqual(manager.sessions[radio.linkKey]?.state, .connected)
        XCTAssertEqual(link?.config.mode, .afsk300)
        XCTAssertEqual(link?.modem.currentConfiguration.mode, .afsk300)
        manager.closeAll()
    }

    /// Frames the modem decodes are attributed to the modem radio, and
    /// frames for the modem radio leave through it as audio.
    func testFramesFlowThroughTheModemRadio() async throws {
        let audio = SyntheticModemIO()
        let manager = RadioManager(linkFactory: { [self] profile in makeModemLink(profile, audio: audio) })
        var received: [RadioIngest] = []
        let sub = manager.ingest.sink { received.append($0) }
        defer { sub.cancel() }
        let radio = modem()
        _ = manager.reconcile([radio], open: true)
        await waitUntil("the link to connect") { manager.sessions.values.first?.state == .connected }

        // A frame in: synthesized audio of a UI frame, fed to the modem.
        var rng = SplitMix64(seed: 7)
        let frame = randomFrames(count: 1, rng: &rng)[0]
        let samples = AFSKModulator.synthesize(frames: [frame], sampleRate: 48_000)
        audio.feed(samples + [Float](repeating: 0, count: 4800))
        await waitUntil("the decoded frame to reach the manager") { !received.isEmpty }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.radio, radio.id)
        XCTAssertEqual(received.first?.ax25, frame)

        // A frame out: enqueued, keyed with no PTT controller, rendered.
        let link = manager.sessions[radio.linkKey]!.link as! ModemRadioLink
        let sent = expectation(description: "accepted")
        link.send(KISS.encodeFrame(payload: frame, port: 0)) { error in
            XCTAssertNil(error)
            sent.fulfill()
        }
        await fulfillment(of: [sent], timeout: 2)
        audio.pump(blocks: 200)
        XCTAssertGreaterThan(audio.renderedOutput.count, 48_000 / 1200 * 8 * 45, "at least the preamble flags rendered")
        manager.closeAll()
    }
    #endif
}
