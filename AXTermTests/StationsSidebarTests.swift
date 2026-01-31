//
//  StationsSidebarTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-08.
//

import XCTest
@testable import AXTerm

@MainActor
final class StationsSidebarTests: XCTestCase {
    func testStationsSeedFromPersistedPacketsOnInit() async {
        let settings = makeSettings(persistHistory: true)
        let store = MockPacketStore()
        let endpoint = KISSEndpoint(host: "localhost", port: 8001)!

        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_100)

        let firstPacket = Packet(
            timestamp: earlier,
            from: AX25Address(call: "ALPHA"),
            to: AX25Address(call: "DEST"),
            frameType: .ui,
            control: 0x03,
            info: Data([0x41]),
            rawAx25: Data([0x01]),
            kissEndpoint: endpoint
        )

        let secondPacket = Packet(
            timestamp: later,
            from: AX25Address(call: "BRAVO"),
            to: AX25Address(call: "DEST"),
            frameType: .ui,
            control: 0x03,
            info: Data([0x42]),
            rawAx25: Data([0x02]),
            kissEndpoint: endpoint
        )

        store.loadResult = [
            try! PacketRecord(packet: firstPacket, endpoint: endpoint),
            try! PacketRecord(packet: secondPacket, endpoint: endpoint)
        ]

        let client = PacketEngine(
            maxPackets: 10,
            settings: settings,
            packetStore: store
        )

        await waitForStations(client, minimumCount: 2)

        XCTAssertEqual(client.stations.count, 2)
        XCTAssertEqual(client.stations.first?.call, "BRAVO")
        XCTAssertEqual(client.stations.last?.call, "ALPHA")
    }

    func testStationsUpdateAndPreserveSelectionOnInsert() async {
        let settings = makeSettings(persistHistory: false)
        let client = PacketEngine(settings: settings)

        let base = Date()
        let firstPacket = Packet(timestamp: base, from: AX25Address(call: "ALPHA"))
        client.handleIncomingPacket(firstPacket)

        await waitForStations(client, minimumCount: 1)
        client.selectedStationCall = "ALPHA"

        let secondPacket = Packet(timestamp: base.addingTimeInterval(10), from: AX25Address(call: "BRAVO"))
        client.handleIncomingPacket(secondPacket)

        await waitForStations(client, minimumCount: 2)
        XCTAssertEqual(client.stations.first?.call, "BRAVO")
        XCTAssertEqual(client.stations.last?.call, "ALPHA")
        XCTAssertEqual(client.selectedStationCall, "ALPHA")

        let thirdPacket = Packet(timestamp: base.addingTimeInterval(20), from: AX25Address(call: "ALPHA"))
        client.handleIncomingPacket(thirdPacket)

        await waitForStations(client, minimumCount: 2)
        XCTAssertEqual(client.stations.first?.call, "ALPHA")
        XCTAssertEqual(client.stations.first?.heardCount, 2)
        XCTAssertEqual(client.selectedStationCall, "ALPHA")
    }

    private func makeSettings(persistHistory: Bool) -> AppSettingsStore {
        let suiteName = "AXTermTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.set(persistHistory, forKey: AppSettingsStore.persistKey)
        return AppSettingsStore(defaults: defaults)
    }

    private func waitForStations(_ client: PacketEngine, minimumCount: Int) async {
        for _ in 0..<20 {
            if client.stations.count >= minimumCount {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
