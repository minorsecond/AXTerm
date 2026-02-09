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
                from: AX25Address(call: "W1PAY"),
                to: AX25Address(call: "APRS"),
                frameType: .ui,
                info: Data([0x00, 0xFF, 0x10])
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

    // MARK: - StationID Normalization Tests

    func testStationIDNormalization() {
        // Basic callsign
        let id1 = StationID("N0CALL")
        XCTAssertEqual(id1.call, "N0CALL")
        XCTAssertEqual(id1.ssid, 0)
        XCTAssertEqual(id1.display, "N0CALL")

        // Callsign with SSID 0
        let id2 = StationID("N0CALL-0")
        XCTAssertEqual(id2.call, "N0CALL")
        XCTAssertEqual(id2.ssid, 0)
        XCTAssertEqual(id2.display, "N0CALL")

        // They should be equal
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(id1.id, id2.id)

        // Lowercase normalization
        let id3 = StationID("n0call-7")
        XCTAssertEqual(id3.call, "N0CALL")
        XCTAssertEqual(id3.ssid, 7)
        XCTAssertEqual(id3.display, "N0CALL-7")
    }

    func testStationIDParsing() {
        XCTAssertEqual(StationID("K0NTS-15").ssid, 15)
        XCTAssertEqual(StationID("K0NTS-16").ssid, 0) // Out of range maps to 0
        XCTAssertEqual(StationID("K0NTS-A").ssid, 0)  // Invalid SSID maps to 0
    }

    // MARK: - Station Filter Tests

    func testFilterByStationID() {
        let packets = createTestPackets()
        let filters = PacketFilters()
        let stationID = StationID("N0CALL-1")

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationID: stationID)

        XCTAssertEqual(filtered.count, 3)
        XCTAssertTrue(filtered.allSatisfy { $0.fromDisplay == "N0CALL-1" })
    }

    func testFilterByStationIDNoMatch() {
        let packets = createTestPackets()
        let filters = PacketFilters()
        let stationID = StationID("NOBODY")

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationID: stationID)

        XCTAssertEqual(filtered.count, 0)
    }

    // MARK: - Frame Type Filter Tests

    func testFilterByFrameTypeUI() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.showI = false
        filters.showS = false
        filters.showU = false

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationID: nil)

        XCTAssertEqual(filtered.count, 3)
        XCTAssertTrue(filtered.allSatisfy { $0.frameType == .ui })
    }

    func testFilterByFrameTypeI() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.showUI = false
        filters.showS = false
        filters.showU = false

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationID: nil)

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

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationID: nil)

        XCTAssertEqual(filtered.count, 0)
    }

    // MARK: - Payload Filter Tests

    func testFilterPayloadOnly() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.payloadOnly = true

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationID: nil)

        XCTAssertFalse(filtered.contains { $0.frameType == .s || $0.frameType == .u })
        XCTAssertTrue(filtered.allSatisfy { $0.frameType == .i || $0.frameType == .ui })
        XCTAssertTrue(filtered.filter { $0.frameType == .ui }.allSatisfy { !$0.info.isEmpty })
    }

    func testPayloadOnlyIncludesBinaryUI() {
        let packets: [Packet] = [
            Packet(frameType: .i, info: Data()),
            Packet(frameType: .s),
            Packet(frameType: .u),
            Packet(frameType: .ui, info: Data()),
            Packet(frameType: .ui, info: Data([0x01, 0x02, 0x03]))
        ]
        var filters = PacketFilters()
        filters.payloadOnly = true

        let filtered = PacketFilter.filter(packets: packets, search: "", filters: filters, stationID: nil)

        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.contains { $0.frameType == .i })
        XCTAssertTrue(filtered.contains { $0.frameType == .ui && !$0.info.isEmpty })
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
            stationID: nil,
            pinnedIDs: pinnedIDs
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, packets[1].id)
    }

    // MARK: - Search Filter Tests

    func testSearchMatchesFrom() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "W0ABC", filters: filters, stationID: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].fromDisplay, "W0ABC")
    }

    func testSearchMatchesTo() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "W0XYZ", filters: filters, stationID: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].toDisplay, "W0XYZ")
    }

    func testSearchMatchesVia() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "WIDE1", filters: filters, stationID: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered[0].viaDisplay.contains("WIDE1"))
    }

    func testSearchMatchesInfo() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "Position", filters: filters, stationID: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered[0].infoText?.contains("Position") ?? false)
    }

    func testSearchCaseInsensitive() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "position", filters: filters, stationID: nil)

        XCTAssertEqual(filtered.count, 1)
    }

    func testSearchNoMatch() {
        let packets = createTestPackets()
        let filters = PacketFilters()

        let filtered = PacketFilter.filter(packets: packets, search: "ZZZZZ", filters: filters, stationID: nil)

        XCTAssertEqual(filtered.count, 0)
    }

    // MARK: - Combined Filters Tests

    func testCombinedFilters() {
        let packets = createTestPackets()
        var filters = PacketFilters()
        filters.showI = false
        filters.showS = false
        filters.showU = false
        filters.payloadOnly = true

        let filtered = PacketFilter.filter(packets: packets, search: "APRS", filters: filters, stationID: nil)

        // UI frames only, with info, matching "APRS"
        XCTAssertEqual(filtered.count, 3)
        XCTAssertTrue(filtered.allSatisfy { $0.frameType == .ui })
        XCTAssertTrue(filtered.allSatisfy { !$0.info.isEmpty })
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
