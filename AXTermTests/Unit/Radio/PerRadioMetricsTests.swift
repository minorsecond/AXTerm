import XCTest
import GRDB
@testable import AXTerm

/// Link quality, neighbours and routes are kept per radio.
///
/// A delivery probability is a property of a path between two antennas on
/// one band. Two of our radios hearing the same station are two links; a
/// clean one and a marginal one must not average into a mediocre figure
/// that misroutes both (CLAUDE.md §8: evidence-based).
final class PerRadioMetricsTests: XCTestCase {

    private let a = RadioID.primary
    private let b = RadioID(rawValue: "ic705")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func iFrame(from: String, to: String, ns: Int, radio: RadioID, at: TimeInterval) -> Packet {
        Packet(timestamp: t0.addingTimeInterval(at),
               from: AX25Address(call: from), to: AX25Address(call: to),
               frameType: .i, control: UInt8(ns << 1), pid: 0xF0,
               info: Data("payload \(ns)".utf8), rawAx25: Data([0x01]), radioID: radio)
    }

    // MARK: - The estimator

    /// Clean on one radio, retried on the other: two figures, not one.
    func testALinkIsMeasuredSeparatelyOnEachRadio() {
        var estimator = LinkQualityEstimator(clock: { self.t0.addingTimeInterval(120) })
        for i in 0..<12 {
            estimator.observePacket(iFrame(from: "K0NTS-1", to: "K0EPI-7", ns: i % 8, radio: a, at: Double(i) * 5), timestamp: t0.addingTimeInterval(Double(i) * 5))
            let onB = iFrame(from: "K0NTS-1", to: "K0EPI-7", ns: i % 8, radio: b, at: Double(i) * 5)
            estimator.observePacket(onB, timestamp: t0.addingTimeInterval(Double(i) * 5), isDuplicate: i % 2 == 1)
        }
        let cleanA = estimator.linkStats(from: "K0NTS-1", to: "K0EPI-7", radio: a)
        let noisyB = estimator.linkStats(from: "K0NTS-1", to: "K0EPI-7", radio: b)
        XCTAssertEqual(cleanA.duplicateCount, 0)
        XCTAssertGreaterThan(noisyB.duplicateCount, 0)
        XCTAssertGreaterThan(estimator.linkQuality(from: "K0NTS-1", to: "K0EPI-7", radio: a),
                             estimator.linkQuality(from: "K0NTS-1", to: "K0EPI-7", radio: b))
        XCTAssertEqual(estimator.radios(from: "K0NTS-1", to: "K0EPI-7"), [a, b])
    }

    /// Export carries the radio and comes back to the same radio.
    func testLinkStatsRoundTripPerRadio() {
        var estimator = LinkQualityEstimator(clock: { self.t0.addingTimeInterval(60) })
        estimator.observePacket(iFrame(from: "K0NTS-1", to: "K0EPI-7", ns: 0, radio: a, at: 0), timestamp: t0)
        estimator.observePacket(iFrame(from: "K0NTS-1", to: "K0EPI-7", ns: 0, radio: b, at: 1), timestamp: t0.addingTimeInterval(1))
        let exported = estimator.exportLinkStats()
        XCTAssertEqual(Set(exported.map(\.radioID)), [a, b])
        XCTAssertEqual(exported.map(\.radioID), exported.map(\.radioID).sorted { $0.rawValue < $1.rawValue },
                       "deterministic export order")

        var restored = LinkQualityEstimator(clock: { self.t0.addingTimeInterval(60) })
        restored.importLinkStats(exported)
        XCTAssertEqual(restored.exportLinkStats(), exported)
    }

    /// A caller that names no radio gets the primary, as it always did.
    func testTheDefaultRadioIsThePrimary() {
        var estimator = LinkQualityEstimator()
        let noRadio = Packet(timestamp: t0, from: AX25Address(call: "K0NTS-1"), to: AX25Address(call: "K0EPI-7"),
                             frameType: .ui, control: 0x03, pid: 0xF0, info: Data([1]), rawAx25: Data([1]))
        estimator.observePacket(noRadio, timestamp: t0)
        XCTAssertEqual(estimator.radios(from: "K0NTS-1", to: "K0EPI-7"), [.primary])
        XCTAssertEqual(estimator.exportLinkStats().first?.radioID, .primary)
    }

