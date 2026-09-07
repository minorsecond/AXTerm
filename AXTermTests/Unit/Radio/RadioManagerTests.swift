import Combine
import XCTest
@testable import AXTerm

/// The station's links and the radios behind them, on loopback links.
///
/// Radio ≠ link: a Direwolf with two channels is one byte stream carrying two
/// radios, told apart by the KISS port. A second TNC is a second stream.
/// These pin the table between them and what happens to a frame at every
/// step: which radio it is attributed to, which link and port it leaves by,
/// and what a frame on a port nobody claims does.
@MainActor
final class RadioManagerTests: XCTestCase {

    private var links: [String: KISSLinkLoopback] = [:]

    /// A manager whose links are loopbacks, one per link key, remembered so
    /// the tests can inject and inspect. Loopback echo is off: a real TNC
    /// does not hand our own frames back.
    private func makeManager() -> RadioManager {
        links = [:]
        return RadioManager(linkFactory: { [weak self] profile in
            let link = KISSLinkLoopback()
            link.loopbackEnabled = false
            self?.links[profile.linkKey] = link
            return link
        })
    }

    private func tcp(_ id: String, host: String = "192.168.3.218", port: Int = 8001, kissPort: UInt8 = 0) -> RadioProfile {
        var radio = RadioProfile(id: RadioID(rawValue: id), name: id)
        radio.kind = .tcp
        radio.host = host
        radio.port = port
        radio.kissPort = kissPort
        return radio
    }

    private func kiss(port: UInt8, payload: [UInt8]) -> Data {
        Data([0xC0, port << 4] + payload + [0xC0])
    }

    // MARK: - Demux

    /// Two radios on one Direwolf: one link, two ports, each frame to its
    /// own radio.
    func testTwoRadiosOnOneLinkAreToldApartByPort() {
        let manager = makeManager()
        var received: [RadioIngest] = []
        let sub = manager.ingest.sink { received.append($0) }
        defer { sub.cancel() }

        manager.reconcile([tcp("base", kissPort: 0), tcp("uhf", kissPort: 1)], open: true)
        XCTAssertEqual(manager.sessions.count, 1, "one byte stream")
        XCTAssertEqual(links.count, 1)

        let link = links.values.first!
        link.injectReceived(kiss(port: 1, payload: [0x11]))
        link.injectReceived(kiss(port: 0, payload: [0x22]))

        XCTAssertEqual(received.map(\.radio.rawValue), ["uhf", "base"])
        XCTAssertEqual(received.map(\.kissPort), [1, 0])
        XCTAssertEqual(received.map(\.ax25), [Data([0x11]), Data([0x22])])
        XCTAssertEqual(received.first?.tcpEndpoint, KISSEndpoint(host: "192.168.3.218", port: 8001))
    }

    /// Two TNCs are two links.
    func testTwoTNCsAreTwoLinks() {
        let manager = makeManager()
        manager.reconcile([tcp("base"), tcp("remote", host: "10.0.0.5")], open: true)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(Set(links.keys), ["tcp://192.168.3.218:8001", "tcp://10.0.0.5:8001"])
    }

    /// A frame on a port no radio claims is dropped, counted, and reported
    /// once — not silently, and not once per frame.
    func testAFrameOnAnUnclaimedPortIsDroppedAndReportedOnce() {
        let manager = makeManager()
        let spy = DelegateSpy()
        manager.delegate = spy
        var received: [RadioIngest] = []
        let sub = manager.ingest.sink { received.append($0) }
        defer { sub.cancel() }

        manager.reconcile([tcp("base", kissPort: 0)], open: true)
        let link = links.values.first!
        link.injectReceived(kiss(port: 3, payload: [0x01]))
        link.injectReceived(kiss(port: 3, payload: [0x02]))

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(manager.unassignedDrops, 2)
        XCTAssertEqual(spy.unassignedReports, [3])
    }

    // MARK: - Sending

