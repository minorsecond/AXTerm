//
//  FilteringTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest
@testable import AXTerm

final class FilteringTests: XCTestCase {

    // Test data setup
    private func createTestPackets() -> [Packet] {
        [
            Packet(
                from: AX25Address(call: "N0CALL", ssid: 1),
                to: AX25Address(call: "APRS"),
                via: [AX25Address(call: "WIDE1", ssid: 1)],
                frameType: .ui,
                info: "Test message 1".data(using: .ascii)!
            ),
            Packet(
                from: AX25Address(call: "W0ABC"),
                to: AX25Address(call: "APRS"),
                frameType: .ui,
                info: "Position report".data(using: .ascii)!
            ),
            Packet(
                from: AX25Address(call: "N0CALL", ssid: 1),
                to: AX25Address(call: "W0XYZ"),
                frameType: .i,
                info: Data() // No info
            ),
            Packet(
                from: AX25Address(call: "K0DEF"),
                to: AX25Address(call: "N0CALL", ssid: 1),
                frameType: .s
            ),
            Packet(
                from: AX25Address(call: "N0CALL", ssid: 1),
                to: AX25Address(call: "CQ"),
                frameType: .u
            )
        ]
    }

    // MARK: - Station Filter Tests

    func testFilterByStationCall() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationCall: "N0CALL-1")

        XCTAssertEqual(filtered.count, 3)
        XCTAssertTrue(filtered.allSatisfy { $0.fromDisplay == "N0CALL-1" })
    }

    func testFilterByStationCallNoMatch() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationCall: "NOBODY")

        XCTAssertEqual(filtered.count, 0)
    }

    // MARK: - Frame Type Filter Tests

    func testFilterByFrameTypeUI() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.showI = false
        filters.showS = false
        filters.showU = false

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationCall: nil)

        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.allSatisfy { $0.frameType == .ui })
    }

    func testFilterByFrameTypeI() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.showUI = false
        filters.showS = false
        filters.showU = false

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationCall: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].frameType, .i)
    }

    func testFilterAllFrameTypesOff() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.showUI = false
        filters.showI = false
        filters.showS = false
        filters.showU = false

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationCall: nil)

        XCTAssertEqual(filtered.count, 0)
    }

    // MARK: - Only With Info Filter Tests

    func testFilterOnlyWithInfo() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.onlyWithInfo = true

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationCall: nil)

        // Only packets with non-empty, printable info
        XCTAssertTrue(filtered.allSatisfy { $0.infoText != nil })
    }

    func testFilterOnlyPinned() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.onlyPinned = true
        let pinnedIDs: Set<Packet.ID> = [packets[1].id]

        let filtered = PacketFilter.filter(
            packets: packets,
            search: "",
            filters: filters,
            stationCall: nil,
            pinnedIDs: pinnedIDs
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, packets[1].id)
    }

    // MARK: - Search Filter Tests

    func testSearchMatchesFrom() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "W0ABC", filters: filters, stationCall: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].fromDisplay, "W0ABC")
    }

    func testSearchMatchesTo() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "W0XYZ", filters: filters, stationCall: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].toDisplay, "W0XYZ")
    }

    func testSearchMatchesVia() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "WIDE1", filters: filters, stationCall: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered[0].viaDisplay.contains("WIDE1"))
    }

    func testSearchMatchesInfo() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "Position", filters: filters, stationCall: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered[0].infoText?.contains("Position") ?? false)
    }

    func testSearchCaseInsensitive() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "position", filters: filters, stationCall: nil)

        XCTAssertEqual(filtered.count, 1)
    }

    func testSearchNoMatch() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "ZZZZZ", filters: filters, stationCall: nil)

        XCTAssertEqual(filtered.count, 0)
    }

    // MARK: - Combined Filters Tests

    func testCombinedFilters() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.showI = false
        filters.showS = false
        filters.showU = false
        filters.onlyWithInfo = true

        let filtered = PacketFilter.filter(packets: packets, search: "APRS", filters: filters, stationCall: nil)

        // UI frames only, with info, matching "APRS"
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.allSatisfy { $0.frameType == .ui })
        XCTAssertTrue(filtered.allSatisfy { $0.infoText != nil })
    }

    // MARK: - PacketFilters Tests

    func testPacketFiltersAllowsFrameType() {
        var filters = PacketFilters()

        // All enabled by default
        XCTAssertTrue(filters.allows(frameType: .ui))
        XCTAssertTrue(filters.allows(frameType: .i))
        XCTAssertTrue(filters.allows(frameType: .s))
        XCTAssertTrue(filters.allows(frameType: .u))
        XCTAssertTrue(filters.allows(frameType: .unknown))

        // Disable UI
        filters.showUI = false
        XCTAssertFalse(filters.allows(frameType: .ui))
        XCTAssertTrue(filters.allows(frameType: .i))
    }

}