    // MARK: - The router

    private func direct(from: String, to: String, radio: RadioID) -> Packet {
        Packet(timestamp: t0, from: AX25Address(call: from), to: AX25Address(call: to),
               frameType: .ui, control: 0x03, pid: 0xF0, info: Data([1]), rawAx25: Data([1]), radioID: radio)
    }

    func testANeighborOnTwoRadiosIsTwoNeighbors() {
        let router = NetRomRouter(localCallsign: "K0EPI-7")
        router.observePacket(direct(from: "K0NTS-1", to: "K0EPI-7", radio: a), observedQuality: 220, direction: .incoming, timestamp: t0)
        router.observePacket(direct(from: "K0NTS-1", to: "K0EPI-7", radio: b), observedQuality: 120, direction: .incoming, timestamp: t0)
        let neighbors = router.currentNeighbors().filter { $0.call == "K0NTS-1" }
        XCTAssertEqual(neighbors.count, 2)
        XCTAssertEqual(Set(neighbors.map(\.radioID)), [a, b])
        XCTAssertNotEqual(neighbors[0].quality, neighbors[1].quality)
        XCTAssertEqual(router.radio(forNeighbor: "K0NTS-1"), a, "best heard on the primary")
    }

    /// The same next hop on two radios is two ways in, and equal evidence
    /// is broken deterministically: the primary radio first.
    func testRoutesAreKeyedByRadioAndTiesGoToThePrimary() {
        let router = NetRomRouter(localCallsign: "K0EPI-7")
        for radio in [b, a] {
            router.observePacket(direct(from: "NODE", to: "K0EPI-7", radio: radio), observedQuality: 200, direction: .incoming, timestamp: t0)
            router.broadcastRoutes(from: "NODE", radio: radio, quality: 200, destinations: [
                RouteInfo(destination: "FAR", origin: "NODE", quality: 200, path: ["NODE", "FAR"], lastUpdated: t0, radioID: radio)
            ], timestamp: t0)
        }
        let candidates = router.candidateRoutes(to: "FAR", currentDate: t0)
        XCTAssertEqual(candidates.count, 2, "one neighbor, two radios, two routes")
        XCTAssertEqual(candidates.first?.radioID, a, "ties go to the primary radio")
        XCTAssertEqual(router.bestRouteTo("FAR", currentDate: t0)?.radioID, a)
    }

    /// Hearing the origin on one radio refreshes only the routes learned
    /// through it on that radio.
    func testRefreshingAnOriginIsPerRadio() {
        let router = NetRomRouter(localCallsign: "K0EPI-7")
        for radio in [a, b] {
            router.observePacket(direct(from: "NODE", to: "K0EPI-7", radio: radio), observedQuality: 200, direction: .incoming, timestamp: t0)
            router.broadcastRoutes(from: "NODE", radio: radio, quality: 200, destinations: [
                RouteInfo(destination: "FAR", origin: "NODE", quality: 200, path: ["NODE", "FAR"], lastUpdated: t0, radioID: radio)
            ], timestamp: t0)
        }
        let later = t0.addingTimeInterval(600)
        router.refreshRoutes(from: "NODE", radio: b, timestamp: later, allowedSourceTypes: ["broadcast"])
        let routes = router.currentRoutes().filter { $0.destination == "FAR" }
        XCTAssertEqual(routes.first { $0.radioID == b }?.lastUpdated, later)
        XCTAssertEqual(routes.first { $0.radioID == a }?.lastUpdated, t0)
    }

    // MARK: - Persistence

