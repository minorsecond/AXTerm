import XCTest
@testable import AXTerm

/// An operator's other radios are other stations.
///
/// The map excludes "the operator's own callsign" so this station does not
/// appear twice — once as the centre marker and again as a heard station a few
/// metres away, which is what happens when our own beacon comes back off a
/// digipeater. That is right. But the comparison was made on the *base*
/// callsign, and `CallsignQuery.normalize` strips the SSID, so it swallowed
/// every SSID on the licence.
///
/// K0EPI-4 is an HT in the operator's pocket running the aprs.fi app: its own
/// radio, its own position, its own symbol, ninety yards away and moving. It
/// was heard, parsed and turned into a station — and then dropped from the map
/// for sharing a licence with the desk. There was no way to see it, no way to
/// ping it, and clicking its line in the traffic strip did nothing, because
/// selecting a station the map does not have is a no-op.
final class OwnSSIDsOnTheMapTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func beaconing(_ call: String, at latitude: Double) -> Station {
        var station = Station(call: call, lastHeard: now, heardCount: 3, lastVia: [])
        station.aprs = APRSReport(latitude: latitude, longitude: -104.7332,
                                  symbolTable: "\\", symbolCode: "b",
                                  courseDegrees: nil, speedKnots: nil, altitudeFeet: nil,
                                  comment: "aprs.fi for iOS", hasTimestamp: true,
                                  kind: .uncompressed)
        return station
    }

    private func mapped(_ stations: [Station], own: Set<String>) -> [String] {
        HeardStationMap.entries(stations: stations, directory: [:], gatewayGrids: [:],
                                excluding: own).map(\.callsign)
    }

    /// The bug, from the operator's own station on 2026-09-09.
    func testAnotherSSIDOnTheSameLicenceIsItsOwnStation() {
        let drawn = mapped([beaconing("K0EPI-7", at: 39.6117),
                            beaconing("K0EPI-4", at: 39.6123)],
                           own: ["K0EPI-7"])
        XCTAssertTrue(drawn.contains("K0EPI-4"),
                      "the HT in the operator's pocket is a different radio: \(drawn)")
    }

    /// And the reason the exclusion exists still holds: our own beacon comes
    /// back digipeated and must not draw a second marker on top of us.
    func testOurOwnTransmissionsAreStillExcluded() {
        let drawn = mapped([beaconing("K0EPI-7", at: 39.6117),
                            beaconing("K0EPI-4", at: 39.6123)],
                           own: ["K0EPI-7"])
        XCTAssertFalse(drawn.contains("K0EPI-7"), drawn.description)
    }

    /// A station answering on several addresses — the node, the mailbox — is
    /// one box at one position, so every address it answers to is excluded,
    /// not just the one it beacons under.
    func testEveryAddressThisStationAnswersToIsExcluded() {
        let drawn = mapped([beaconing("K0EPI-7", at: 39.6117),
                            beaconing("K0EPI-1", at: 39.6117),
                            beaconing("K0EPI-11", at: 39.6117),
                            beaconing("K0EPI-4", at: 39.6123)],
                           own: ["K0EPI-7", "K0EPI-1", "K0EPI-11"])
        XCTAssertEqual(drawn, ["K0EPI-4"])
    }

    /// Somebody else's sibling SSIDs were never in question, and still are
    /// not: two SSIDs of one licence are two APRS stations to everyone else.
    func testOtherOperatorsSiblingSSIDsAreUnaffected() {
        let drawn = mapped([beaconing("KB5YZB-1", at: 39.7),
                            beaconing("KB5YZB-7", at: 39.7)],
                           own: ["K0EPI-7"])
        XCTAssertEqual(Set(drawn), ["KB5YZB-1", "KB5YZB-7"])
    }
}