    /// A frame leaves on its radio's link with its radio's port.
    func testAFrameLeavesOnItsRadiosLinkAndPort() {
        let manager = makeManager()
        manager.reconcile([tcp("base", kissPort: 0), tcp("uhf", kissPort: 1), tcp("remote", host: "10.0.0.5")], open: true)

        XCTAssertTrue(manager.send(ax25: Data([0xAA]), radio: RadioID(rawValue: "uhf")))
        XCTAssertTrue(manager.send(ax25: Data([0xBB]), radio: RadioID(rawValue: "remote")))

        let shared = links["tcp://192.168.3.218:8001"]!
        let remote = links["tcp://10.0.0.5:8001"]!
        XCTAssertEqual(shared.sentData, [kiss(port: 1, payload: [0xAA])])
        XCTAssertEqual(remote.sentData, [kiss(port: 0, payload: [0xBB])])
    }

    func testSendingOnAnUnknownOrClosedRadioIsRefused() {
        let manager = makeManager()
        manager.reconcile([tcp("base")], open: false)
        XCTAssertFalse(manager.send(ax25: Data([0x01]), radio: RadioID(rawValue: "base")), "link not open")
        XCTAssertFalse(manager.send(ax25: Data([0x01]), radio: RadioID(rawValue: "nobody")))
    }

    // MARK: - Reconciling

    /// A radio that is still wanted keeps its link; one that is not loses
    /// it; a new one gets one.
    func testReconcileKeepsClosesAndCreates() {
        let manager = makeManager()
        let created = manager.reconcile([tcp("base")], open: true)
        XCTAssertEqual(created, 1)
        let first = manager.sessions["tcp://192.168.3.218:8001"]

        let again = manager.reconcile([tcp("base"), tcp("remote", host: "10.0.0.5")], open: true)
        XCTAssertEqual(again, 1)
        XCTAssertTrue(manager.sessions["tcp://192.168.3.218:8001"] === first, "the kept link is the same object")

        let none = manager.reconcile([tcp("remote", host: "10.0.0.5")], open: true)
        XCTAssertEqual(none, 0)
        XCTAssertNil(manager.sessions["tcp://192.168.3.218:8001"])
        XCTAssertEqual(links["tcp://192.168.3.218:8001"]?.state, .disconnected, "closed on the way out")
    }

    /// Disabled and archived radios get no link.
    func testDisabledAndArchivedRadiosGetNoLink() {
        let manager = makeManager()
        var off = tcp("off", host: "10.0.0.6"); off.enabled = false
        var gone = tcp("gone", host: "10.0.0.7"); gone.archived = true
        manager.reconcile([tcp("base"), off, gone], open: true)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.profiles.map(\.id.rawValue), ["base"])
    }

    /// Opening says "connecting" straight away, so a caller that connects and
    /// reads the state does not see the stale "disconnected".
    func testOpeningReportsConnectingImmediatelyAndStatesFollowTheLink() {
        let manager = makeManager()
        manager.reconcile([tcp("base")], open: false)
        XCTAssertEqual(manager.state(of: RadioID(rawValue: "base")), .disconnected)
        XCTAssertEqual(manager.aggregateStatus, .disconnected)

        manager.openAll()
        // Loopback connects synchronously inside open(), so the optimistic
        // "connecting" has already become "connected".
        XCTAssertEqual(manager.state(of: RadioID(rawValue: "base")), .connected)
        XCTAssertEqual(manager.aggregateStatus, .connected)

        manager.closeAll()
        XCTAssertEqual(manager.state(of: RadioID(rawValue: "base")), .disconnected)
    }

    func testThePrimaryIsTheFirstEnabledRadio() {
        let manager = makeManager()
        var off = tcp("off"); off.enabled = false
        manager.reconcile([off, tcp("base"), tcp("remote", host: "10.0.0.5")], open: false)
        XCTAssertEqual(manager.primaryRadioID, RadioID(rawValue: "base"))
    }

    // MARK: - Spy

    private final class DelegateSpy: RadioManagerDelegate {
        var unassignedReports: [UInt8] = []
        func radioManager(_ manager: RadioManager, link: LinkSession, didReceiveBytes data: Data) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, didReceiveTelemetry frame: Data, port: UInt8) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, didReceiveUnknown command: UInt8, payload: Data) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, didChangeState state: KISSLinkState, from previous: KISSLinkState) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, didError message: String) {}
        func radioManager(_ manager: RadioManager, link: LinkSession, droppedFrameOnUnassignedPort port: UInt8) {
            unassignedReports.append(port)
        }
    }
}
