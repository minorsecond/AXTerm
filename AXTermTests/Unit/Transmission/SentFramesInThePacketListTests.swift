import Combine
import XCTest
@testable import AXTerm

/// A frame we send joins the engine's packet list as it goes out.
///
/// It used to be written to the database only, so the list (and everything
/// reading it: car mode's last-beacon line, the Packets view) saw our own
/// beacons only after a relaunch reloaded the history. On the APRS drive
/// (2026-10-09) car mode said "No beacon yet" through 28 beacons.
@MainActor
final class SentFramesInThePacketListTests: XCTestCase {
    private var link: KISSLinkLoopback?

    private func makeEngine() -> PacketEngine {
        let settings = AppSettingsStore(defaults: TestDefaults.make("sent-frames"))
        settings.updateRadio(settings.radios[0].id) { $0.host = "127.0.0.1"; $0.port = 8001 }
        settings.adoptStationCallsign("K0EPI-3")
        let engine = PacketEngine(settings: settings, linkFactory: { [weak self] _ in
            if let existing = self?.link { return existing }
            let fresh = KISSLinkLoopback()
            fresh.loopbackEnabled = false
            self?.link = fresh
            return fresh
        })
        engine.connectUsingSettings()
        return engine
    }

    private func beacon() -> OutboundFrame {
        AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 3),
                                 to: AX25Address(call: "APZAXT"), via: DigiPath(),
                                 pid: 0xF0, payload: Data("!/:KlX4#-@>  ATesting car".utf8),
                                 displayInfo: nil)
    }

    func testABeaconWeSendIsInThePacketListAsSent() async {
        let engine = makeEngine()
        XCTAssertEqual(engine.status, .connected)
        let frame = beacon()
        engine.send(frame: frame)
        let logged = engine.packets.first { $0.id == frame.id }
        XCTAssertEqual(logged?.direction, .tx)
        XCTAssertEqual(logged?.from?.display, "K0EPI-3")
        XCTAssertEqual(logged?.frameType, .ui)
    }

    /// Joining the list is all it does: it is not published as heard, so
    /// nothing counts it as a station, a ping answer or coverage evidence.
    func testASentFrameIsNotTreatedAsHeard() async {
        let engine = makeEngine()
        var heard: [Packet] = []
        let sub = engine.packetPublisher.sink { heard.append($0) }
        defer { sub.cancel() }
        engine.send(frame: beacon())
        XCTAssertTrue(heard.isEmpty)
        XCTAssertFalse(engine.stations.contains { $0.call == "K0EPI-3" })
    }
}
