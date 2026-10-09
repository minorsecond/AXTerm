import XCTest
@testable import AXTerm

/// Our own station is drawn once, and nobody else is folded into it.
///
/// The operator beaconed as K0EPI before setting the SSID to -5. A digipeater
/// repeated one of those beacons, the repeat became a heard station called
/// K0EPI, and the map drew it on top of the K0EPI-5 marker. That copy is
/// recognized by its content (`OwnEchoOnTheMapTests`), never by where it sits:
/// on 2026-10-09 the operator's phone beaconed as K0EPI-3 from the house, 4.7 m
/// from A (705), and a 50 m rule hid it from the map, the station list and the
/// heard count. `OwnSSIDsOnTheMapTests` covers sibling SSIDs elsewhere.
final class OwnStationOnTheMapTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func placed(_ call: String, latitude: Double, longitude: Double,
                        isNode: Bool = false, nodeCallsign: String? = nil) -> HeardStationMap.Entry {
        var entry = HeardStationMap.Entry(callsign: call, heardCount: 1, lastHeard: now,
                                          lastVia: [])
        entry.position = GreatCircle.Point(latitude: latitude, longitude: longitude)
        entry.isNodeAlias = isNode
        entry.nodeCallsign = nodeCallsign
        return entry
    }

    private func kept(_ entries: [HeardStationMap.Entry], own: Set<String>) -> [String] {
        HeardStationMap.withoutOwnStation(entries, ownAddresses: own).map(\.callsign)
    }

    /// The case from 2026-10-09: the phone's beacon as K0EPI-3, decoded at
    /// 39.61237,-104.73323, a few meters from A (705) at home. Another radio,
    /// so it is drawn and listed.
    func testASiblingSSIDOnTopOfUsStays() {
        let phone = placed("K0EPI-3", latitude: 39.61237, longitude: -104.73323)
        XCTAssertEqual(kept([phone], own: ["K0EPI-2", "K0EPI-4", "K0EPI-5"]), ["K0EPI-3"])
    }

    /// Our old SSID on top of us stays too, unless its frames are ours coming
    /// back, which the caller puts in `ownAddresses` (see `ownEchoAddresses`).
    func testOurOldSSIDOnTopOfUsStaysUnlessItIsOurEcho() {
        let heard = placed("K0EPI", latitude: 39.6125, longitude: -104.7331)
        XCTAssertEqual(kept([heard], own: ["K0EPI-5"]), ["K0EPI"])
        XCTAssertEqual(kept([heard], own: ["K0EPI-5", "K0EPI"]), [])
    }

    /// Even without a position to compare, an address we transmitted as is us.
    func testAnAddressWeTransmittedAsIsDroppedWherever() {
        let echo = placed("K0EPI", latitude: 40.0, longitude: -105.5)
        XCTAssertEqual(kept([echo], own: ["K0EPI-5", "K0EPI"]), [])
    }

    /// The HT in the operator's pocket, and a mobile across town, are other
    /// radios and stay on the map.
    func testADistantSiblingSSIDStays() {
        let mobile = placed("K0EPI-9", latitude: 39.70, longitude: -104.90)
        let pocket = placed("K0EPI-4", latitude: 39.6130, longitude: -104.7340)
        XCTAssertEqual(kept([mobile, pocket], own: ["K0EPI-5"]),
                       ["K0EPI-9", "K0EPI-4"],
                       "K0EPI-4 is about 90 m away: close, and still a separate station")
    }

    func testSomebodyElseAtOurAddressIsNotUs() {
        let neighbour = placed("KE0HXD-7", latitude: 39.6125, longitude: -104.7331)
        XCTAssertEqual(kept([neighbour], own: ["K0EPI-5"]), ["KE0HXD-7"])
    }

    func testOurOwnNodeAliasIsDropped() {
        let ours = placed("EPINOD", latitude: 39.6125, longitude: -104.7331,
                          isNode: true, nodeCallsign: "K0EPI-7")
        let theirs = placed("DRLNOD", latitude: 39.7, longitude: -105.0,
                            isNode: true, nodeCallsign: "KE0NCQ-7")
        XCTAssertEqual(kept([ours, theirs], own: ["K0EPI-5"]), ["DRLNOD"])
    }

    func testNoOwnAddressesChangesNothing() {
        let entry = placed("K0EPI", latitude: 39.6125, longitude: -104.7331)
        XCTAssertEqual(kept([entry], own: []), ["K0EPI"])
    }

    /// The directory layer excludes every license we operate under, not only
    /// the beacon callsign.
    func testDirectoryLayerExcludesEveryOwnLicence() {
        var directory = NodeAliasDirectory()
        directory.record(.init(alias: "CLBNOD", callsign: "W0CLB-7", service: "N"), at: now)
        let records = ["W0CLB": CallsignRecord(
            callsign: "W0CLB", name: "Club", gridSquare: "DM79", latitude: 39.6,
            longitude: -104.7, locality: "Parker", source: "HamDB", fetchedAt: now)]
        let withClub = HeardStationMap.directoryNodeEntries(
            aliases: directory, alreadyShown: [], directory: records, announcedGrids: [:],
            stations: [], excluding: "K0EPI-5", excludingAll: ["K0EPI-5", "W0CLB-1"])
        let without = HeardStationMap.directoryNodeEntries(
            aliases: directory, alreadyShown: [], directory: records, announcedGrids: [:],
            stations: [], excluding: "K0EPI-5")
        XCTAssertFalse(without.isEmpty, "fixture: the club node is placeable")
        XCTAssertTrue(withClub.isEmpty)
    }
}
