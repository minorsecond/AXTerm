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
        settings.myCallsign = "TEST-7"

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
        coordinator.localCallsign = "TEST-7"
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
        let local = AX25Address(call: "TEST", ssid: 7)
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
        XCTAssertEqual(decoded?.from?.display, "TEST-7")
    }

    /// The same peer calling on the primary radio is a different session,
    /// answered on port 0.
    func testTheSamePeerOnThePrimaryRadioIsAnsweredOnPortZero() async {
        let (engine, coordinator, settings) = makeStation()
        engine.connectUsingSettings()

        let peer = AX25Address(call: "PEER", ssid: 1)
        let local = AX25Address(call: "TEST", ssid: 7)
        let sabm = AX25FrameBuilder.buildSABM(from: peer, to: local, via: DigiPath(), extended: false).encodeAX25()

        link!.injectReceived(kissFrame(port: 1, ax25: sabm))
        link!.injectReceived(kissFrame(port: 0, ax25: sabm))
        await waitForReplies(2)
        defer { withExtendedLifetime(coordinator) {} }

        XCTAssertEqual(replies.count, 2, diagnostics(engine, coordinator, peer: peer, local: local, radio: .primary))
        XCTAssertEqual(replies.map(\.port), [1, 0])
        let uhf = settings.radios.first { $0.kissPort == 1 }!.id
        let base = settings.radios.first { $0.kissPort == 0 }!.id
        let onUHF = coordinator.sessionManager.existingSession(for: peer, path: DigiPath(), radio: uhf)
        let onBase = coordinator.sessionManager.existingSession(for: peer, path: DigiPath(), radio: base)
        XCTAssertNotNil(onUHF, "one peer, two radios, two sessions")
        XCTAssertNotNil(onBase)
        XCTAssertNotEqual(onUHF?.key, onBase?.key)
    }
}
