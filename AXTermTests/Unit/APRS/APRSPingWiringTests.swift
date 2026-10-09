import Combine
import XCTest
@testable import AXTerm

/// The APRS ping, wired the same way in both apps.
///
/// On 2026-10-09 the operator, driving with the iPhone, went to ping A (705)
/// and could not find Ping: the map shows it only when the app hands it a
/// query handler, and the iPhone app never did. The Mac's wiring now lives
/// here and both apps use it.
@MainActor
final class APRSPingWiringTests: XCTestCase {
    private var link: KISSLinkLoopback?

    private func makeStation() -> (PacketEngine, SessionCoordinator) {
        let settings = AppSettingsStore(defaults: TestDefaults.make("ping-wiring"))
        settings.updateRadio(settings.radios[0].id) {
            $0.host = "127.0.0.1"; $0.port = 8001
            RadioChannel.aprs.apply(to: &$0)
            $0.aprsPath = "WIDE1-1,WIDE2-1"
        }
        settings.adoptStationCallsign("K0EPI-3")
        let engine = PacketEngine(settings: settings, linkFactory: { [weak self] _ in
            if let existing = self?.link { return existing }
            let fresh = KISSLinkLoopback()
            fresh.loopbackEnabled = false
            self?.link = fresh
            return fresh
        })
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "K0EPI-3"
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: engine)
        engine.connectUsingSettings()
        return (engine, coordinator)
    }

    private var sentFrames: [AX25.FrameDecodeResult] {
        (link?.sentData ?? []).compactMap { kiss in
            var parser = KISSFrameParser()
            guard let frame = parser.feedFrames(kiss).first, case .ax25(let ax25) = frame.output
            else { return nil }
            return AX25.decodeFrame(ax25: ax25)
        }
    }

    func testADirectPingGoesOutWithNoPathAndIsTracked() async {
        let (_, coordinator) = makeStation()
        defer { withExtendedLifetime(coordinator) {} }
        let pings = APRSPingTracker()
        let sent = APRSPingWiring.sendQuery(
            APRSStationQuery(callsign: "K0EPI-2", kind: .position, reach: .direct),
            coordinator: coordinator, pings: pings)
        XCTAssertTrue(sent)
        let query = sentFrames.last
        XCTAssertEqual(query?.info, Data(APRSMessage.directedQueryInfo(to: "K0EPI-2", query: "?APRSP").utf8))
        XCTAssertEqual(query?.via.count, 0, "direct: can you hear me, and nothing else")
        XCTAssertEqual(pings.outcome(for: "K0EPI-2")?.outcome, .waiting)
    }

    func testAWidePingUsesTheRadiosPath() async {
        let (_, coordinator) = makeStation()
        defer { withExtendedLifetime(coordinator) {} }
        _ = APRSPingWiring.sendQuery(
            APRSStationQuery(callsign: "K0EPI-2", kind: .position, reach: .wide),
            coordinator: coordinator, pings: APRSPingTracker())
        XCTAssertEqual(sentFrames.last?.via.map(\.display), ["WIDE1-1", "WIDE2-1"])
    }

    /// Attached to the engine, the tracker hears the channel: our own frame
    /// repeated by a digipeater is proof that digipeater hears us.
    func testAnAttachedTrackerHearsADigipeaterRepeatUs() async {
        let (engine, coordinator) = makeStation()
        defer { withExtendedLifetime(coordinator) {} }
        let pings = APRSPingTracker()
        let coverage = CoverageEvidenceStore()
        let attachment = APRSPingWiring.attach(pings: pings, coverage: coverage, to: engine,
                                               myCallsign: "K0EPI-3")
        defer { attachment.cancel() }
        XCTAssertEqual(pings.isOurs?("K0EPI-9"), true, "any SSID of our license")
        XCTAssertEqual(pings.isOurs?("W0NED"), false)

        // Our beacon on its way back, W0NED's has-been-repeated bit set.
        let echo = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "K0EPI", ssid: 3), to: AX25Address(call: "APZAXT"),
            via: DigiPath([AX25Address(call: "W0NED", repeated: true)]), pid: 0xF0,
            payload: Data("!position".utf8), displayInfo: nil).encodeAX25()
        link!.injectReceived(KISS.encodeFrame(payload: echo, port: 0))
        for _ in 0..<50 where pings.repeatedUs("W0NED") == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(pings.repeatedUs("W0NED"))
    }
}