    func testNeighborsRoutesAndLinkStatsPersistPerRadio() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        let persistence = try NetRomPersistence(database: queue)
        let neighbors = [
            NeighborInfo(call: "K0NTS-1", quality: 220, lastSeen: t0, radioID: a),
            NeighborInfo(call: "K0NTS-1", quality: 120, lastSeen: t0, radioID: b),
        ]
        let routes = [
            RouteInfo(destination: "FAR", origin: "K0NTS-1", quality: 200, path: ["K0NTS-1", "FAR"], lastUpdated: t0, radioID: a),
            RouteInfo(destination: "FAR", origin: "K0NTS-1", quality: 100, path: ["K0NTS-1", "FAR"], lastUpdated: t0, radioID: b),
        ]
        let stats = [
            LinkStatRecord(fromCall: "K0NTS-1", toCall: "K0EPI-7", quality: 200, lastUpdated: t0, observationCount: 4, radioID: a),
            LinkStatRecord(fromCall: "K0NTS-1", toCall: "K0EPI-7", quality: 90, lastUpdated: t0, observationCount: 4, radioID: b),
        ]
        try persistence.saveSnapshot(neighbors: neighbors, routes: routes, linkStats: stats, lastPacketID: 1, configHash: nil)

        XCTAssertEqual(Set(try persistence.loadNeighbors().map(\.radioID)), [a, b])
        XCTAssertEqual(try persistence.loadRoutes().count, 2)
        XCTAssertEqual(Set(try persistence.loadLinkStats(now: t0).map(\.radioID)), [a, b])
    }

    /// Tables from before the radio was part of the key are rebuilt on
    /// open, every row attributed to the primary radio.
    func testOldRoutingTablesAreRebuiltWithTheRadioKey() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE netrom_neighbors (call TEXT PRIMARY KEY, quality INTEGER NOT NULL, lastSeen DOUBLE NOT NULL,
                    obsolescenceCount INTEGER NOT NULL DEFAULT 1, sourceType TEXT NOT NULL DEFAULT 'classic');
                INSERT INTO netrom_neighbors (call, quality, lastSeen) VALUES ('K0NTS-1', 200, 1000000);
                CREATE TABLE netrom_routes (destination TEXT NOT NULL, origin TEXT NOT NULL, quality INTEGER NOT NULL,
                    pathJson TEXT NOT NULL, sourceType TEXT NOT NULL DEFAULT 'broadcast', lastUpdate DOUBLE NOT NULL DEFAULT 0,
                    PRIMARY KEY (destination, origin));
                INSERT INTO netrom_routes (destination, origin, quality, pathJson) VALUES ('FAR', 'K0NTS-1', 150, '["K0NTS-1","FAR"]');
                CREATE TABLE link_stats (fromCall TEXT NOT NULL, toCall TEXT NOT NULL, quality INTEGER NOT NULL,
                    lastUpdated DOUBLE NOT NULL, dfEstimate DOUBLE, drEstimate DOUBLE, dupCount INTEGER NOT NULL DEFAULT 0,
                    ewmaQuality INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (fromCall, toCall));
                INSERT INTO link_stats (fromCall, toCall, quality, lastUpdated) VALUES ('K0NTS-1', 'TEST-7', 180, 1000000);
                """)
        }
        let persistence = try NetRomPersistence(database: queue)
        XCTAssertEqual(try persistence.loadNeighbors().map(\.radioID), [.primary])
        XCTAssertEqual(try persistence.loadRoutes().map(\.radioID), [.primary])
        XCTAssertEqual(try persistence.loadLinkStats(now: t0).map(\.radioID), [.primary])
        // The new key admits the same neighbor on a second radio.
        try persistence.saveNeighbors([
            NeighborInfo(call: "K0NTS-1", quality: 200, lastSeen: t0, radioID: a),
            NeighborInfo(call: "K0NTS-1", quality: 100, lastSeen: t0, radioID: b),
        ], lastPacketID: 2)
        XCTAssertEqual(try persistence.loadNeighbors().count, 2)
    }

    /// The link-quality time series carries the radio too.
    func testLinkQualityHistoryIsPerRadio() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLiteLinkQualityHistoryStore(dbQueue: queue)
        try store.record([
            LinkStatRecord(fromCall: "K0NTS-1", toCall: "K0EPI-7", quality: 200, lastUpdated: t0, radioID: a),
            LinkStatRecord(fromCall: "K0NTS-1", toCall: "K0EPI-7", quality: 90, lastUpdated: t0, radioID: b),
        ], at: t0)
        let samples = try store.history(from: "K0NTS-1", to: "K0EPI-7", since: t0.addingTimeInterval(-1))
        XCTAssertEqual(samples.count, 2, "one sample per radio, not one per link")
        XCTAssertEqual(Set(samples.map(\.radioID)), [a, b])
    }
}
