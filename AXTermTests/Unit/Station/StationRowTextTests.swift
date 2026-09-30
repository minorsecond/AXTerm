import XCTest
@testable import AXTerm

/// What a row in the Map's station list says about distance and traffic.
///
/// The row used to end in a bare number that turned out to be the packet
/// count, and the only distance was in the tooltip, which measured from 0,0
/// whenever our own position was unknown.
final class StationRowTextTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let home = GreatCircle.Point(latitude: 39.6124, longitude: -104.7333)
    /// K0PWO's beaconed fix: the house on the edge of the receive ring.
    private let k0pwo = GreatCircle.Point(latitude: 39.3000, longitude: -104.6000)

    // MARK: - Distance and bearing

    func testFarStationsRoundToWholeUnits() {
        XCTAssertEqual(HeardStationMap.rangeText(from: home, to: k0pwo, inMiles: true),
                       "23 mi SSE")
        XCTAssertEqual(HeardStationMap.rangeText(from: home, to: k0pwo, inMiles: false),
                       "37 km SSE")
    }

    func testNearStationsKeepATenth() {
        let ad1ct = GreatCircle.Point(latitude: 39.6227, longitude: -104.7722)
        XCTAssertEqual(HeardStationMap.rangeText(from: home, to: ad1ct, inMiles: true),
                       "2.2 mi WNW")
    }

    func testNoDistanceWithoutBothEnds() {
        XCTAssertNil(HeardStationMap.rangeText(from: nil, to: k0pwo, inMiles: true))
        XCTAssertNil(HeardStationMap.rangeText(from: home, to: nil, inMiles: true))
    }

    // MARK: - Packet count

    func testTheCountSaysWhatItCounts() {
        XCTAssertEqual(HeardStationMap.packetCountText(61), "61 pkts")
        XCTAssertEqual(HeardStationMap.packetCountText(1), "1 pkt")
    }

    func testTheCountTooltipExplainsWhereTheNumberComesFrom() {
        let help = HeardStationMap.packetCountHelp(61)
        XCTAssertTrue(help.hasPrefix("61 packets heard"))
        XCTAssertTrue(help.contains("digipeater"))
        XCTAssertTrue(help.contains("counts once"))
    }

    // MARK: - The tooltip without our position

    private var entry: HeardStationMap.Entry {
        var entry = HeardStationMap.Entry(callsign: "K0PWO", heardCount: 61,
                                          lastHeard: now, lastVia: [])
        entry.position = k0pwo
        entry.positionSource = "APRS position"
        entry.confidence = .exact
        entry.origin = .transmittedAPRS
        return entry
    }

    func testTheTooltipMeasuresFromUsWhenWeKnowWhereWeAre() {
        let text = HeardStationMap.detail(for: entry, observer: home, now: now)
        XCTAssertTrue(text.contains("23 mi at 162° (SSE)"), text)
    }

    /// With no position of our own the old tooltip measured from the Gulf of
    /// Guinea: several thousand miles, bearing roughly north-west.
    func testTheTooltipOmitsDistanceWithoutOurPosition() {
        let text = HeardStationMap.detail(for: entry, observer: nil, now: now)
        XCTAssertFalse(text.contains(" mi at "), text)
        XCTAssertTrue(text.contains("61 packets heard"), text)
        XCTAssertTrue(text.contains("Beaconed position"), text)
    }
}
