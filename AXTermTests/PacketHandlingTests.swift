//
//  PacketHandlingTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import XCTest
@testable import AXTerm

@MainActor
final class PacketHandlingTests: XCTestCase {
    func testHandleIncomingPacketPersistsWhenEnabled() async {
        let settings = makeSettings(persistHistory: true)
        let store = MockPacketStore()
        let consoleStore = MockConsoleStore()
        let rawStore = MockRawStore()
        let eventLogger = MockEventLogger()
        let client = KISSTcpClient(
            maxPackets: 10,
            maxConsoleLines: 10,
            maxRawChunks: 10,
            settings: settings,
            packetStore: store,
            consoleStore: consoleStore,
            rawStore: rawStore,
            eventLogger: eventLogger
        )

        let packet = Packet(
            timestamp: Date(),
            from: AX25Address(call: "N0CALL"),
            to: AX25Address(call: "DEST"),
            frameType: .ui,
            control: 0x03,
            info: Data([0x41]),
            rawAx25: Data([0x01])
        )

        client.handleIncomingPacket(packet)
        client.handleIncomingData(Data([0x01, 0x02, 0x03]))

        XCTAssertEqual(client.packets.count, 1)
        XCTAssertEqual(client.stations.count, 1)

        await waitForStore(store)
        await waitForConsoleStore(consoleStore)
        await waitForRawStore(rawStore)
        XCTAssertEqual(store.savedPackets.count, 1)
        XCTAssertEqual(consoleStore.appendedEntries.count, 1)
        XCTAssertEqual(rawStore.appendedEntries.count, 1)
    }

    func testHandleIncomingPacketSkipsPersistenceWhenDisabled() async {
        let settings = makeSettings(persistHistory: false)
        let store = MockPacketStore()
        let consoleStore = MockConsoleStore()
        let rawStore = MockRawStore()
        let client = KISSTcpClient(
            maxPackets: 10,
            maxConsoleLines: 10,
            maxRawChunks: 10,
            settings: settings,
            packetStore: store,
            consoleStore: consoleStore,
            rawStore: rawStore,
            eventLogger: nil
        )

        let packet = Packet(
            timestamp: Date(),
            from: AX25Address(call: "N0CALL"),
            to: AX25Address(call: "DEST"),
            frameType: .ui,
            control: 0x03,
            info: Data([0x41]),
            rawAx25: Data([0x01])
        )

        client.handleIncomingPacket(packet)
        client.handleIncomingData(Data([0x01, 0x02, 0x03]))

        XCTAssertEqual(client.packets.count, 1)
        await waitForStore(store)
        XCTAssertEqual(store.savedPackets.count, 0)
        XCTAssertEqual(consoleStore.appendedEntries.count, 0)
        XCTAssertEqual(rawStore.appendedEntries.count, 0)
    }

    func testConnectInvalidPortLogsEvent() {
        let settings = makeSettings(persistHistory: true)
        let eventLogger = MockEventLogger()
        let client = KISSTcpClient(
            maxPackets: 1,
            maxConsoleLines: 1,
            maxRawChunks: 1,
            settings: settings,
            packetStore: nil,
            consoleStore: nil,
            rawStore: nil,
            eventLogger: eventLogger
        )

        client.connect(host: "localhost", port: 0)

        XCTAssertTrue(eventLogger.entries.contains(where: { $0.0 == .error && $0.1 == .connection }))
    }

    private func makeSettings(persistHistory: Bool) -> AppSettingsStore {
        let suiteName = "AXTermTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.set(persistHistory, forKey: AppSettingsStore.persistKey)
        return AppSettingsStore(defaults: defaults)
    }

    private func waitForStore(_ store: MockPacketStore) async {
        for _ in 0..<10 {
            if !store.savedPackets.isEmpty || !store.pruneCalls.isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitForConsoleStore(_ store: MockConsoleStore) async {
        for _ in 0..<10 {
            if !store.appendedEntries.isEmpty || !store.pruneCalls.isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitForRawStore(_ store: MockRawStore) async {
        for _ in 0..<10 {
            if !store.appendedEntries.isEmpty || !store.pruneCalls.isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
