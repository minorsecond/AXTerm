//
//  MHeardTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest
@testable import AXTerm

final class MHeardTests: XCTestCase {

    func testStationTrackerUpdatesCountAndVia() {
        let now = Date()
        let later = now.addingTimeInterval(10)
        var tracker = StationTracker()

        // H-bit set: the copy we heard came out of WIDE1-1's transmitter.
        let firstPacket = Packet(
            timestamp: now,
            from: AX25Address(call: "N0CALL", ssid: 1),
            via: [AX25Address(call: "WIDE1", ssid: 1, repeated: true)]
        )
        tracker.update(with: firstPacket)

        XCTAssertEqual(tracker.stations.count, 1)
        XCTAssertEqual(tracker.stations.first?.heardCount, 1)
        XCTAssertEqual(tracker.stations.first?.lastVia, ["WIDE1-1"])

        let secondPacket = Packet(
            timestamp: later,
            from: AX25Address(call: "N0CALL", ssid: 1),
            via: [AX25Address(call: "WIDE2", ssid: 1, repeated: true)]
        )
        tracker.update(with: secondPacket)

        XCTAssertEqual(tracker.stations.count, 1)
        XCTAssertEqual(tracker.stations.first?.heardCount, 2)
        XCTAssertEqual(tracker.stations.first?.lastHeard, later)
        XCTAssertEqual(tracker.stations.first?.lastVia, ["WIDE2-1"])
    }

    /// Regression (field capture 2026-08-22): the sidebar said "Via DRLNOD,
    /// FNKTWN" for a station an entire direct session was proving we hear
    /// directly. lastVia only updated on non-empty via, so a stale digi path
    /// stuck forever once recorded. Hearing a station direct must clear it.
    func testDirectReceptionClearsStaleDigiPath() {
        var tracker = StationTracker()
        let station = AX25Address(call: "KB5YZB", ssid: 7)

        tracker.update(with: Packet(
            timestamp: Date(),
            from: station,
            via: [AX25Address(call: "DRLNOD", ssid: 0, repeated: true),
                  AX25Address(call: "FNKTWN", ssid: 0, repeated: true)]
        ))
        XCTAssertEqual(tracker.stations.first?.lastVia, ["DRLNOD", "FNKTWN"])

        tracker.update(with: Packet(
            timestamp: Date().addingTimeInterval(5),
            from: station,
            via: []
        ))
        XCTAssertEqual(tracker.stations.first?.lastVia, [],
                       "direct reception must clear the stale digipeated path")
    }

    /// A via list whose H-bits are all clear means the frame had NOT been
    /// repeated yet — what we heard was the origin's own transmitter, so the
    /// heard-path is direct regardless of the requested path.
    func testUnrepeatedViaCountsAsDirect() {
        var tracker = StationTracker()
        tracker.update(with: Packet(
            timestamp: Date(),
            from: AX25Address(call: "K0EPI", ssid: 7),
            via: [AX25Address(call: "DRLNOD", ssid: 0, repeated: false)]
        ))
        XCTAssertEqual(tracker.stations.first?.lastVia, [],
                       "an unacted via request is not a heard path")
    }

    func testStationHeardCountIncrements() {
        // Test that Station struct tracks heardCount correctly
        var testStation = Station(call: "N0CALL-1", heardCount: 0)

        // Simulate first packet
        testStation.heardCount += 1
        testStation.lastHeard = Date()
        XCTAssertEqual(testStation.heardCount, 1)

        // Simulate second packet
        testStation.heardCount += 1
        testStation.lastHeard = Date()
        XCTAssertEqual(testStation.heardCount, 2)

        // Simulate third packet
        testStation.heardCount += 1
        XCTAssertEqual(testStation.heardCount, 3)
    }

    func testStationLastHeardUpdates() {
        let initialTime = Date(timeIntervalSince1970: 1000)
        var station = Station(call: "N0CALL", lastHeard: initialTime, heardCount: 1)

        let laterTime = Date(timeIntervalSince1970: 2000)
        station.lastHeard = laterTime

        XCTAssertEqual(station.lastHeard, laterTime)
        XCTAssertNotEqual(station.lastHeard, initialTime)
    }

    func testStationLastViaUpdated() {
        var station = Station(call: "N0CALL", lastVia: [])

        // First packet via WIDE1-1
        station.lastVia = ["WIDE1-1"]
        XCTAssertEqual(station.lastVia, ["WIDE1-1"])

        // Second packet via WIDE1-1, WIDE2-1
        station.lastVia = ["WIDE1-1", "WIDE2-1"]
        XCTAssertEqual(station.lastVia, ["WIDE1-1", "WIDE2-1"])
    }

    func testStationIdentity() {
        let station1 = Station(call: "N0CALL-1", heardCount: 1)
        let station2 = Station(call: "N0CALL-1", heardCount: 5) // Same call, different count

        XCTAssertEqual(station1.id, station2.id)
        XCTAssertEqual(station1.call, station2.call)
    }

    func testStationSortingByLastHeard() {
        let now = Date()
        let earlier = now.addingTimeInterval(-100)
        let earliest = now.addingTimeInterval(-200)

        var stations = [
            Station(call: "FIRST", lastHeard: earliest, heardCount: 1),
            Station(call: "THIRD", lastHeard: now, heardCount: 1),
            Station(call: "SECOND", lastHeard: earlier, heardCount: 1)
        ]

        // Sort by lastHeard descending
        stations.sort { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }

        XCTAssertEqual(stations[0].call, "THIRD")
        XCTAssertEqual(stations[1].call, "SECOND")
        XCTAssertEqual(stations[2].call, "FIRST")
    }

    func testStationSubtitle() {
        let now = Date()
        let station = Station(call: "N0CALL", lastHeard: now, heardCount: 5)

        // Should contain packet count
        XCTAssertTrue(station.subtitle.contains("5 pkts"))
    }

    func testStationSubtitleSingular() {
        let now = Date()
        let station = Station(call: "N0CALL", lastHeard: now, heardCount: 1)

        // Should use singular "pkt"
        XCTAssertTrue(station.subtitle.contains("1 pkt"))
        XCTAssertFalse(station.subtitle.contains("1 pkts"))
    }
}
