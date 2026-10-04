//
//  NetRomIntegrationLifecycleTests.swift
//  AXTermTests
//
//  The NET/ROM engine exists as soon as the station has a callsign, not only
//  when it had one at launch.
//
//  Smoke run 2026-10-03-1, issue 37: the engine was built once, in
//  PacketEngine's init, and only if a callsign was already set. A station set
//  up through the first-run wizard gets its callsign after that, so it never
//  had one: every NODES broadcast and every inferred neighbor was dropped,
//  and Station A learned nothing about Station B while B learned A at once.
//

import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class NetRomIntegrationLifecycleTests: XCTestCase {

    /// B's NODES broadcast as Station A heard it on 2026-10-04 22:44:35Z:
    /// signature, alias EPINDB, one entry for K0EPI-3 via K0EPI-3.
    private let nodesFromB = Data([
        0xFF, 0x45, 0x50, 0x49, 0x4E, 0x44, 0x42,
        0x96, 0x60, 0x8A, 0xA0, 0x92, 0x40, 0x66, 0x45, 0x50, 0x49, 0x4E, 0x44, 0x42,
        0x96, 0x60, 0x8A, 0xA0, 0x92, 0x40, 0x66, 0xFF,
    ])

    private func makeEngine() throws -> (PacketEngine, AppSettingsStore) {
        let suite = TestDefaults.name("NetRomIntegrationLifecycleTests")
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let engine = PacketEngine(
            maxPackets: 100, maxConsoleLines: 100, maxRawChunks: 100,
            settings: settings,
            packetStore: SQLitePacketStore(dbQueue: queue),
            consoleStore: nil, rawStore: nil, eventLogger: nil,
            databaseWriter: queue)
        return (engine, settings)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    func testTheEngineAppearsWhenTheCallsignIsSetAfterLaunch() async throws {
        let (engine, settings) = try makeEngine()
        XCTAssertNil(engine.netRomIntegration, "no callsign yet, nothing to infer as")

        settings.adoptStationCallsign("K0EPI-2")
        await waitUntil("the NET/ROM engine") { engine.netRomIntegration != nil }

        engine.handleIncomingPacket(Packet(
            timestamp: Date(),
            from: AX25Address(call: "K0EPI", ssid: 3),
            to: AX25Address(call: "NODES"),
            frameType: .ui, control: 0x03, pid: 0xCF,
            info: nodesFromB, rawAx25: Data([0x01])))

        let neighbors = engine.netRomIntegration?.currentNeighbors().map(\.call) ?? []
        XCTAssertTrue(neighbors.contains("K0EPI-3"), "neighbors: \(neighbors)")
    }

    /// The engine compares full addresses, SSID included, against the
    /// station's own; it must follow a change instead of keeping the first.
    func testTheEngineFollowsACallsignChange() async throws {
        let (engine, settings) = try makeEngine()
        settings.adoptStationCallsign("K0EPI-2")
        await waitUntil("the NET/ROM engine") { engine.netRomIntegration != nil }

        // A new SSID on the radio's page, which is where the on-air call lives.
        let radioID = try XCTUnwrap(settings.radios.first?.id)
        settings.updateRadio(radioID) { $0.callsign = "K0EPI-5" }
        await waitUntil("the new callsign") { engine.netRomIntegration?.localCallsign == "K0EPI-5" }
    }
}
