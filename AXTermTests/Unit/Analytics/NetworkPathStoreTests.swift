import XCTest
import GRDB
@testable import AXTerm

/// Paths that survive a restart, and the merge rules that keep them honest.
///
/// The trap here is arithmetic. The live observer re-derives its paths from a
/// rolling packet window every few seconds, so anything summed on the way in
/// grows without bound and a quiet path ends up looking busier than a loud
/// one. Every rule below exists to make recording the same window twice a
/// no-op.
final class NetworkPathStoreTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SQLiteNetworkPathStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteNetworkPathStore(dbQueue: queue)
    }

    private func path(_ from: String, _ to: String, via: [String] = [],
                      evidence: NetworkPath.Evidence = .heardDirect,
                      observations: Int = 1,
                      first: Date? = nil, last: Date? = nil,
                      unanswered: Int = 0) -> NetworkPath {
        NetworkPath(from: from, to: to, via: via, evidence: evidence,
                    observations: observations,
                    firstSeen: first ?? t0, lastSeen: last ?? t0,
                    unansweredAttempts: unanswered)
    }

    // MARK: - Round trip

    func testAPathSurvivesARestart() throws {
        let store = try makeStore()
        try store.record([path("K0EPI-7", "W0ARP-10")], now: t0)
        let back = try store.paths(since: t0.addingTimeInterval(-60))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.from, "K0EPI-7")
        XCTAssertEqual(back.first?.evidence, .heardDirect)
    }

    func testDigipeaterHopsRoundTripInOrder() throws {
        let store = try makeStore()
        try store.record([path("A", "B", via: ["DRLNOD", "HORSE"],
                               evidence: .heardDigipeated)], now: t0)
        XCTAssertEqual(try store.paths(since: t0.addingTimeInterval(-60)).first?.via,
                       ["DRLNOD", "HORSE"])
    }

    func testADirectPathStoresNoHops() throws {
        let store = try makeStore()
        try store.record([path("A", "B")], now: t0)
        XCTAssertEqual(try store.paths(since: t0.addingTimeInterval(-60)).first?.via, [])
    }

    // MARK: - Merge rules

    /// The one that matters: recording the same window repeatedly, which is
    /// exactly what the five-second throttle does, must not inflate anything.
    func testRecordingTheSameWindowTwiceChangesNothing() throws {
        let store = try makeStore()
        let observed = [path("A", "B", observations: 12)]
        try store.record(observed, now: t0)
        try store.record(observed, now: t0)
        try store.record(observed, now: t0)

        let back = try store.paths(since: t0.addingTimeInterval(-60))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.observations, 12)
    }

    /// Proof does not expire because a quiet hour passed.
    func testStrongerEvidenceIsNeverDowngraded() throws {
        let store = try makeStore()
        try store.record([path("A", "B", evidence: .sessionEstablished)], now: t0)
        try store.record([path("A", "B", evidence: .heardDirect)], now: t0)
        XCTAssertEqual(try store.paths(since: t0.addingTimeInterval(-60)).first?.evidence,
                       .sessionEstablished)
    }

    func testWeakerStoredEvidenceIsUpgraded() throws {
        let store = try makeStore()
        try store.record([path("A", "B", evidence: .transitive)], now: t0)
        try store.record([path("A", "B", evidence: .sessionEstablished)], now: t0)
        XCTAssertEqual(try store.paths(since: t0.addingTimeInterval(-60)).first?.evidence,
                       .sessionEstablished)
    }

    func testTheWindowWidensRatherThanMoving() throws {
        let store = try makeStore()
        let later = t0.addingTimeInterval(3600)
        try store.record([path("A", "B", first: t0, last: t0)], now: t0)
        try store.record([path("A", "B", first: later, last: later)], now: later)

        let back = try store.paths(since: t0.addingTimeInterval(-60)).first
        XCTAssertEqual(back?.firstSeen, t0)
        XCTAssertEqual(back?.lastSeen, later)
    }

    /// A path that failed four times last week must not be laundered clean by
    /// a fresh window that simply never tried it.
    func testUnansweredAttemptsAreAHighWaterMark() throws {
        let store = try makeStore()
        try store.record([path("A", "B", unanswered: 4)], now: t0)
        try store.record([path("A", "B", unanswered: 0)], now: t0)
        let back = try store.paths(since: t0.addingTimeInterval(-60)).first
        XCTAssertEqual(back?.unansweredAttempts, 4)
        XCTAssertTrue(back?.isSuspect == true)
    }

    func testMergingIsOrderIndependent() {
        let strong = path("A", "B", evidence: .sessionEstablished, observations: 3,
                          first: t0, last: t0)
        let weak = path("A", "B", evidence: .heardDirect, observations: 9,
                        first: t0.addingTimeInterval(-500),
                        last: t0.addingTimeInterval(500), unanswered: 2)
        XCTAssertEqual(NetworkPath.merged(strong, weak),
                       NetworkPath.merged(weak, strong))
    }

    /// A and B is the same path as B and A, and must not become two rows.
    func testTheSamePathFromBothDirectionsIsOneRow() throws {
        let store = try makeStore()
        try store.record([path("A", "B"), path("B", "A")], now: t0)
        XCTAssertEqual(try store.paths(since: t0.addingTimeInterval(-60)).count, 1)
    }

    /// Different digipeater routes between the same pair are different paths.
    func testDifferentHopsAreDifferentPaths() throws {
        let store = try makeStore()
        try store.record([
            path("A", "B", via: ["DRLNOD"], evidence: .heardDigipeated),
            path("A", "B", via: ["HORSE"], evidence: .heardDigipeated),
        ], now: t0)
        XCTAssertEqual(try store.paths(since: t0.addingTimeInterval(-60)).count, 2)
    }

    // MARK: - Retention

    func testPathsOlderThanTheCutoffAreNotReturned() throws {
        let store = try makeStore()
        let old = t0.addingTimeInterval(-30 * 24 * 3600)
        try store.record([path("OLD", "GONE", first: old, last: old)], now: old)
        try store.record([path("A", "B")], now: t0)

        let recent = try store.paths(since: t0.addingTimeInterval(-3600))
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.from, "A")
    }

    /// A station that moved away should stop being drawn as a neighbour.
    func testPruningDropsStalePaths() throws {
        let store = try makeStore()
        let old = t0.addingTimeInterval(-30 * 24 * 3600)
        try store.record([path("OLD", "GONE", first: old, last: old)], now: old)
        try store.record([path("A", "B")], now: t0)

        let removed = try store.prune(before: t0.addingTimeInterval(-3600))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try store.paths(since: .distantPast).count, 1)
    }

    func testPruningKeepsEverythingStillFresh() throws {
        let store = try makeStore()
        try store.record([path("A", "B"), path("C", "D")], now: t0)
        XCTAssertEqual(try store.prune(before: t0.addingTimeInterval(-3600)), 0)
        XCTAssertEqual(try store.paths(since: .distantPast).count, 2)
    }

    func testRecordingNothingIsHarmless() throws {
        let store = try makeStore()
        try store.record([], now: t0)
        XCTAssertTrue(try store.paths(since: .distantPast).isEmpty)
    }
}
