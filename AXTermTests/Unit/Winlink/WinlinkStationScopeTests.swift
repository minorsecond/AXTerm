//
//  WinlinkStationScopeTests.swift
//  AXTermTests
//
//  `gateway/status.json` has no geographic filter: the whole world already
//  arrives on every refresh and the radius is applied on-device. The wide
//  list was being downloaded and thrown away. The only thing missing was
//  somewhere to keep it that a refresh at home would not wipe.
//

import XCTest
import GRDB
@testable import AXTerm

final class WinlinkStationScopeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func station(_ callsign: String, grid: String = "DM79QL",
                         hz: Int = 145_030_000, miles: Double = 10) -> WinlinkRMSStationRecord {
        WinlinkRMSStationRecord(
            callsign: callsign, gridSquare: grid, frequencyHz: hz,
            modeName: "packet", baud: "1200", serviceCode: "PUBLIC",
            distanceMiles: miles, headingDegrees: 180,
            lastSeenAt: t0, fetchedAt: t0)
    }

    // MARK: - The reason this exists

    func testRefreshingLocalDoesNotDestroyTheDownloadedSet() throws {
        let store = try makeStore()
        try store.replaceStationCache(
            [station("N0FAR", grid: "DN70KA", hz: 145_090_000, miles: 400)], scope: .global)
        try store.replaceStationCache([station("W0ARP-10")], scope: .local)

        // The whole point: a 100-mile refresh at home used to delete a list
        // fetched for a trip.
        try store.replaceStationCache([station("W0ARP-10")], scope: .local)

        XCTAssertEqual(try store.stations(scope: .global).map(\.callsign), ["N0FAR"])
        XCTAssertEqual(try store.stations(scope: .local).map(\.callsign), ["W0ARP-10"])
    }

    func testDownloadingATripDoesNotDestroyTheLocalSet() throws {
        let store = try makeStore()
        try store.replaceStationCache([station("W0ARP-10")], scope: .local)
        try store.replaceStationCache(
            [station("N0FAR", grid: "DN70KA", hz: 145_090_000, miles: 400)], scope: .global)
        XCTAssertEqual(try store.stations(scope: .local).map(\.callsign), ["W0ARP-10"])
    }

    // MARK: - Overlap

    func testLocalWinsWhenAGatewayIsInBothSets() throws {
        let store = try makeStore()
        try store.replaceStationCache([station("W0ARP-10", miles: 9.7)], scope: .local)
        try store.replaceStationCache([station("W0ARP-10", miles: 9.7)], scope: .global)

        // callsign+frequency is the primary key, so only one row can exist.
        // Local keeps it, because its distance is measured from where the
        // operator actually is.
        let all = try store.stations()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.scope, .local)
    }

    func testClearingDownloadedLeavesLocalAlone() throws {
        let store = try makeStore()
        try store.replaceStationCache([station("W0ARP-10")], scope: .local)
        try store.replaceStationCache(
            [station("N0FAR", grid: "DN70KA", hz: 145_090_000)], scope: .global)

        try store.clearDownloadedStations()

        XCTAssertTrue(try store.stations(scope: .global).isEmpty)
        XCTAssertEqual(try store.stations(scope: .local).map(\.callsign), ["W0ARP-10"])
    }

    // MARK: - Regions

    func testGridFieldIsTheFirstTwoCharacters() {
        XCTAssertEqual(station("W0ARP-10", grid: "DM79QL").gridField, "DM")
        XCTAssertEqual(station("N0FAR", grid: "dn70ka").gridField, "DN")
    }

    func testDownloadedFieldsAreCountedAndRanked() throws {
        let store = try makeStore()
        try store.replaceStationCache([
            station("A", grid: "DM79QL", hz: 1),
            station("B", grid: "DM88AA", hz: 2),
            station("C", grid: "DN70KA", hz: 3),
        ], scope: .global)

        let fields = try store.downloadedGridFields()
        XCTAssertEqual(fields.first?.field, "DM")
        XCTAssertEqual(fields.first?.count, 2)
        XCTAssertEqual(fields.count, 2)
    }

    func testLocalRowsAreNotCountedAsDownloadedRegions() throws {
        let store = try makeStore()
        try store.replaceStationCache([station("W0ARP-10", grid: "DM79QL")], scope: .local)
        // Otherwise "have I got DM?" would answer yes off the back of the
        // home cache and mislead someone packing for a trip.
        XCTAssertTrue(try store.downloadedGridFields().isEmpty)
    }

    func testExistingRowsMigrateAsLocal() throws {
        let store = try makeStore()
        try store.replaceStationCache([station("W0ARP-10")], scope: .local)
        XCTAssertEqual(try store.stations().first?.scope, .local,
                       "rows written before the split were fetched under the local radius")
    }
}
