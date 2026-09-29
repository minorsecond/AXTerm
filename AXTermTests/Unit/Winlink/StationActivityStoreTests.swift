import XCTest
import GRDB
@testable import AXTerm

/// Persistence and publication for attributed observations.
final class StationActivityStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteStationActivityStore {
        let queue = try DatabaseQueue()
        try queue.write { try DatabaseManager.createRemoteStationActivity($0) }
        return SQLiteStationActivityStore(dbQueue: queue)
    }

    private func payload(_ callsign: String, station: String, device: String,
                         frames: Int = 3,
                         heard: Date = Date(timeIntervalSince1970: 5_000)) -> StationActivityPayload {
        StationActivityPayload(
            callsign: callsign, roles: ["Node", "BBS"],
            firstHeard: heard.addingTimeInterval(-60), lastHeard: heard,
            frameCount: frames, airtimeSeconds: 2.5,
            provenance: WinlinkSyncProvenance(
                station: station, deviceID: device,
                gridSquare: "DM79GR", observedAt: heard))
    }

    func testAnObservationSurvivesTheRoundTrip() throws {
        let store = try makeStore()
        try store.saveRemoteStationActivity([payload("N0CVL-10", station: "K0EPI-7", device: "mac")])

        let back = try XCTUnwrap(try store.remoteStationActivity().first)
        XCTAssertEqual(back.callsign, "N0CVL-10")
        XCTAssertEqual(back.roles, ["Node", "BBS"])
        XCTAssertEqual(back.frameCount, 3)
        XCTAssertEqual(back.provenance.station, "K0EPI-7")
        XCTAssertEqual(back.provenance.gridSquare, "DM79GR")
    }

    /// A fresher report from the same receiver replaces the older one — it
    /// is one fact seen again, not two facts.
    func testARepeatReportFromOneReceiverReplacesTheOlder() throws {
        let store = try makeStore()
        try store.saveRemoteStationActivity([payload("N0CVL-10", station: "K0EPI-7", device: "mac", frames: 3)])
        try store.saveRemoteStationActivity([payload("N0CVL-10", station: "K0EPI-7", device: "mac", frames: 9)])

        let all = try store.remoteStationActivity()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].frameCount, 9)
    }

    /// Two receivers hearing one station stay two rows. Collapsing them
    /// would silently discard one antenna's view of the network.
    func testTwoReceiversHearingOneStationBothSurvive() throws {
        let store = try makeStore()
        try store.saveRemoteStationActivity([
            payload("N0CVL-10", station: "K0EPI-7", device: "mac"),
            payload("N0CVL-10", station: "K0EPI-9", device: "ipad"),
        ])
        XCTAssertEqual(try store.remoteStationActivity().count, 2)
    }

    /// Remote arrivals must never appear as this station's own.
    func testRemoteRowsAreNotOfferedForPublication() throws {
        let store = try makeStore()
        try store.saveRemoteStationActivity([payload("N0CVL-10", station: "K0EPI-7", device: "mac")])
        XCTAssertTrue(try store.localStationActivity().isEmpty)
    }

    /// A station that has not yet worked out what it heard publishes
    /// nothing, rather than guessing.
    func testNothingIsPublishedBeforeAnalyticsHasRun() throws {
        XCTAssertTrue(try makeStore().localStationActivity().isEmpty)
    }

    func testTheLocalSnapshotIsWhatGetsPublished() throws {
        let store = try makeStore()
        store.setLocalActivity([payload("W0ARP-10", station: "K0EPI-9", device: "ipad")])
        XCTAssertEqual(try store.localStationActivity().map(\.callsign), ["W0ARP-10"])
    }

    // MARK: Publication

    private func entry(_ callsign: String, lastHeard: Date) -> StationDirectoryEntry {
        StationDirectoryEntry(
            callsign: callsign, roles: [], firstHeard: lastHeard.addingTimeInterval(-3600),
            lastHeard: lastHeard, frameCount: 4, airtimeSeconds: 1)
    }

    /// Only recent observations are offered. Publishing the whole history
    /// every pass would grow without bound and re-send facts that have not
    /// changed.
    func testOnlyRecentObservationsArePublished() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let payloads = StationActivityPublication.payloads(
            from: [entry("FRESH", lastHeard: now.addingTimeInterval(-3600)),
                   entry("STALE", lastHeard: now.addingTimeInterval(-30 * 86_400))],
            station: "K0EPI-7", deviceID: "mac", gridSquare: "DM79GR", now: now)

        XCTAssertEqual(payloads.map(\.callsign), ["FRESH"])
    }

    /// Every published observation is stamped with who made it and where.
    func testPublishedObservationsCarryProvenance() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let payload = StationActivityPublication.payloads(
            from: [entry("N0CVL-10", lastHeard: now)],
            station: "K0EPI-7", deviceID: "mac", gridSquare: "DM79GR", now: now).first

        XCTAssertEqual(payload?.provenance.station, "K0EPI-7")
        XCTAssertEqual(payload?.provenance.deviceID, "mac")
        XCTAssertEqual(payload?.provenance.gridSquare, "DM79GR")
    }

    /// An unset grid square publishes as absent rather than as an empty
    /// string, so the view can tell "no position" from "position is blank".
    func testAnEmptyGridPublishesAsNoPosition() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let payload = StationActivityPublication.payloads(
            from: [entry("N0CVL-10", lastHeard: now)],
            station: "K0EPI-7", deviceID: "mac", gridSquare: "", now: now).first
        XCTAssertNil(payload?.provenance.gridSquare)
    }
}
