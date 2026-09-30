import XCTest
@testable import AXTerm

/// The Map's station list shows what the map draws.
///
/// "Drop after" and the APRS layer switches filtered the markers and left the
/// sidebar alone, so "On the map" listed stations that had gone quiet a day
/// ago, and license-address dots that Transmitted Positions had taken off the
/// map. The list and the markers now go through one filter.
final class MapEntryVisibilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ call: String, heardMinutesAgo: Double?, placed: Bool = true,
                       origin: HeardStationMap.PositionOrigin? = nil,
                       symbol: Character? = nil, isNode: Bool = false) -> HeardStationMap.Entry {
        var entry = HeardStationMap.Entry(
            callsign: call, heardCount: 5,
            lastHeard: heardMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
            lastVia: [])
        if placed {
            entry.position = GreatCircle.Point(latitude: 39.6, longitude: -104.8)
            entry.origin = origin ?? .transmittedAPRS
        }
        if let symbol { entry.aprsSymbol = APRSMapSymbol(table: "/", code: symbol) }
        entry.isNodeAlias = isNode
        return entry
    }

    private func calls(_ entries: [HeardStationMap.Entry]) -> [String] {
        entries.map(\.callsign)
    }

    // MARK: - Drop after

    func testDropAfterThinsBothSectionsOfTheList() {
        let visibility = MapEntryVisibility(falloffMinutes: 60, now: now)
        let sections = visibility.listSections([
            entry("FRESH-1", heardMinutesAgo: 10),
            entry("STALE-1", heardMinutesAgo: 600),
            entry("FRESH-2", heardMinutesAgo: 30, placed: false),
            entry("STALE-2", heardMinutesAgo: 600, placed: false),
        ])
        XCTAssertEqual(calls(sections.onMap), ["FRESH-1"])
        XCTAssertEqual(calls(sections.noPosition), ["FRESH-2"])
    }

    func testNeverKeepsEverything() {
        let visibility = MapEntryVisibility(falloffMinutes: 0, now: now)
        let sections = visibility.listSections([
            entry("OLD-1", heardMinutesAgo: 100_000),
            entry("OLD-2", heardMinutesAgo: 100_000, placed: false),
        ])
        XCTAssertEqual(calls(sections.onMap), ["OLD-1"])
        XCTAssertEqual(calls(sections.noPosition), ["OLD-2"])
    }

    /// A directory lead has no heard time. Its own layer decides whether it
    /// is shown, so "Drop after" leaves it alone in the list as on the map.
    func testADirectoryLeadWithNoHeardTimeIsNotDropped() {
        let visibility = MapEntryVisibility(falloffMinutes: 15, now: now)
        let lead = entry("ZIABBS", heardMinutesAgo: nil, origin: .licenceOrGrid, isNode: true)
        XCTAssertTrue(visibility.withinFalloff(lead))
        XCTAssertEqual(calls(visibility.listSections([lead]).onMap), ["ZIABBS"])
    }

    func testTheBoundaryIsInclusive() {
        let visibility = MapEntryVisibility(falloffMinutes: 60, now: now)
        XCTAssertTrue(visibility.withinFalloff(entry("EDGE", heardMinutesAgo: 60)))
        XCTAssertFalse(visibility.withinFalloff(entry("PAST", heardMinutesAgo: 60.1)))
    }

    // MARK: - The list matches the markers

    /// Whatever the switches say, "On the map" is exactly the placed entries
    /// the scope is built from.
    func testOnTheMapIsExactlyWhatIsDrawn() {
        let entries = [
            entry("BEACON-1", heardMinutesAgo: 5, symbol: ">"),
            entry("WX-1", heardMinutesAgo: 5, symbol: "_"),
            entry("DIGI-1", heardMinutesAgo: 5, symbol: "#"),
            entry("HOUSE-1", heardMinutesAgo: 5, symbol: "-"),
            entry("ADDRESS-1", heardMinutesAgo: 5, origin: .licenceOrGrid),
            entry("PACKET-1", heardMinutesAgo: 5, origin: .licenceOrGrid),
            entry("NODE", heardMinutesAgo: 5, origin: .licenceOrGrid, isNode: true),
            entry("QUIET-1", heardMinutesAgo: 5_000, symbol: ">"),
            entry("NOWHERE", heardMinutesAgo: 5, placed: false),
        ]
        let onAPRS: Set<String> = ["BEACON-1", "WX-1", "DIGI-1", "HOUSE-1",
                                   "ADDRESS-1", "QUIET-1", "NOWHERE"]
        for transmitted in [false, true] {
            for weather in [false, true] {
                let visibility = MapEntryVisibility(
                    falloffMinutes: 60, prefersTransmittedPosition: transmitted,
                    showsWeather: weather, callsOnAPRSChannels: onAPRS, now: now)
                let drawn = visibility.entriesForMap(entries).filter(\.isPlaced)
                XCTAssertEqual(calls(visibility.listSections(entries).onMap), calls(drawn),
                               "transmitted=\(transmitted) weather=\(weather)")
            }
        }
    }

    /// Transmitted Positions takes a license-address dot off the map when the
    /// station was heard on APRS; the list follows.
    func testTransmittedPositionsDropsAddressDotsOnAPRSChannels() {
        let visibility = MapEntryVisibility(
            prefersTransmittedPosition: true,
            callsOnAPRSChannels: ["ADDRESS-1", "BEACON-1"], now: now)
        let sections = visibility.listSections([
            entry("BEACON-1", heardMinutesAgo: 5, symbol: ">"),
            entry("ADDRESS-1", heardMinutesAgo: 5, origin: .licenceOrGrid),
            entry("PACKET-1", heardMinutesAgo: 5, origin: .licenceOrGrid),
            entry("NODE", heardMinutesAgo: 5, origin: .licenceOrGrid, isNode: true),
        ])
        XCTAssertEqual(calls(sections.onMap), ["BEACON-1", "PACKET-1", "NODE"],
                       "a packet-channel station has no beaconed fix to prefer")
    }

    func testStationTypeSwitchesApplyOnlyUnderTransmittedPositions() {
        let weather = entry("WX-1", heardMinutesAgo: 5, symbol: "_")
        let off = MapEntryVisibility(prefersTransmittedPosition: false, showsWeather: false,
                                     now: now)
        let on = MapEntryVisibility(prefersTransmittedPosition: true, showsWeather: false,
                                    callsOnAPRSChannels: ["WX-1"], now: now)
        XCTAssertTrue(off.drawsMarker(weather),
                      "the type switches only show while Transmitted Positions is on")
        XCTAssertFalse(on.drawsMarker(weather))
        XCTAssertTrue(on.listSections([weather]).onMap.isEmpty)
    }

    /// Unplaced entries still reach the scope, where the analysis layers use
    /// them, even when "Drop after" has taken them out of the list.
    func testUnplacedEntriesPassThroughToTheScope() {
        let visibility = MapEntryVisibility(falloffMinutes: 15, now: now)
        let stale = entry("STALE", heardMinutesAgo: 600, placed: false)
        XCTAssertEqual(calls(visibility.entriesForMap([stale])), ["STALE"])
        XCTAssertTrue(visibility.listSections([stale]).noPosition.isEmpty)
    }

    // MARK: - Who counts as on an APRS channel

    func testARadioWithNothingClassifiedCountsAsAPRS() {
        let radio = RadioID(rawValue: "new")
        var station = Station(call: "N0CALL", lastHeard: now, heardCount: 1)
        station.perRadio[radio] = Station.RadioObservation(
            lastHeard: now, heardCount: 1, lastVia: [], aprsFrames: 0, sessionFrames: 0)
        XCTAssertEqual(MapEntryVisibility.callsOnAPRSChannels(stations: [station], families: [:]),
                       ["N0CALL"])
    }
}
