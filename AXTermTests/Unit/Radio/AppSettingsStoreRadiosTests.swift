import XCTest
@testable import AXTerm

/// The radio list inside the settings store: the one record of how the
/// station's TNCs are reached. The old single-connection scalars are read
/// once, on the first launch after the update, and never written again.
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

    /// The beacon used to be one station-wide setting; it is now per radio.
    /// On first launch the legacy beacon is seeded onto the first radio and
    /// the migration is marked done so it never runs twice.
    func testTheLegacyBeaconSeedsOntoTheFirstRadioOnce() {
        defaults.set(true, forKey: AppSettingsStore.beaconEnabledKey)
        defaults.set("K0EPI Colorado packet", forKey: AppSettingsStore.beaconTextKey)
        defaults.set("WIDE1-1", forKey: AppSettingsStore.beaconPathKey)
        defaults.set(20, forKey: AppSettingsStore.beaconMinutesKey)

        let store = AppSettingsStore(defaults: defaults)
        let beacon = store.radios[0].beacon
        XCTAssertTrue(beacon.enabled)
        XCTAssertEqual(beacon.kind, .text)
        XCTAssertEqual(beacon.text, "K0EPI Colorado packet")
        XCTAssertEqual(beacon.path, "WIDE1-1")
        XCTAssertEqual(beacon.intervalMinutes, 20)
        XCTAssertTrue(defaults.bool(forKey: AppSettingsStore.beaconPerRadioMigratedKey))

        // Idempotent: a later launch does not re-seed. Clear the radio's
        // beacon, rebuild, and it stays cleared because the flag is set.
        store.updateRadio(store.radios[0].id) { $0.beacon = BeaconConfig() }
        let reopened = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(reopened.radios[0].beacon.enabled)
    }

    /// A second radio added later must not inherit the first radio's beacon:
    /// its beacon stays off until the operator configures it.
    func testAnAddedRadioDoesNotInheritTheBeacon() {
        defaults.set(true, forKey: AppSettingsStore.beaconEnabledKey)
        defaults.set("packet node", forKey: AppSettingsStore.beaconTextKey)
        let store = AppSettingsStore(defaults: defaults)
        _ = store.addRadio()
        XCTAssertTrue(store.hasMultipleRadios)
        XCTAssertTrue(store.radios[0].beacon.enabled)
        XCTAssertFalse(store.radios[1].beacon.enabled)
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

    // MARK: - The old keys are read once

    /// The first launch writes the list at once, so the migration is over
    /// before anything else runs and the old keys are never consulted again.
    func testTheMigrationWritesTheListImmediately() {
        defaults.set("10.0.0.5", forKey: AppSettingsStore.hostKey)
        _ = AppSettingsStore(defaults: defaults)
        XCTAssertNotNil(defaults.string(forKey: AppSettingsStore.radiosKey))
        // A later change to the old key is nobody's business.
        defaults.set("changed.later", forKey: AppSettingsStore.hostKey)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).primaryRadio?.host, "10.0.0.5")
    }

    /// Editing a radio edits the list and only the list: nothing writes the
    /// old keys any more.
    func testEditingThePrimaryRadioDoesNotTouchTheOldKeys() {
        let store = AppSettingsStore(defaults: defaults)
        store.updateRadio(store.radios[0].id) {
            $0.host = "10.0.0.5"
            $0.port = 8020
            $0.kind = .serial
            $0.serialDevicePath = "/dev/cu.tnc"
        }
        // What was actually written, not what `register(defaults:)` answers.
        let written = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertNil(written[AppSettingsStore.hostKey])
        XCTAssertNil(written[AppSettingsStore.portKey])
        XCTAssertNil(written[AppSettingsStore.transportTypeKey])
        XCTAssertEqual(store.primaryRadio?.host, "10.0.0.5")
        XCTAssertEqual(store.primaryRadio?.kind, .serial)
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
        XCTAssertEqual(store.primaryRadio?.host, AppSettingsStore.defaultHost)
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
        XCTAssertEqual(store.primaryRadio?.host, "second.local")
    }

    func testReorderingChangesThePrimary() {
        let store = AppSettingsStore(defaults: defaults)
        let second = store.addRadio().id
        store.updateRadio(second) { $0.host = "second.local" }
        store.moveRadios(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(store.primaryRadio?.id, second)
        XCTAssertEqual(store.primaryRadio?.host, "second.local")
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
