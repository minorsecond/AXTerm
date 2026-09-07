import XCTest
@testable import AXTerm

/// A radio as a value: what the station had before it had several, read off
/// the old scalar settings, and what two radios cannot both be.
final class RadioProfileTests: XCTestCase {

    private func migrated(transport: String = "network", host: String = "192.168.3.218",
                          serialPath: String = "", bleName: String = "") -> RadioProfile {
        RadioProfile.migrated(
            id: RadioID(rawValue: "primary"),
            transportType: transport, host: host, port: 8001,
            serialDevicePath: serialPath, serialBaudRate: 9600, serialAutoReconnect: true,
            blePeripheralUUID: "", blePeripheralName: bleName, bleAutoReconnect: true,
            mobilinkdEnabled: false, mobilinkdModemType: 1,
            mobilinkdOutputGain: 11, mobilinkdInputGain: 0,
            capabilities: TNCCapabilities())
    }

    // MARK: - The migrated radio

    /// Named for what it is, so the moment a second radio appears the first
    /// already reads as something rather than "Radio 1".
    func testTheMigratedRadioIsNamedForItsTransport() {
        XCTAssertEqual(migrated(transport: "network").name, "Direwolf")
        XCTAssertEqual(migrated(transport: "serial", serialPath: "/dev/cu.usbmodem1420").name, "usbmodem1420")
        XCTAssertEqual(migrated(transport: "serial").name, "Serial TNC")
        XCTAssertEqual(migrated(transport: "ble", bleName: "TNC4 Mobilinkd").name, "TNC4 Mobilinkd")
        XCTAssertEqual(migrated(transport: "ble").name, "Bluetooth TNC")
    }

    /// The transport strings are the ones the scalar setting always stored.
    func testTransportKindsSpellTheLegacySetting() {
        XCTAssertEqual(RadioTransportKind.tcp.rawValue, "network")
        XCTAssertEqual(migrated(transport: "serial").kind, .serial)
        XCTAssertEqual(migrated(transport: "ble").kind, .ble)
        XCTAssertEqual(migrated(transport: "garbage").kind, .tcp, "an unknown transport falls back to TCP, as the engine does")
    }

    func testAnEmptyCallsignMeansTheStationCallsign() {
        var radio = migrated()
        XCTAssertEqual(radio.resolvedCallsign(station: "k0epi-7"), "K0EPI-7")
        radio.callsign = " k0epi-1 "
        XCTAssertEqual(radio.resolvedCallsign(station: "K0EPI-7"), "K0EPI-1")
    }

    /// Two radios on one Direwolf share a link and differ by port.
    func testTheLinkKeyNamesTheByteStreamNotTheRadio() {
        var a = migrated(); a.kissPort = 0
        var b = migrated(); b.id = RadioID(rawValue: "b"); b.kissPort = 1
        XCTAssertEqual(a.linkKey, b.linkKey)
        XCTAssertEqual(a.linkKey, "tcp://192.168.3.218:8001")
        XCTAssertEqual(migrated(transport: "serial", serialPath: "/dev/cu.x").linkKey, "serial:///dev/cu.x")
    }

    // MARK: - Storage

    func testAProfileSurvivesJSON() throws {
        var radio = migrated()
        radio.kissPort = 3
        radio.callsign = "K0EPI-1"
        radio.frequencyHz = 144_390_000
        let data = try JSONEncoder().encode([radio])
        let back = try JSONDecoder().decode([RadioProfile].self, from: data)
        XCTAssertEqual(back, [radio])
    }

    /// A profile written before a field existed still decodes: every field
    /// but the id has a default.
    func testAnOlderProfileDecodesWithDefaults() throws {
        let minimal = Data(#"[{"id":"abc","name":"Base"}]"#.utf8)
        let radios = try JSONDecoder().decode([RadioProfile].self, from: minimal)
        XCTAssertEqual(radios.count, 1)
        XCTAssertEqual(radios[0].id, RadioID(rawValue: "abc"))
        XCTAssertEqual(radios[0].name, "Base")
        XCTAssertEqual(radios[0].kind, .tcp)
        XCTAssertEqual(radios[0].kissPort, 0)
        XCTAssertTrue(radios[0].enabled)
        XCTAssertFalse(radios[0].archived)
        // Every station-wide service runs on a radio unless switched off.
        XCTAssertTrue(radios[0].sendsBeacons)
        XCTAssertTrue(radios[0].pings)
        XCTAssertTrue(radios[0].announcesNode)
        XCTAssertTrue(radios[0].answersMailbox)
        XCTAssertEqual(radios[0].netRomAlias, "")
    }

    // MARK: - Two radios that cannot both be

    func testTwoRadiosOnOneLinkAndPortAreFlagged() {
        let a = migrated()
        var b = migrated(); b.id = RadioID(rawValue: "b")
        let issues = RadioProfileIssue.issues(in: [a, b], stationCallsign: "K0EPI")
        XCTAssertTrue(issues.contains(.duplicateLink(a.id, b.id)))
        // Same address too, since neither names its own.
        XCTAssertTrue(issues.contains(.duplicateCallsign(a.id, b.id, "K0EPI")))
    }

    func testDifferentPortsOnOneLinkAreFine() {
        let a = migrated()
        var b = migrated(); b.id = RadioID(rawValue: "b"); b.kissPort = 1; b.callsign = "K0EPI-1"
        XCTAssertTrue(RadioProfileIssue.issues(in: [a, b], stationCallsign: "K0EPI").isEmpty)
    }

    /// A radio switched off, or removed, is not competing for anything.
    func testDisabledAndArchivedRadiosAreNotCompared() {
        let a = migrated()
        var off = migrated(); off.id = RadioID(rawValue: "off"); off.enabled = false
        var gone = migrated(); gone.id = RadioID(rawValue: "gone"); gone.archived = true
        XCTAssertTrue(RadioProfileIssue.issues(in: [a, off, gone], stationCallsign: "K0EPI").isEmpty)
    }
}
