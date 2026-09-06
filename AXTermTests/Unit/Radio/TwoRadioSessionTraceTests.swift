import Combine
import XCTest
@testable import AXTerm

/// The whole path, end to end, on two radios sharing one Direwolf: a SABM
/// heard on the second radio's port is answered with a UA that leaves on the
/// same link with the same port.
///
/// This is the trace the design was written around. Before it, the port was
/// dropped on the way in and never set on the way out, so a multi-port TNC
/// would have had every reply leave on port 0 — the wrong radio.
@MainActor
final class TwoRadioSessionTraceTests: XCTestCase {

    private var suiteName = ""
    private var link: KISSLinkLoopback?

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStation() -> (PacketEngine, SessionCoordinator, AppSettingsStore) {
        suiteName = "AXTermTests.TwoRadioTrace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "K0EPI-7"

        // Two radios on one Direwolf: same host and port, KISS ports 0 and 1.
        settings.updateRadio(settings.radios[0].id) { $0.host = "192.168.3.218"; $0.port = 8001; $0.kissPort = 0 }
        let uhf = settings.addRadio()
        settings.updateRadio(uhf.id) { $0.name = "UHF"; $0.host = "192.168.3.218"; $0.port = 8001; $0.kissPort = 1 }

        let engine = PacketEngine(settings: settings, linkFactory: { [weak self] _ in
            // One loopback for the one byte stream both radios share.
            if let existing = self?.link { return existing }
            let fresh = KISSLinkLoopback()
            fresh.loopbackEnabled = false
            self?.link = fresh
            return fresh
        })
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "K0EPI-7"
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: engine)
        return (engine, coordinator, settings)
    }

    private func kissFrame(port: UInt8, ax25: Data) -> Data {
        KISS.encodeFrame(payload: ax25, port: port)
    }

    /// The AX.25 frames the link has sent, with their ports. A TCP link also
    /// sends the TNC-identity query a second after connecting — a hardware
    /// frame, not a reply — and that is left out here.
    private var replies: [(port: UInt8, ax25: Data)] {
        (link?.sentData ?? []).compactMap(unwrap)
    }

    /// Packets reach the coordinator on the main run loop, so the reply is a
    /// turn of the loop away. Awaiting yields the main actor so it can run;
    /// these tests are `async` for that reason and for the one the project
    /// memory records — a synchronous test that drops a main-actor
    /// ObservableObject trips its isolated deinit.
    private func waitForReplies(_ count: Int) async {
        for _ in 0..<100 where replies.count < count {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Strips the KISS framing and returns (port, AX.25 bytes).
    private func unwrap(_ kiss: Data) -> (port: UInt8, ax25: Data)? {
        var parser = KISSFrameParser()
        guard let frame = parser.feedFrames(kiss).first, case .ax25(let ax25) = frame.output else { return nil }
        return (frame.port, ax25)
    }

    /// What the trace looked like at each step, for the failure message.
    private func diagnostics(_ engine: PacketEngine, _ coordinator: SessionCoordinator,
                             peer: AX25Address, local: AX25Address, radio: RadioID) -> String {
        let answers = coordinator.sessionManager.answers(local)
        let session = coordinator.sessionManager.existingSession(for: peer, path: DigiPath(), radio: radio)
        let lines = engine.consoleLines.suffix(8).map(\.text).joined(separator: " | ")
        return "answers=\(answers) session=\(session != nil) state=\(session.map { "\($0.state)" } ?? "-") replies=\(replies.count) console=[\(lines)]"
    }

    func testASABMOnTheSecondRadioIsAnsweredOnTheSecondRadio() async {
        let (engine, coordinator, settings) = makeStation()
        // The coordinator is what answers; it must outlive the wait.
        defer { withExtendedLifetime(coordinator) {} }
        engine.connectUsingSettings()
        XCTAssertEqual(engine.status, .connected, "loopback links connect synchronously")
        XCTAssertEqual(engine.radioManager.sessions.count, 1, "two radios, one byte stream")

        let peer = AX25Address(call: "PEER", ssid: 1)
        let local = AX25Address(call: "K0EPI", ssid: 7)
        let sabm = AX25FrameBuilder.buildSABM(from: peer, to: local, via: DigiPath(), extended: false).encodeAX25()

        // What the engine published, as it published it. (Its `packets` list
        // is reloaded from storage after a connect and is not stable here.)
        var heard: [Packet] = []
        let sub = engine.packetPublisher.sink { heard.append($0) }
        defer { sub.cancel() }

        link!.injectReceived(kissFrame(port: 1, ax25: sabm))
        await waitForReplies(1)

        // The packet was attributed to the UHF radio…
        let uhf = settings.radios.first { $0.kissPort == 1 }!
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard.first?.radioID, uhf.id)
        XCTAssertEqual(heard.first?.kissPort, 1)

        // …and the UA left on port 1 of the same link.
        XCTAssertEqual(replies.count, 1, "exactly one reply: " + diagnostics(engine, coordinator, peer: peer, local: local, radio: uhf.id))
        let reply = replies.first
        XCTAssertEqual(reply?.port, 1)
        let decoded = reply.flatMap { AX25.decodeFrame(ax25: $0.ax25) }
        XCTAssertEqual(decoded?.frameType, .u)
        XCTAssertEqual(decoded?.to?.display, "PEER-1")
        XCTAssertEqual(decoded?.from?.display, "K0EPI-7")
    }

    /// A second call on the primary radio is a different session, answered
    /// on port 0. From a second peer: the same bytes on both ports inside the
    /// window are one transmission heard twice, and are folded on purpose.
    func testACallOnThePrimaryRadioIsAnsweredOnPortZero() async {
        let (engine, coordinator, settings) = makeStation()
        engine.connectUsingSettings()

        let peer = AX25Address(call: "PEER", ssid: 1)
        let other = AX25Address(call: "PEER", ssid: 2)
        let local = AX25Address(call: "K0EPI", ssid: 7)
        let sabm = AX25FrameBuilder.buildSABM(from: peer, to: local, via: DigiPath(), extended: false).encodeAX25()
        let sabm2 = AX25FrameBuilder.buildSABM(from: other, to: local, via: DigiPath(), extended: false).encodeAX25()

        link!.injectReceived(kissFrame(port: 1, ax25: sabm))
        link!.injectReceived(kissFrame(port: 0, ax25: sabm2))
        await waitForReplies(2)
        defer { withExtendedLifetime(coordinator) {} }

        XCTAssertEqual(replies.count, 2, diagnostics(engine, coordinator, peer: peer, local: local, radio: .primary))
        XCTAssertEqual(replies.map(\.port), [1, 0])
        let uhf = settings.radios.first { $0.kissPort == 1 }!.id
        let base = settings.radios.first { $0.kissPort == 0 }!.id
        XCTAssertNotNil(coordinator.sessionManager.existingSession(for: peer, path: DigiPath(), radio: uhf))
        XCTAssertNotNil(coordinator.sessionManager.existingSession(for: other, path: DigiPath(), radio: base))
    }

    /// The same peer calling both radios with identical bytes inside the
    /// window is one transmission heard twice: one session, one UA.
    func testTheSameCallHeardOnBothRadiosIsAnsweredOnce() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime(coordinator) {} }
        engine.connectUsingSettings()

        let peer = AX25Address(call: "PEER", ssid: 1)
        let local = AX25Address(call: "K0EPI", ssid: 7)
        let sabm = AX25FrameBuilder.buildSABM(from: peer, to: local, via: DigiPath(), extended: false).encodeAX25()
        link!.injectReceived(kissFrame(port: 1, ax25: sabm))
        link!.injectReceived(kissFrame(port: 0, ax25: sabm))
        await waitForReplies(1)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(replies.count, 1, "the second copy was folded")
        XCTAssertEqual(replies.first?.port, 1, "answered on the radio that heard it first")
        XCTAssertEqual(engine.crossRadioFolds, 1)
        let base = settings.radios.first { $0.kissPort == 0 }!.id
        XCTAssertNil(coordinator.sessionManager.existingSession(for: peer, path: DigiPath(), radio: base))
    }

    /// The owner rule. Give the UHF radio its own SSID; a call to that SSID
    /// heard on the primary radio's port — both radios on one frequency —
    /// is answered by the UHF radio, on its port, from its callsign.
    func testACallToOneRadiosCallsignIsAnsweredByThatRadioWhicheverLinkHeardIt() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime(coordinator) {} }
        let uhf = settings.radios.first { $0.kissPort == 1 }!.id
        settings.updateRadio(uhf) { $0.callsign = "K0EPI-1" }
        engine.connectUsingSettings()
        // The coordinator learns the addresses on the main run loop.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let peer = AX25Address(call: "PEER", ssid: 1)
        let sabm = AX25FrameBuilder.buildSABM(from: peer, to: AX25Address(call: "K0EPI", ssid: 1),
                                              via: DigiPath(), extended: false).encodeAX25()
        link!.injectReceived(kissFrame(port: 0, ax25: sabm))
        await waitForReplies(1)

        XCTAssertEqual(replies.count, 1, diagnostics(engine, coordinator, peer: peer,
                                                      local: AX25Address(call: "K0EPI", ssid: 1), radio: uhf))
        XCTAssertEqual(replies.first?.port, 1, "answered on the UHF radio's port, not the one that heard it")
        let decoded = replies.first.flatMap { AX25.decodeFrame(ax25: $0.ax25) }
        XCTAssertEqual(decoded?.from?.display, "K0EPI-1")
        XCTAssertEqual(decoded?.to?.display, "PEER-1")
    }

    // MARK: - Two radios on one frequency

    /// The same transmission heard by both radios is one packet, and the
    /// station is marked heard on both.
    func testOneTransmissionHeardByBothRadiosIsOnePacket() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime(coordinator) {} }
        engine.connectUsingSettings()

        var heard: [Packet] = []
        let sub = engine.packetPublisher.sink { heard.append($0) }
        defer { sub.cancel() }

        let beacon = AX25FrameBuilder.buildUI(from: AX25Address(call: "K0NTS", ssid: 1),
                                              to: AX25Address(call: "BEACON"), via: DigiPath(),
                                              pid: 0xF0, payload: Data("hello".utf8), displayInfo: nil).encodeAX25()
        // Both radios share the link; port 0 and port 1 hear the same frame.
        link!.injectReceived(kissFrame(port: 0, ax25: beacon))
        link!.injectReceived(kissFrame(port: 1, ax25: beacon))

        XCTAssertEqual(heard.count, 1, "one transmission, one packet")
        XCTAssertEqual(engine.crossRadioFolds, 1)
        let base = settings.radios.first { $0.kissPort == 0 }!.id
        let uhf = settings.radios.first { $0.kissPort == 1 }!.id
        let station = engine.stations.first { $0.call == "K0NTS-1" }
        XCTAssertEqual(station?.heardCount, 1)
        XCTAssertEqual(Set(station?.heardOn ?? []), [base, uhf])
    }

    /// Our own transmission on one radio, heard by the other, is logged as
    /// an echo and counted for no station.
    func testOurOwnTransmissionHeardByTheOtherRadioIsAnEchoNotAStation() async {
        let (engine, coordinator, _) = makeStation()
        defer { withExtendedLifetime(coordinator) {} }
        engine.connectUsingSettings()

        var heard: [Packet] = []
        let sub = engine.packetPublisher.sink { heard.append($0) }
        defer { sub.cancel() }

        let frame = AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 7),
                                             to: AX25Address(call: "BEACON"), via: DigiPath(),
                                             pid: 0xF0, payload: Data("beacon".utf8), displayInfo: nil)
        engine.send(frame: frame)
        // The other radio hears exactly what left the first.
        link!.injectReceived(kissFrame(port: 1, ax25: frame.encodeAX25()))

        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard.first?.isOwnEcho, true)
        XCTAssertFalse(engine.stations.contains { $0.call == "K0EPI-7" }, "we are not a station we heard")
        XCTAssertNil(engine.identityCollision, "our own echo is not another station on our callsign")
    }

    /// A folded copy is still this radio's evidence: the link metrics are per
    /// radio, so both radios' entries for the sender fill in, and neither
    /// counts the fold as a retry.
    func testAFoldedCopyFeedsTheSecondRadiosMetricsWithoutARetry() async {
        let (engine, coordinator, settings) = makeStation()
        defer { withExtendedLifetime(coordinator) {} }
        engine.connectUsingSettings()

        // An I-frame to us, direct: the classifier treats it as real evidence.
        let frame = AX25FrameBuilder.buildIFrame(from: AX25Address(call: "K0NTS", ssid: 1),
                                                 to: AX25Address(call: "K0EPI", ssid: 7), via: DigiPath(),
                                                 ns: 0, nr: 0, pid: 0xF0,
                                                 payload: Data("hello".utf8), pf: false,
                                                 sessionId: nil, displayInfo: nil).encodeAX25()
        link!.injectReceived(kissFrame(port: 0, ax25: frame))
        link!.injectReceived(kissFrame(port: 1, ax25: frame))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let base = settings.radios.first { $0.kissPort == 0 }!.id
        let uhf = settings.radios.first { $0.kissPort == 1 }!.id
        let stats = engine.netRomIntegration?.exportLinkStats().filter { $0.fromCall == "K0NTS-1" && $0.toCall == "K0EPI-7" } ?? []
        XCTAssertEqual(Set(stats.map(\.radioID)), [base, uhf], "evidence on both radios")
        XCTAssertEqual(stats.map(\.duplicateCount), [0, 0], "a fold is not a retry on either radio")
        XCTAssertEqual(engine.crossRadioFolds, 1)
    }
}

