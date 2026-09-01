import XCTest
@testable import AXTerm

/// Station totals from the log rather than the in-memory window.
///
/// The profile counted from `PacketEngine.packets`, capped at 5,000 frames so
/// the UI stays quick. On this operator's channel that cap is a few hours:
/// KF0HEG showed "Heard 42 frames" while the database held 136 going back to
/// 22 August. Neither number was wrong; the one on screen was described as
/// something it was not.
final class StationStatsTests: XCTestCase {

    /// Direct and digipeated always account for the whole count, so a caller
    /// reading one of them is never quietly missing frames.
    func testTheTwoKindsOfFrameAccountForAllOfThem() {
        let stats = StationStats(frameCount: 136, directCount: 100,
                                 firstHeard: nil, lastHeard: nil, hourlyCounts: [])
        XCTAssertEqual(stats.digipeatedCount, 36)
        XCTAssertEqual(stats.directCount + stats.digipeatedCount, stats.frameCount)
    }

    /// More direct frames than total would be a query fault, and a negative
    /// digipeated count on screen is a worse symptom than a wrong one.
    func testAnImpossibleSplitCannotProduceANegativeCount() {
        let stats = StationStats(frameCount: 10, directCount: 12,
                                 firstHeard: nil, lastHeard: nil, hourlyCounts: [])
        XCTAssertEqual(stats.digipeatedCount, 0)
    }

    /// The reported case: what the log holds against what the window held.
    func testTheLogKnowingMoreThanTheWindowIsDetectable() {
        let stats = StationStats(frameCount: 136, directCount: 136,
                                 firstHeard: nil, lastHeard: nil, hourlyCounts: [])
        XCTAssertTrue(stats.exceeds(42))
        XCTAssertFalse(stats.exceeds(136))
        XCTAssertFalse(stats.exceeds(200))
    }
}

/// Correcting the sidebar's counts without changing what it lists.
final class StationLifetimeCountTests: XCTestCase {

    /// The list is who is on the air now. Folding in lifetime totals corrects
    /// the number beside a station; it does not add rows for every callsign
    /// ever heard, which would make it a historical roster instead.
    func testOnlyStationsAlreadyListedAreCorrected() {
        var tracker = StationTracker()
        tracker.update(with: packet(from: "KF0HEG"))

        tracker.applyLifetimeCounts(["KF0HEG": 136, "W0TX": 500])

        XCTAssertEqual(tracker.stations.count, 1)
        XCTAssertEqual(tracker.stations.first?.lifetimeCount, 136)
    }

    /// A rebuild from the capped packet list must not wipe the lifetime
    /// figure, which is why the two counts are separate fields.
    func testTheSessionCountAndTheLifetimeCountAreDifferentQuestions() {
        var station = Station(call: "KF0HEG", lastHeard: Date(), heardCount: 42)
        XCTAssertEqual(station.displayedCount, 42, "no log figure yet")

        station.lifetimeCount = 136
        XCTAssertEqual(station.heardCount, 42, "the session count is untouched")
        XCTAssertEqual(station.displayedCount, 136)
        XCTAssertTrue(station.subtitle.contains("136 pkts"))
    }

    /// A station heard more this session than the roll-up saw, because the
    /// roll-up was taken at launch and traffic has arrived since.
    func testTheLiveCountWinsWhenItHasOvertakenTheRollUp() {
        var station = Station(call: "K0NTS-10", lastHeard: Date(), heardCount: 1_500)
        station.lifetimeCount = 1_392
        XCTAssertEqual(station.displayedCount, 1_500)
    }

    private func packet(from call: String) -> Packet {
        Packet(timestamp: Date(),
               from: AX25Address(call: call, ssid: 0),
               to: AX25Address(call: "BEACON", ssid: 0),
               via: [], frameType: .ui, control: 0x03, infoText: "x")
    }
}
