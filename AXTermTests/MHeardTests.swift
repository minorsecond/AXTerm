//
//  MHeardTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest
@testable import AXTerm

final class MHeardTests: XCTestCase {

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
