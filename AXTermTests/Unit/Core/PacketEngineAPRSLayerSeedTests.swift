//
//  PacketEngineAPRSLayerSeedTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

/// The incident layer has to survive a restart.
///
/// Objects and NWS alerts were filed only as they arrived, and nothing
/// rebuilt them from the packet log, so every launch started the map empty.
/// A repeater object came back on its next beacon and hid it; a one-shot
/// hazard, or one whose sender had gone off the air, was gone for good.
@MainActor
final class PacketEngineAPRSLayerSeedTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_757_419_200)   // 091200z

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppSettingsStore(defaults: defaults)
    }

    private func packet(_ info: String, from: String, ssid: Int = 0,
                        at offset: TimeInterval) -> Packet {
        Packet(timestamp: epoch.addingTimeInterval(offset),
               from: AX25Address(call: from, ssid: ssid),
               to: AX25Address(call: "APRS"),
               frameType: .ui, control: 0x03, pid: 0xF0,
               info: Data(info.utf8), rawAx25: Data([0x01]))
    }

    private func objectInfo(_ name: String, live: Bool, at offset: TimeInterval) -> String {
        live
        ? APRSObjectReport.objectInfo(name: name, live: true, latitude: 39.6,
                                      longitude: -104.7, symbolTable: "/",
                                      symbolCode: "-", at: epoch.addingTimeInterval(offset))
        : APRSObjectReport.killInfo(name: name, latitude: 39.6, longitude: -104.7,
                                    symbolTable: "/", symbolCode: "-",
                                    at: epoch.addingTimeInterval(offset))
    }

    /// A hazard placed once, hours before launch, comes back from the log.
    func testAOneShotObjectIsRestoredFromStoredPackets() {
        let engine = PacketEngine(settings: makeSettings())
        XCTAssertTrue(engine.aprsObjects.placed.isEmpty, "starts empty, as after a launch")

        engine.seedAPRSLayersIfEmpty(from: [
            packet(objectInfo("WILDFIRE", live: true, at: 0), from: "W0FIRE", at: 0)
        ])

        let placed = engine.aprsObjects.placed.values
        XCTAssertEqual(placed.count, 1, "the object layer was rebuilt from history")
        XCTAssertEqual(placed.first?.reportedBy, "W0FIRE")
        XCTAssertEqual(placed.first?.heard, epoch,
                       "age runs from when it was heard, not from app start")
    }

    /// A BBS directory listing inside a connected-mode session begins with
    /// `)`, the APRS item DTI. 368 such I-frames are in the prod log. None
    /// parse today — measured against the real payloads — but a fabricated
    /// hazard on an emergency map is the worst output this app has, so the
    /// frame type is what keeps them out, not the name rules.
    func testConnectedModeTextIsNeverPlacedOnTheIncidentMap() {
        let engine = PacketEngine(settings: makeSettings())
        let bbs = Packet(timestamp: epoch,
                         from: AX25Address(call: "K0NTS", ssid: 10),
                         to: AX25Address(call: "K0EPI", ssid: 7),
                         frameType: .i, control: 0x00, pid: 0xF0,
                         info: Data(")  18536 free  (A,B,H,J,K,L,R,S,V,".utf8),
                         rawAx25: Data([0x01]))

        engine.handleIncomingPacket(bbs)
        engine.rebuildStations(from: [bbs])

        XCTAssertTrue(engine.aprsObjects.placed.isEmpty,
                      "session text must never become a hazard")
    }

    /// The wiring, which is where the bug actually was. `rebuildStations` runs
    /// at launch off the loaded log; testing the seed function alone would
    /// pass even while nothing called it.
    func testRebuildingStationsAlsoRebuildsTheIncidentLayer() {
        let engine = PacketEngine(settings: makeSettings())

        engine.rebuildStations(from: [
            packet(objectInfo("WILDFIRE", live: true, at: 0), from: "W0FIRE", at: 0)
        ])

        XCTAssertEqual(engine.aprsObjects.placed.count, 1,
                       "a launch rebuild must restore the incident layer, not just the stations")
    }

    /// Replay order is load-bearing: a kill must retire the placement before
    /// it, however the packets happen to come back off disk.
    func testAKillHeardLaterStaysDeadWhenPacketsReplayOutOfOrder() {
        let engine = PacketEngine(settings: makeSettings())
        let placement = packet(objectInfo("ROADCLOSE", live: true, at: 0),
                               from: "W0ROAD", at: 0)
        let kill = packet(objectInfo("ROADCLOSE", live: false, at: 600),
                          from: "W0ROAD", at: 600)

        // Newest first, the order a log read hands them back.
        engine.seedAPRSLayersIfEmpty(from: [kill, placement])

        XCTAssertTrue(engine.aprsObjects.placed.isEmpty,
                      "a stood-down hazard must not come back as live")
        XCTAssertEqual(engine.aprsObjects.killed.count, 1, "it is kept as stood down")
    }

    /// The guard that matters: a rebuild also fires on a radio reconnect, and
    /// `record` moves `heard` and bumps `timesHeard`. Replaying over live
    /// state would age a current hazard backwards and double-count it.
    func testSeedingDoesNotRunOverLiveState() {
        let engine = PacketEngine(settings: makeSettings())
        let old = packet(objectInfo("SHELTER", live: true, at: 0), from: "W0AID", at: 0)

        engine.seedAPRSLayersIfEmpty(from: [old])
        let firstHeard = engine.aprsObjects.placed.values.first?.heard
        XCTAssertEqual(firstHeard, epoch)

        // A fresher copy arrives live, then something triggers another rebuild.
        engine.handleIncomingPacket(
            packet(objectInfo("SHELTER", live: true, at: 7200), from: "W0AID", at: 7200))
        let live = try? XCTUnwrap(engine.aprsObjects.placed.values.first)
        XCTAssertEqual(live?.heard, epoch.addingTimeInterval(7200))

        engine.seedAPRSLayersIfEmpty(from: [old])

        let after = engine.aprsObjects.placed.values.first
        XCTAssertEqual(after?.heard, epoch.addingTimeInterval(7200),
                       "the replay must not drag a current object backwards in time")
        XCTAssertEqual(after?.timesHeard, live?.timesHeard,
                       "nor count the same repeat twice")
    }

    /// Our own objects never enter the packet log, so a seed that ran over a
    /// populated store would silently erase them.
    func testOurOwnPlacedObjectSurvivesALaterRebuild() {
        let engine = PacketEngine(settings: makeSettings())
        engine.recordOwnAPRSObject(objectInfo("OURAID", live: true, at: 0),
                                   from: "K0EPI-7", at: epoch)
        XCTAssertEqual(engine.aprsObjects.placed.count, 1)

        engine.seedAPRSLayersIfEmpty(from: [
            packet(objectInfo("WILDFIRE", live: true, at: 0), from: "W0FIRE", at: 0)
        ])

        XCTAssertNotNil(engine.aprsObjects.placed.values.first { $0.reportedBy == "K0EPI-7" },
                        "our own object must not be wiped by a rebuild")
    }
}
