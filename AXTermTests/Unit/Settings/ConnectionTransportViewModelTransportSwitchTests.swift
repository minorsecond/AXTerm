import XCTest
@testable import AXTerm

/// The radio form when the operator moves a radio between transports.
///
/// From the 2026-09-30 RF test (Docs/LiveRFTest-2026-09-30.md, bug 6):
/// moving a TNC4 radio from Serial to Bluetooth and back lost the chosen
/// serial device.
@MainActor
final class ConnectionTransportViewModelTransportSwitchTests: XCTestCase {

    /// Not in /dev on any machine, so discovery always reports it missing.
    private static let serialPath = "/dev/cu.usbmodem-axterm-test-missing"
    private static let bleUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"

    private var settings: AppSettingsStore!
    private var engine: PacketEngine!
    private var radioID: RadioID!

    override func setUp() async throws {
        settings = AppSettingsStore(defaults: TestDefaults.make("TransportSwitch"))
        engine = PacketEngine(settings: settings)
        let radio = settings.addRadio()
        radioID = radio.id
        // Off, so nothing tries to open a port or a Bluetooth connection.
        settings.updateRadio(radio.id) {
            $0.enabled = false
            $0.kind = .serial
            $0.serialDevicePath = Self.serialPath
            $0.blePeripheralUUID = Self.bleUUID
            $0.blePeripheralName = "TNC4"
            $0.host = "192.168.3.218"
            $0.port = 8011
        }
    }

    override func tearDown() async throws {
        settings = nil
        engine = nil
    }

    private func makeViewModel() -> ConnectionTransportViewModel {
        ConnectionTransportViewModel(radioID: radioID, settings: settings, packetEngine: engine)
    }

    private var profile: RadioProfile { settings.radio(radioID)! }

    private func waitUntil(_ what: String, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        if !condition() {
            XCTFail("timed out after \(timeout)s waiting for: \(what)", file: file, line: line)
        }
    }

    /// The picker dispatches the change to the next turn of the run loop.
    private func switchTransport(_ vm: ConnectionTransportViewModel, to transport: TransportSelection,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        vm.userDidChangeTransport(transport)
        await waitUntil("the transport to become \(transport.rawValue)", file: file, line: line) {
            vm.selectedTransport == transport && profile.kind == RadioTransportKind(transport)
        }
        // Let the store's echo come back through the form.
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Serial to Bluetooth to Network and back to Serial: every transport
    /// finds what it had.
    func testEachTransportKeepsItsOwnSettingsAcrossSwitches() async {
        let vm = makeViewModel()
        XCTAssertEqual(vm.selectedSerialDevicePath, Self.serialPath)

        await switchTransport(vm, to: .ble)
        XCTAssertEqual(vm.selectedBLEPeripheralID, Self.bleUUID)
        await switchTransport(vm, to: .network)
        XCTAssertEqual(vm.host, "192.168.3.218")
        XCTAssertEqual(vm.port, 8011)
        await switchTransport(vm, to: .serial)

        XCTAssertEqual(vm.selectedSerialDevicePath, Self.serialPath)
        XCTAssertEqual(profile.serialDevicePath, Self.serialPath)
        XCTAssertEqual(profile.blePeripheralUUID, Self.bleUUID)
        XCTAssertEqual(profile.blePeripheralName, "TNC4")
        XCTAssertEqual(profile.host, "192.168.3.218")
        XCTAssertEqual(profile.port, 8011)

        await switchTransport(vm, to: .ble)
        XCTAssertEqual(vm.selectedBLEPeripheralID, Self.bleUUID)
    }

    /// The reported bug. The TNC4 had been taken off USB to try it over
    /// Bluetooth, so its port was missing when the radio came back to Serial,
    /// and ten seconds later the form cleared the choice and saved the empty
    /// path. A missing device stays chosen, shown as unavailable.
    ///
    /// Waits out the old ten-second grace in real time. Starts on Bluetooth
    /// because the form only started that clock the first time it saw the
    /// device missing, and a form opened on Serial has already seen it.
    func testAMissingSerialDeviceStaysChosenAfterSwitchingBack() async {
        // On Bluetooth now, with the serial device from before still saved.
        settings.updateRadio(radioID) { $0.kind = .ble }
        let vm = makeViewModel()
        await switchTransport(vm, to: .serial)
        await waitUntil("discovery to list the saved device as unavailable", timeout: 5) {
            vm.serialDevices.contains { $0.path == Self.serialPath && !$0.isAvailable }
        }

        try? await Task.sleep(for: .seconds(11.5))

        XCTAssertEqual(vm.selectedSerialDevicePath, Self.serialPath, "the form kept the operator's choice")
        XCTAssertEqual(profile.serialDevicePath, Self.serialPath, "and so did the saved radio")
        XCTAssertTrue(vm.serialDevices.contains { $0.path == Self.serialPath && !$0.isAvailable },
                      "still listed, marked unavailable")
        vm.onDisappear()
    }
}

private extension RadioTransportKind {
    init(_ selection: TransportSelection) {
        switch selection {
        case .network: self = .tcp
        case .serial: self = .serial
        case .ble: self = .ble
        case .modem: self = .modem
        }
    }
}
