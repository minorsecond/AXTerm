import XCTest
@testable import AXTerm

/// Disconnect means stop, and a link that is no longer configured is gone.
///
/// Found on the air on 2026-09-30 (Docs/LiveRFTest-2026-09-30.md, bug 7): a
/// TNC4 on USB kept being reopened after the operator pressed Disconnect, and
/// after they moved the radio to Bluetooth, so lsof still showed AXTerm on
/// /dev/cu.usbmodem… and an outside probe could not have the port to itself.
/// These run on fake links that count opens and closes; nothing here opens
/// a port.
@MainActor
final class OperatorDisconnectTests: XCTestCase {

    /// A link that only counts. Opening connects at once, as a loopback does.
    private final class CountingLink: KISSLink {
        let key: String
        private(set) var state: KISSLinkState = .disconnected
        weak var delegate: KISSLinkDelegate?
        private(set) var opens = 0
        private(set) var closes = 0
        var endpointDescription: String { key }

        init(key: String) { self.key = key }

        func open() {
            opens += 1
            state = .connected
            delegate?.linkDidChangeState(.connected)
        }

        func close() {
            closes += 1
            state = .disconnected
            delegate?.linkDidChangeState(.disconnected)
        }

        func send(_ data: Data, completion: @escaping (Error?) -> Void) { completion(nil) }
    }

    /// Every link the factory made, in order, so a test can ask about the
    /// old one after a new one replaced it.
    private var made: [CountingLink] = []

    private func factory() -> RadioManager.LinkFactory {
        { [weak self] profile in
            let link = CountingLink(key: profile.linkKey)
            self?.made.append(link)
            return link
        }
    }

    private func link(_ key: String) -> CountingLink? { made.last { $0.key == key } }

    private func serialRadio(_ id: String = "tnc4") -> RadioProfile {
        var radio = RadioProfile(id: RadioID(rawValue: id), name: id)
        radio.kind = .serial
        radio.serialDevicePath = "/dev/cu.usbmodem-axterm-test"
        radio.blePeripheralUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        return radio
    }

    /// The settings sink debounces for 500 ms. Long enough for it to have
    /// run, for a test that expects it to have done nothing.
    private func letTheSettingsSinkRun() async {
        try? await Task.sleep(for: .milliseconds(900))
    }

    // MARK: - The manager

    /// A wake reopens what was up when the lid closed, and nothing the
    /// operator had closed.
    func testAWakeDoesNotReopenALinkTheOperatorClosed() {
        let manager = RadioManager(linkFactory: factory())
        let radio = serialRadio()
        manager.reconcile([radio], open: true)
        let serial = try! XCTUnwrap(link(radio.linkKey))
        XCTAssertEqual(serial.opens, 1)

        manager.closeAll()
        manager.suspendAll()
        manager.resumeAll()
        XCTAssertEqual(serial.opens, 1, "Disconnect holds through a sleep and wake")
        XCTAssertEqual(serial.state, .disconnected)

        manager.reconcile([radio], open: true)
        XCTAssertEqual(serial.opens, 2, "connecting again lifts the hold")
        manager.suspendAll()
        manager.resumeAll()
        XCTAssertEqual(serial.opens, 3, "and a wake reopens a wanted link as before")
    }

    /// A settings write after Disconnect brings the links into line with the
    /// settings and opens none of them.
    func testASettingsChangeAfterDisconnectOpensNothing() {
        let manager = RadioManager(linkFactory: factory())
        var radio = serialRadio()
        manager.reconcile([radio], open: true)
        manager.closeAll()

        radio.tnc4.inputGain = 3
        manager.reconcileAfterSettingsChange([radio])
        XCTAssertEqual(link(radio.linkKey)?.opens, 1)

        radio.kind = .ble
        manager.reconcileAfterSettingsChange([radio])
        let ble = try! XCTUnwrap(link(radio.linkKey))
        XCTAssertEqual(ble.opens, 0, "the new transport's link waits for Connect")
        XCTAssertNil(manager.sessions[serialRadio().linkKey], "the old transport's link is gone")
    }

