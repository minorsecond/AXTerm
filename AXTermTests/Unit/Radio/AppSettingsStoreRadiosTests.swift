import XCTest
@testable import AXTerm

/// The radio list inside the settings store, and its two-way mirror onto the
/// single-connection scalars the engine still reads.
///
/// The mirror is the whole reason the rest of the app keeps working while
/// radios are introduced one layer at a time: the engine, the toolbar and the
/// tests all still speak `host`/`port`/`transportType`, and those must mean
/// "the primary radio" without anyone having to know that.
@MainActor
final class AppSettingsStoreRadiosTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AXTermTests.Radios.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Migration

    /// A station that had one TNC before this build has one radio after it,
    /// with the fixed primary id the database migration will use too.
    func testTheFirstLaunchReadsTheOldConnectionIntoOneRadio() {
        defaults.set("kiss.local", forKey: AppSettingsStore.hostKey)
        defaults.set(8010, forKey: AppSettingsStore.portKey)
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.radios.count, 1)
        let radio = store.radios[0]
        XCTAssertEqual(radio.id, RadioIdentity.primaryID(defaults: defaults))
        XCTAssertEqual(radio.kind, .tcp)
        XCTAssertEqual(radio.host, "kiss.local")
        XCTAssertEqual(radio.port, 8010)
        XCTAssertEqual(radio.name, "Direwolf")
        XCTAssertFalse(store.hasMultipleRadios)
        XCTAssertEqual(store.primaryRadio?.id, radio.id)
    }

    func testASerialStationMigratesAsASerialRadio() {
        defaults.set("serial", forKey: AppSettingsStore.transportTypeKey)
        defaults.set("/dev/cu.usbmodem1420", forKey: AppSettingsStore.serialDevicePathKey)
        defaults.set(9600, forKey: AppSettingsStore.serialBaudRateKey)
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.radios[0].kind, .serial)
        XCTAssertEqual(store.radios[0].serialDevicePath, "/dev/cu.usbmodem1420")
        XCTAssertEqual(store.radios[0].serialBaudRate, 9600)
        XCTAssertEqual(store.radios[0].name, "usbmodem1420")
    }

    /// The second launch finds the list and does not mint a second radio.
    func testTheMigrationRunsOnce() {
        let first = AppSettingsStore(defaults: defaults)
        first.updateRadio(first.radios[0].id) { $0.name = "Base" }
        let second = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(second.radios.count, 1)
        XCTAssertEqual(second.radios[0].id, first.radios[0].id)
        XCTAssertEqual(second.radios[0].name, "Base")
    }

    // MARK: - The mirror

    /// Editing the primary radio is editing the connection.
    func testEditingThePrimaryRadioWritesTheLegacyScalars() {
        let store = AppSettingsStore(defaults: defaults)
        store.updateRadio(store.radios[0].id) {
            $0.host = "10.0.0.5"
            $0.port = 8020
            $0.kind = .serial
            $0.serialDevicePath = "/dev/cu.tnc"
            $0.mobilinkdEnabled = true
        }
        XCTAssertEqual(store.host, "10.0.0.5")
        XCTAssertEqual(store.port, 8020)
        XCTAssertEqual(store.transportType, "serial")
        XCTAssertTrue(store.isSerialTransport)
        XCTAssertEqual(store.serialDevicePath, "/dev/cu.tnc")
        XCTAssertTrue(store.mobilinkdEnabled)
        XCTAssertEqual(defaults.string(forKey: AppSettingsStore.hostKey), "10.0.0.5")
    }

    /// The old writers still exist — the engine's auto-gain, for one — and
    /// what they write must show up in the radio.
    func testWritingALegacyScalarUpdatesThePrimaryRadio() {
        let store = AppSettingsStore(defaults: defaults)
        store.host = "1.2.3.4"
        store.mobilinkdInputGain = 3
        XCTAssertEqual(store.radios[0].host, "1.2.3.4")
        XCTAssertEqual(store.radios[0].mobilinkdInputGain, 3)
    }

    /// Both directions at once do not chase each other: after a round trip
    /// everything agrees and nothing is left dirty.
    func testTheMirrorSettles() {
        let store = AppSettingsStore(defaults: defaults)
        store.updateRadio(store.radios[0].id) { $0.host = "a.local" }
        store.host = "b.local"
        store.updateRadio(store.radios[0].id) { $0.port = 9001 }
        XCTAssertEqual(store.radios[0].host, "b.local")
        XCTAssertEqual(store.host, "b.local")
        XCTAssertEqual(store.radios[0].port, 9001)
        XCTAssertEqual(store.port, 9001)
    }

    // MARK: - Several radios

    /// A second radio is a second radio: the connection scalars keep
    /// describing the first.
    func testAddingARadioLeavesTheConnectionAlone() {
        let store = AppSettingsStore(defaults: defaults)
        let added = store.addRadio()
        XCTAssertEqual(store.radios.count, 2)
        XCTAssertTrue(store.hasMultipleRadios)
        XCTAssertEqual(added.name, "Radio 2")
        store.updateRadio(added.id) { $0.host = "second.local" }
        XCTAssertEqual(store.host, AppSettingsStore.defaultHost)
        XCTAssertEqual(store.primaryRadio?.id, store.radios[0].id)
    }

    /// Switching the first radio off makes the next one primary, and the
    /// connection follows it.
    func testDisablingThePrimaryPromotesTheNextRadio() {
        let store = AppSettingsStore(defaults: defaults)
        let first = store.radios[0].id
        let second = store.addRadio().id
        store.updateRadio(second) { $0.host = "second.local" }
        store.updateRadio(first) { $0.enabled = false }
        XCTAssertEqual(store.primaryRadio?.id, second)
        XCTAssertEqual(store.host, "second.local")
    }

    func testReorderingChangesThePrimary() {
        let store = AppSettingsStore(defaults: defaults)
        let second = store.addRadio().id
        store.updateRadio(second) { $0.host = "second.local" }
        store.moveRadios(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(store.primaryRadio?.id, second)
        XCTAssertEqual(store.host, "second.local")
    }

    /// Removed radios stay in storage, off the visible list; the last one
    /// cannot be removed at all.
    func testRemovingArchivesAndTheLastRadioStays() {
        let store = AppSettingsStore(defaults: defaults)
        let first = store.radios[0].id
        store.archiveRadio(first)
        XCTAssertEqual(store.activeRadios.count, 1, "the only radio is kept")

        let second = store.addRadio().id
        store.archiveRadio(first)
        XCTAssertEqual(store.activeRadios.map(\.id), [second])
        XCTAssertEqual(store.radios.count, 2, "archived, not deleted")
        XCTAssertEqual(store.primaryRadio?.id, second)
    }

    /// The list is persisted as it changes and comes back whole.
    func testTheListPersists() {
        let store = AppSettingsStore(defaults: defaults)
        let second = store.addRadio().id
        store.updateRadio(second) { $0.name = "IC-705"; $0.kind = .ble; $0.blePeripheralName = "TNC4" }
        let again = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(again.radios.map(\.id), store.radios.map(\.id))
        XCTAssertEqual(again.radio(second)?.name, "IC-705")
        XCTAssertEqual(again.radio(second)?.kind, .ble)
    }
}
