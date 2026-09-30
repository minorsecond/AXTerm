//
//  SettingsUpgradeCompatibilityTests.swift
//  AXTermTests
//
//  The settings redesign moved controls between pages and renamed nothing
//  in storage. A radios blob written by the build before it loads to the
//  same radios, reads as the same channels, and writes back the same values.
//

import XCTest
@testable import AXTerm

@MainActor
final class SettingsUpgradeCompatibilityTests: XCTestCase {

    /// Two radios as the previous build stored them: a packet radio with a
    /// text beacon, a digipeater and its services trimmed, and an APRS radio
    /// with a position beacon at a fixed spot. The older encoder also wrote
    /// `sendsBeacons` and knew nothing of `sendsKISSTiming`.
    private func previousBuildBlob() throws -> (json: String, radios: [[String: Any]]) {
        var packet = RadioProfile(id: .primary, name: "Base")
        packet.kind = .tcp
        packet.host = "192.168.3.218"
        packet.callsign = "K0EPI-7"
        packet.pings = false
        packet.beacon = BeaconConfig(enabled: true, kind: .text, text: "K0EPI node", path: "WIDE1-1",
                                     intervalMinutes: 20)
        packet.digi = DigiConfig(enabled: true, fillIn: false, wideAreaMaxHops: 1, aliases: ["DWARC"])
        packet.txDelayMs = 400

        var aprs = RadioProfile(id: RadioID(rawValue: "ic-v8"), name: "IC-V8")
        aprs.kind = .ble
        aprs.blePeripheralUUID = UUID().uuidString
        aprs.callsign = "K0EPI-9"
        aprs.aprsEnabled = true
        aprs.aprsPath = "WIDE1-1,WIDE2-1"
        aprs.beacon = BeaconConfig(enabled: true, kind: .aprsPosition, intervalMinutes: 10,
                                   aprs: APRSPositionConfig(useGPS: false, latitude: 39.6,
                                                            longitude: -105.0, symbolTable: "/",
                                                            symbolCode: ">", comment: "mobile"))
        aprs.txDelayMs = 500

        let data = try JSONEncoder().encode([packet, aprs])
        var dicts = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for index in dicts.indices {
            dicts[index]["sendsBeacons"] = true
            dicts[index].removeValue(forKey: "sendsKISSTiming")
        }
        let old = try JSONSerialization.data(withJSONObject: dicts)
        return (try XCTUnwrap(String(data: old, encoding: .utf8)), dicts)
    }

    private func upgradedStore() throws -> (AppSettingsStore, [[String: Any]], UserDefaults) {
        let defaults = TestDefaults.make("SettingsUpgrade")
        let (json, dicts) = try previousBuildBlob()
        defaults.set(json, forKey: AppSettingsStore.radiosKey)
        defaults.set("K0EPI", forKey: AppSettingsStore.myCallsignKey)
        // The one-time migrations had already run on this station.
        defaults.set(true, forKey: AppSettingsStore.beaconPerRadioMigratedKey)
        defaults.set(true, forKey: AppSettingsStore.aprsSeededFromBeaconKey)
        defaults.set(true, forKey: AppSettingsStore.pingEnabledKey)
        defaults.set(true, forKey: AppSettingsStore.netRomAdvertiseKey)
        return (AppSettingsStore(defaults: defaults), dicts, defaults)
    }

    func testTheRadiosLoadAsTheyWere() throws {
        let (settings, _, _) = try upgradedStore()
        XCTAssertEqual(settings.activeRadios.map(\.name), ["Base", "IC-V8"])
        let base = try XCTUnwrap(settings.radio(.primary))
        let v8 = try XCTUnwrap(settings.radio(RadioID(rawValue: "ic-v8")))

        XCTAssertEqual(RadioChannel.of(base), .packet)
        XCTAssertEqual(RadioChannel.of(v8), .aprs)
        XCTAssertTrue(RadioChannel.beaconMatchesChannel(base))
        XCTAssertTrue(RadioChannel.beaconMatchesChannel(v8))

        XCTAssertEqual(base.beacon.text, "K0EPI node")
        XCTAssertEqual(base.beacon.intervalMinutes, 20)
        XCTAssertEqual(base.digi.aliases, ["DWARC"])
        XCTAssertFalse(base.pings)
        XCTAssertEqual(base.txDelayMs, 400)
        XCTAssertFalse(base.sendsKISSTiming, "a network TNC keeps its own timing after the upgrade")

        XCTAssertEqual(v8.effectiveAPRSPath, "WIDE1-1,WIDE2-1")
        XCTAssertFalse(v8.beacon.aprs?.useGPS ?? true, "a fixed position stays fixed")
        XCTAssertEqual(v8.beacon.aprs?.latitude, 39.6)
        XCTAssertEqual(v8.txDelayMs, 500)

        XCTAssertEqual(settings.onAirCallsigns, ["K0EPI-7", "K0EPI-9"])
        XCTAssertTrue(settings.pingEnabled)
        XCTAssertTrue(settings.netRomAdvertiseSelf)
    }

    /// Written back, every value the old build stored is unchanged. The only
    /// differences are the key nothing read and the new option's default.
    func testTheRadiosWriteBackTheSameValues() throws {
        let (settings, old, defaults) = try upgradedStore()
        let id = try XCTUnwrap(settings.activeRadios.first?.id)
        // Any edit persists the whole list.
        settings.updateRadio(id) { $0.name = "Base" ; $0.pings = false }
        settings.updateRadio(id) { $0.pings = true }
        settings.updateRadio(id) { $0.pings = false }

        let json = try XCTUnwrap(defaults.string(forKey: AppSettingsStore.radiosKey))
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(written.count, old.count)
        for (before, after) in zip(old, written) {
            var expected = before
            expected.removeValue(forKey: "sendsBeacons")
            expected["sendsKISSTiming"] = false
            XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: expected))
        }
    }

    /// An APRS-position beacon on a radio whose APRS switch had been turned
    /// off stays exactly as it was. The page says so; nothing is migrated.
    func testAMismatchedBeaconIsLeftAlone() throws {
        let defaults = TestDefaults.make("SettingsUpgradeMismatch")
        var radio = RadioProfile(id: .primary, name: "Base")
        radio.beacon = BeaconConfig(enabled: true, kind: .aprsPosition,
                                    aprs: APRSPositionConfig(useGPS: true))
        radio.aprsEnabled = false
        let json = String(data: try JSONEncoder().encode([radio]), encoding: .utf8)
        defaults.set(json, forKey: AppSettingsStore.radiosKey)
        defaults.set(true, forKey: AppSettingsStore.beaconPerRadioMigratedKey)
        defaults.set(true, forKey: AppSettingsStore.aprsSeededFromBeaconKey)

        let settings = AppSettingsStore(defaults: defaults)
        let loaded = try XCTUnwrap(settings.radio(.primary))
        XCTAssertEqual(loaded.beacon.kind, .aprsPosition)
        XCTAssertFalse(loaded.aprsEnabled)
        XCTAssertFalse(RadioChannel.beaconMatchesChannel(loaded))
    }
}
