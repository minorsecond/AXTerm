import XCTest
@testable import AXTerm

/// How another station's observations read on screen.
///
/// The labelling is a safety property, not cosmetics: an operator who reads
/// these as their own will conclude their radio can reach places it cannot.
final class NetworkHistoryRowTests: XCTestCase {

    private func payload(_ callsign: String,
                         station: String,
                         grid: String? = "DM79GR",
                         frames: Int = 7,
                         heard: Date = Date(timeIntervalSince1970: 1_000)) -> StationActivityPayload {
        StationActivityPayload(
            callsign: callsign, roles: [],
            firstHeard: heard, lastHeard: heard,
            frameCount: frames, airtimeSeconds: 1,
            provenance: WinlinkSyncProvenance(
                station: station, deviceID: "d", gridSquare: grid, observedAt: heard))
    }

    /// Every row names the ears that heard it. This is the invariant the
    /// screen exists to hold.
    func testEveryRowNamesTheObservingStation() {
        let text = NetworkHistoryRow.attribution(payload("N0CVL-10", station: "K0EPI-7"))
        XCTAssertTrue(text.contains("K0EPI-7"))
        XCTAssertTrue(text.lowercased().contains("heard by"))
    }

    /// Where it was heard from matters as much as who heard it — a station
    /// worked from a summit is not the same evidence as one worked from a
    /// basement.
    func testAttributionIncludesTheObserversLocation() {
        XCTAssertTrue(NetworkHistoryRow.attribution(
            payload("N0CVL-10", station: "K0EPI-7", grid: "DM79GR")).contains("DM79GR"))
    }

    /// A station with no known position still gets attributed, just without
    /// a dangling separator.
    func testAttributionSurvivesAMissingGrid() {
        let text = NetworkHistoryRow.attribution(payload("N0CVL-10", station: "K0EPI-7", grid: nil))
        XCTAssertEqual(text, "Heard by K0EPI-7")
        XCTAssertFalse(text.hasSuffix("·"))
    }

    /// Grouped by observer: "what can the home rig hear" and "what can this
    /// handheld hear" are different questions, and one merged list answers
    /// neither.
    func testObservationsGroupByTheStationThatHeardThem() {
        let groups = NetworkHistoryRow.grouped([
            payload("N0CVL-10", station: "K0EPI-7"),
            payload("W0ARP-10", station: "K0EPI-9"),
            payload("KB5YZB-7", station: "K0EPI-7"),
        ])
        XCTAssertEqual(groups.map(\.station), ["K0EPI-7", "K0EPI-9"])
        XCTAssertEqual(groups[0].entries.count, 2)
    }

    /// Singular reads as singular; "1 frames" is the kind of thing that
    /// makes an operator distrust everything else on the screen.
    func testFrameCountReadsNaturallyAtOne() {
        XCTAssertTrue(NetworkHistoryRow.activity(
            payload("N0CVL-10", station: "K0EPI-7", frames: 1)).hasPrefix("1 frame ·"))
    }

    /// Coarse on purpose: CloudKit is unhurried, so a to-the-second stamp
    /// would claim a precision the transport cannot deliver.
    func testRecencyIsCoarseBecauseTheTransportIsSlow() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(NetworkHistoryRow.relative(now.addingTimeInterval(-60), now: now),
                       "within the hour")
        XCTAssertEqual(NetworkHistoryRow.relative(now.addingTimeInterval(-7200), now: now), "2h ago")
        XCTAssertEqual(NetworkHistoryRow.relative(now.addingTimeInterval(-172_800), now: now), "2d ago")
    }

    /// Clock skew between devices is normal; a future timestamp must not
    /// render as a negative age.
    func testAFutureObservationDoesNotReadAsNegative() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(NetworkHistoryRow.relative(now.addingTimeInterval(300), now: now), "just now")
    }
}
