import CoreBluetooth
import XCTest
@testable import AXTerm

/// What the radio form says when a Bluetooth scan comes back empty.
///
/// From the 2026-09-30 RF test (Docs/LiveRFTest-2026-09-30.md, I-3): the scan
/// found nothing while the Mobilinkd configuration app held the TNC4's
/// Bluetooth connection, and for a while after the TNC4 was switched from
/// USB, and the form said nothing at all. No scan runs here: the scanner's
/// scanning flag is played into the form by hand.
@MainActor
final class BLEScanNoticeTests: XCTestCase {

    private var settings: AppSettingsStore!
    private var engine: PacketEngine!
    private var radioID: RadioID!

    override func setUp() async throws {
        settings = AppSettingsStore(defaults: TestDefaults.make("BLEScanNotice"))
        engine = PacketEngine(settings: settings)
        let radio = settings.addRadio()
        radioID = radio.id
        // Off, so nothing tries to make a Bluetooth connection.
        settings.updateRadio(radio.id) {
            $0.enabled = false
            $0.kind = .ble
        }
    }

    override func tearDown() async throws {
        settings = nil
        engine = nil
    }

    /// Nothing is said while the scan runs. When the scan window ends with
    /// nothing found, the form says why that may be.
    func testAnEmptyScanExplainsItselfOnlyOnceTheScanEnds() {
        let vm = ConnectionTransportViewModel(radioID: radioID, settings: settings, packetEngine: engine)
        XCTAssertEqual(vm.selectedTransport, .ble)
        XCTAssertNil(vm.bleScanNotice)

        vm.bleScanDidChange(isScanning: true, found: 0, bluetoothState: .poweredOn)
        XCTAssertNil(vm.bleScanNotice, "nothing to say while the scan is still running")

        vm.bleScanDidChange(isScanning: false, found: 0, bluetoothState: .poweredOn)
        XCTAssertEqual(vm.bleScanNotice, BLEScanNotice.nothingFound)
        XCTAssertTrue(vm.bleScanNotice?.contains("Mobilinkd configuration app") == true)
        XCTAssertTrue(vm.bleScanNotice?.contains("power cycle") == true)

        vm.bleScanDidChange(isScanning: true, found: 0, bluetoothState: .poweredOn)
        XCTAssertNil(vm.bleScanNotice, "a new scan clears it")

        vm.bleScanDidChange(isScanning: false, found: 1, bluetoothState: .poweredOn)
        XCTAssertNil(vm.bleScanNotice, "a scan that found something has nothing to explain")
    }

    /// The wording, and the cases that need different words.
    func testTheNoticeFitsWhatHappened() {
        XCTAssertEqual(BLEScanNotice.afterScan(found: 0, bluetoothState: .poweredOn, thisRadioConnected: false),
                       BLEScanNotice.nothingFound)
        XCTAssertNil(BLEScanNotice.afterScan(found: 2, bluetoothState: .poweredOn, thisRadioConnected: false))
        XCTAssertNil(BLEScanNotice.afterScan(found: 0, bluetoothState: .poweredOn, thisRadioConnected: true),
                     "a TNC connected to this radio stops advertising, and the radio page already says it is connected")
        XCTAssertEqual(BLEScanNotice.afterScan(found: 0, bluetoothState: .poweredOff, thisRadioConnected: false),
                       BLEScanNotice.bluetoothOff)
        XCTAssertEqual(BLEScanNotice.afterScan(found: 0, bluetoothState: .unauthorized, thisRadioConnected: false),
                       BLEScanNotice.notAllowed)

        XCTAssertEqual(BLEScanNotice.afterScan(found: 0, bluetoothState: .unknown, thisRadioConnected: false),
                       BLEScanNotice.notReady,
                       "Bluetooth not answering yet is not \"no TNC\": iOS may still be asking for permission")
        XCTAssertEqual(BLEScanNotice.afterScan(found: 0, bluetoothState: .resetting, thisRadioConnected: false),
                       BLEScanNotice.notReady)

        for text in [BLEScanNotice.nothingFound, BLEScanNotice.bluetoothOff, BLEScanNotice.notAllowed,
                     BLEScanNotice.notReady] {
            XCTAssertFalse(text.contains("\u{2014}"), "no em dashes in UI text")
        }
    }

    /// While iOS asks for Bluetooth permission the scanner hears `.unknown`.
    /// Ending the scan there reported "No TNC found" before the operator had
    /// even answered (smoke run 2026-10-03-1, test 13.3, issue 107).
    func testAScanWaitsWhileBluetoothIsNotReady() {
        XCTAssertFalse(BLEScanNotice.endsScan(on: .unknown))
        XCTAssertFalse(BLEScanNotice.endsScan(on: .resetting))
        XCTAssertFalse(BLEScanNotice.endsScan(on: .poweredOn))
        XCTAssertTrue(BLEScanNotice.endsScan(on: .poweredOff))
        XCTAssertTrue(BLEScanNotice.endsScan(on: .unauthorized))
        XCTAssertTrue(BLEScanNotice.endsScan(on: .unsupported))
    }
}
