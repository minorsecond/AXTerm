import XCTest
@testable import AXTerm

/// Callsigns and frequencies here are from this operator's own cached
/// station list.
final class WinlinkStationPreferencesTests: XCTestCase {

    private func station(_ callsign: String, _ frequencyHz: Int,
                         grid: String = "DM79QL") -> WinlinkRMSStationRecord {
        WinlinkRMSStationRecord(
            callsign: callsign, gridSquare: grid, frequencyHz: frequencyHz,
            modeName: "Packet", baud: "1200", serviceCode: "PUBLIC",
            distanceMiles: 10, headingDegrees: 156, lastSeenAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private var stations: [WinlinkRMSStationRecord] {
        [
            station("W0ARP-10", 145_030_000),
            station("W0ARP-10", 145_050_000),
            station("W0ARP-10", 441_075_000),
            station("N0HI-10", 145_050_000),
            station("K0ARK-10", 145_090_000, grid: "DN70KA"),
        ]
    }

    // MARK: - Path storage

    /// The same gateway on two bands is two paths — storing per callsign
    /// would leak a VHF digi route onto a UHF link.
    func testPathsAreStoredPerLinkNotPerCallsign() {
        var preferences = WinlinkStationPreferences()
        preferences.setPath("DRLNOD", for: station("W0ARP-10", 145_050_000))
        XCTAssertEqual(preferences.path(for: station("W0ARP-10", 145_050_000)), "DRLNOD")
        XCTAssertEqual(preferences.path(for: station("W0ARP-10", 441_075_000)), "",
                       "the UHF link must not inherit the VHF path")
    }

    func testPathsAcceptCommasSpacesOrBoth() {
        XCTAssertEqual(WinlinkStationPreferences.normalizePath("drlnod"), "DRLNOD")
        XCTAssertEqual(WinlinkStationPreferences.normalizePath("drlnod,wide1-1"), "DRLNOD,WIDE1-1")
        XCTAssertEqual(WinlinkStationPreferences.normalizePath("drlnod wide1-1"), "DRLNOD,WIDE1-1")
        XCTAssertEqual(WinlinkStationPreferences.normalizePath(" drlnod , wide1-1 "),
                       "DRLNOD,WIDE1-1")
    }

    /// AX.25 allows eight digipeaters. Dropping the excess here beats
    /// failing at transmit time.
    func testPathIsCappedAtTheAX25Limit() {
        let long = (1...12).map { "DIGI\($0)" }.joined(separator: ",")
        let normalized = WinlinkStationPreferences.normalizePath(long)
        XCTAssertEqual(normalized.split(separator: ",").count, 8)
    }

    /// "Direct" has one representation, not two.
    func testClearingAPathRemovesItRatherThanStoringEmpty() {
        var preferences = WinlinkStationPreferences()
        let link = station("W0ARP-10", 145_050_000)
        preferences.setPath("DRLNOD", for: link)
        preferences.setPath("   ", for: link)
        XCTAssertTrue(preferences.paths.isEmpty)
        XCTAssertEqual(preferences.path(for: link), "")
    }

    // MARK: - Hiding

    /// Hiding is a view preference. The record stays cached and its link
    /// quality keeps accumulating.
    func testHidingRemovesFromTheTableOnly() {
        var preferences = WinlinkStationPreferences()
        preferences.setHidden(true, for: station("K0ARK-10", 145_090_000))
        let visible = preferences.visible(stations)
        XCTAssertEqual(visible.count, 4)
        XCTAssertFalse(visible.contains { $0.callsign == "K0ARK-10" })
    }

    /// The operator has to be able to find what they hid.
    func testShowingHiddenRestoresThemToTheTable() {
        var preferences = WinlinkStationPreferences()
        preferences.setHidden(true, for: station("K0ARK-10", 145_090_000))
        XCTAssertEqual(preferences.visible(stations, showingHidden: true).count, 5)
    }

    func testUnhidingIsExact() {
        var preferences = WinlinkStationPreferences()
        let link = station("W0ARP-10", 145_030_000)
        preferences.setHidden(true, for: link)
        preferences.setHidden(false, for: link)
        XCTAssertEqual(preferences.visible(stations).count, 5)
    }

    // MARK: - Frequency filter

    /// Empty means no filter, not "hide everything" — the only reading
    /// that degrades safely if the set is ever lost.
    func testAnEmptyFrequencySetShowsEverything() {
        let preferences = WinlinkStationPreferences()
        XCTAssertEqual(preferences.visible(stations).count, stations.count)
    }

    /// The operator's actual case: the radio lives on 145.050, so
    /// nothing else is worth looking at.
    func testFilteringToOneFrequency() {
        var preferences = WinlinkStationPreferences()
        preferences.visibleFrequencies = [145_050_000]
        let visible = preferences.visible(stations)
        XCTAssertEqual(visible.count, 2)
        XCTAssertTrue(visible.allSatisfy { $0.frequencyHz == 145_050_000 })
    }

    /// Turning one off while showing all means "all except that one",
    /// which is what the click expressed.
    func testTurningOneOffFromAllKeepsTheRest() {
        var preferences = WinlinkStationPreferences()
        let available = WinlinkStationPreferences.frequencies(in: stations)
        preferences.toggleFrequency(441_075_000, in: available)
        XCTAssertFalse(preferences.showsFrequency(441_075_000))
        XCTAssertTrue(preferences.showsFrequency(145_050_000))
    }

    /// Selecting everything is the same as no filter — and storing it
    /// that way means a frequency that appears later is shown rather
    /// than silently excluded.
    func testSelectingEveryFrequencyCollapsesToNoFilter() {
        var preferences = WinlinkStationPreferences()
        let available = WinlinkStationPreferences.frequencies(in: stations)
        preferences.toggleFrequency(441_075_000, in: available)
        preferences.toggleFrequency(441_075_000, in: available)
        XCTAssertTrue(preferences.visibleFrequencies.isEmpty)

        let laterStations = stations + [station("NEW-10", 144_930_000)]
        XCTAssertEqual(preferences.visible(laterStations).count, laterStations.count)
    }

    func testAvailableFrequenciesAreDistinctAndAscending() {
        XCTAssertEqual(WinlinkStationPreferences.frequencies(in: stations),
                       [145_030_000, 145_050_000, 145_090_000, 441_075_000])
    }

    // MARK: - Honesty about filtering

    /// Silent truncation reads as "that is everything" when it is not.
    func testHiddenCountReportsWhatIsBeingWithheld() {
        var preferences = WinlinkStationPreferences()
        preferences.visibleFrequencies = [145_050_000]
        XCTAssertEqual(preferences.hiddenCount(in: stations), 3)

        preferences.setHidden(true, for: station("N0HI-10", 145_050_000))
        XCTAssertEqual(preferences.hiddenCount(in: stations), 4)
    }

    // MARK: - Persistence

    func testRoundTripsThroughCoding() throws {
        var preferences = WinlinkStationPreferences()
        preferences.setPath("DRLNOD,WIDE1-1", for: station("W0ARP-10", 145_050_000))
        preferences.setHidden(true, for: station("K0ARK-10", 145_090_000))
        preferences.visibleFrequencies = [145_050_000]

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(WinlinkStationPreferences.self, from: data)
        XCTAssertEqual(decoded, preferences)
    }
}