    /// With the settings page open the engine applies settings in place, and
    /// used to leave a link whose transport had changed open until the page
    /// closed. The old link goes the moment its transport is no longer the
    /// radio's.
    func testATransportChangeWhileSettingsAreOpenRetiresTheOldLink() {
        let manager = RadioManager(linkFactory: factory())
        let radio = serialRadio()
        manager.reconcile([radio], open: true)
        let serial = try! XCTUnwrap(link(radio.linkKey))

        var moved = radio
        moved.kind = .ble
        manager.applyInPlace([moved])

        XCTAssertEqual(serial.closes, 1, "the serial port is let go")
        XCTAssertNil(manager.sessions[radio.linkKey])
        XCTAssertNil(manager.session(for: radio.id), "the radio no longer points at it")
        XCTAssertEqual(manager.state(of: radio.id), .disconnected)
        XCTAssertNil(manager.sessions[moved.linkKey], "and nothing new is opened while the page is open")

        manager.suspendAll()
        manager.resumeAll()
        XCTAssertEqual(serial.opens, 1, "a retired link never comes back")
    }

    // MARK: - The engine

    private func makeEngine() -> (PacketEngine, AppSettingsStore, RadioID) {
        let settings = AppSettingsStore(defaults: TestDefaults.make("OperatorDisconnect"))
        let id = settings.radios[0].id
        settings.updateRadio(id) {
            $0.kind = .serial
            $0.serialDevicePath = "/dev/cu.usbmodem-axterm-test"
            $0.blePeripheralUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
            $0.enabled = true
        }
        let engine = PacketEngine(settings: settings, linkFactory: factory())
        return (engine, settings, id)
    }

    /// The reported bug: Disconnect, then anything that writes the radio's
    /// settings, and the port was open again.
    func testDisconnectHoldsAgainstLaterSettingsWrites() async {
        let (engine, settings, id) = makeEngine()
        defer { withExtendedLifetime(engine) {} }
        engine.connectUsingSettings()
        let key = try! XCTUnwrap(settings.radio(id)?.linkKey)
        XCTAssertEqual(link(key)?.opens, 1)

        engine.disconnect(reason: "test")
        settings.updateRadio(id) { $0.tnc4.inputGain = 3 }
        await letTheSettingsSinkRun()
        XCTAssertEqual(link(key)?.opens, 1, "nothing reopens a link the operator closed")
        XCTAssertEqual(link(key)?.state, .disconnected)

        engine.connectUsingSettings()
        XCTAssertEqual(link(key)?.opens, 2, "until the operator connects again")
    }

    /// Disconnect on the radio's page, switch it to Bluetooth, leave the
    /// page: the page closing used to connect whatever the settings said.
    func testLeavingTheRadioPageAfterDisconnectConnectsNothing() async {
        let (engine, settings, id) = makeEngine()
        defer { withExtendedLifetime(engine) {} }
        engine.connectUsingSettings()
        let serialKey = try! XCTUnwrap(settings.radio(id)?.linkKey)

        engine.isConnectionLogicSuspended = true
        engine.disconnect(reason: "test")
        settings.updateRadio(id) { $0.kind = .ble }
        await letTheSettingsSinkRun()
        engine.isConnectionLogicSuspended = false
        await letTheSettingsSinkRun()

        let bleKey = try! XCTUnwrap(settings.radio(id)?.linkKey)
        XCTAssertNotEqual(bleKey, serialKey)
        XCTAssertEqual(link(serialKey)?.opens, 1, "the serial link stays closed")
        XCTAssertNil(engine.radioManager.sessions[serialKey], "and is gone")
        XCTAssertEqual(link(bleKey)?.opens ?? 0, 0, "the Bluetooth link waits for Connect")
        XCTAssertNotEqual(engine.status, .connecting)
    }

    /// Without a Disconnect, switching transport on the open page lets go of
    /// the old port at once; closing the page connects the new one.
    func testATransportChangeOnTheOpenPageLetsGoOfThePortAtOnce() async {
        let (engine, settings, id) = makeEngine()
        defer { withExtendedLifetime(engine) {} }
        engine.connectUsingSettings()
        let serialKey = try! XCTUnwrap(settings.radio(id)?.linkKey)
        let serial = try! XCTUnwrap(link(serialKey))

        engine.isConnectionLogicSuspended = true
        settings.updateRadio(id) { $0.kind = .ble }
        await letTheSettingsSinkRun()
        XCTAssertEqual(serial.closes, 1, "the serial port is let go while the page is still open")
        XCTAssertNil(engine.radioManager.sessions[serialKey])

        engine.isConnectionLogicSuspended = false
        let bleKey = try! XCTUnwrap(settings.radio(id)?.linkKey)
        XCTAssertEqual(link(bleKey)?.opens, 1, "closing the page connects the new transport")
        XCTAssertEqual(serial.opens, 1, "and never the old one")
    }
}
