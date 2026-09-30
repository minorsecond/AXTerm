import XCTest
@testable import AXTerm

/// Our own station is drawn once.
///
/// The operator beaconed as K0EPI before setting the SSID to -5. A digipeater
/// repeated one of those beacons, the repeat became a heard station called
/// K0EPI, and the map drew it on top of the K0EPI-5 marker. Exact-address
/// exclusion could not see it: K0EPI is not an address this station answers
/// to any more. `OwnSSIDsOnTheMapTests` covers the other half, that a sibling
/// SSID somewhere else is another radio and stays.
final class OwnStationOnTheMapTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    /// K0EPI-5's own fix, from the test database.
    private let home = GreatCircle.Point(latitude: 39.6124, longitude: -104.7333)

    private func placed(_ call: String, latitude: Double, longitude: Double,
                        isNode: Bool = false, nodeCallsign: String? = nil) -> HeardStationMap.Entry {
        var entry = HeardStationMap.Entry(callsign: call, heardCount: 1, lastHeard: now,
                                          lastVia: [])
        entry.position = GreatCircle.Point(latitude: latitude, longitude: longitude)
        entry.isNodeAlias = isNode
        entry.nodeCallsign = nodeCallsign
        return entry
    }

    private func kept(_ entries: [HeardStationMap.Entry], own: Set<String>,
                      observer: GreatCircle.Point?) -> [String] {
        HeardStationMap.withoutOwnStation(entries, ownAddresses: own, observer: observer)
            .map(\.callsign)
    }

    /// The case from 2026-09-29: K0EPI (SSID 0) decoded at 39.6125,-104.7331,
    /// about twenty metres from where K0EPI-5 now says it is.
    func testOurOldSSIDOnTopOfUsIsDropped() {
        let echo = placed("K0EPI", latitude: 39.6125, longitude: -104.7331)
        XCTAssertEqual(kept([echo], own: ["K0EPI-5"], observer: home), [])
    }

    /// Even without a position to compare, an address we transmitted as is us.
    func testAnAddressWeTransmittedAsIsDroppedWherever() {
        let echo = placed("K0EPI", latitude: 40.0, longitude: -105.5)
        XCTAssertEqual(kept([echo], own: ["K0EPI-5", "K0EPI"], observer: nil), [])
    }

    /// The HT in the operator's pocket, and a mobile across town, are other
    /// radios and stay on the map.
    func testADistantSiblingSSIDStays() {
        let mobile = placed("K0EPI-9", latitude: 39.70, longitude: -104.90)
        let pocket = placed("K0EPI-4", latitude: 39.6130, longitude: -104.7340)
        XCTAssertEqual(kept([mobile, pocket], own: ["K0EPI-5"], observer: home),
                       ["K0EPI-9", "K0EPI-4"],
                       "K0EPI-4 is about 90 m away: close, and still a separate station")
    }

    func testWithoutOurPositionOnlyExactAddressesGo() {
        let sibling = placed("K0EPI-9", latitude: 39.6125, longitude: -104.7331)
        XCTAssertEqual(kept([sibling], own: ["K0EPI-5"], observer: nil), ["K0EPI-9"],
                       "with nothing to measure from, a sibling is given the benefit of the doubt")
    }

    func testSomebodyElseAtOurAddressIsNotUs() {
        let neighbour = placed("KE0HXD-7", latitude: 39.6125, longitude: -104.7331)
        XCTAssertEqual(kept([neighbour], own: ["K0EPI-5"], observer: home), ["KE0HXD-7"])
    }

    func testOurOwnNodeAliasIsDropped() {
        let ours = placed("EPINOD", latitude: 39.6125, longitude: -104.7331,
                          isNode: true, nodeCallsign: "K0EPI-7")
        let theirs = placed("DRLNOD", latitude: 39.7, longitude: -105.0,
                            isNode: true, nodeCallsign: "KE0NCQ-7")
        XCTAssertEqual(kept([ours, theirs], own: ["K0EPI-5"], observer: home), ["DRLNOD"])
    }

    func testNoOwnAddressesChangesNothing() {
        let entry = placed("K0EPI", latitude: 39.6125, longitude: -104.7331)
        XCTAssertEqual(kept([entry], own: [], observer: home), ["K0EPI"])
    }

    /// The directory layer excludes every licence we operate under, not only
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
