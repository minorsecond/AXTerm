//
//  NetRomAPRSPollutionTests.swift
//  AXTermTests
//
//  What the routing table may learn from, and what it may promise on the air.
//

import XCTest
@testable import AXTerm

/// Three faults that together put APRS stations into NET/ROM NODES broadcasts
/// on a packet frequency, observed on the air 2026-09-17:
///
/// 1. the next hop was read from the last repeated via entry, which for a
///    digipeated APRS frame is the alias the digi consumed, not the digi;
/// 2. a digipeated beacon was accepted as evidence of a routable path;
/// 3. the broadcast advertised routes belonging to every radio, not the one
///    it was going out on.
@MainActor
final class NetRomAPRSPollutionTests: XCTestCase {

    private let localCallsign = "N0CALL"

    private func makeRouter() -> NetRomRouter { NetRomRouter(localCallsign: localCallsign) }

    private func makeInference(router: NetRomRouter) -> NetRomPassiveInference {
        NetRomPassiveInference(
            router: router,
            localCallsign: localCallsign,
            config: NetRomInferenceConfig(
                evidenceWindowSeconds: 600,
                inferredRouteHalfLifeSeconds: 600,
                inferredBaseQuality: 60,
                reinforcementIncrement: 30,
                inferredMinimumQuality: 20,
                maxInferredRoutesPerDestination: 2,
                dataProgressWeight: 1.0,
                routingBroadcastWeight: 0.8,
                uiBeaconWeight: 0.4,
                ackOnlyWeight: 0.1,
                retryPenaltyMultiplier: 0.7
            )
        )
    }

    /// `via` entries as they arrive: repeated ones carry the H bit.
    private func makePacket(from: String, to: String,
                            via: [(String, Bool)],
                            frameType: FrameType,
                            control: UInt8,
                            info: String,
                            timestamp: Date) -> Packet {
        let data = info.data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0.0, repeated: $0.1) },
            frameType: frameType,
            control: control,
            controlByte1: nil,
            pid: 0xF0,
            info: data,
            rawAx25: data,
            kissEndpoint: nil,
            infoText: info
        )
    }

    // MARK: - The next hop is the station, not the alias

    /// A NET/ROM broadcast repeated by a real node through a fill-in digi.
    /// `WQ8M-9*,WIDE1*` means WQ8M-9 keyed up and consumed the WIDE1-1 alias.
    /// The last repeated entry is the alias; the station is the one before it.
    func testTheNextHopIsTheDigipeaterRatherThanTheAliasItConsumed() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let t = Date(timeIntervalSince1970: 1_700_000_000)

        let packet = makePacket(
            from: "W0ARP-1", to: "NODES",
            via: [("WQ8M-9", true), ("WIDE1", true), ("WIDE2-1", false)],
            frameType: .ui, control: 0x03, info: "NODES", timestamp: t)
        inference.observePacket(packet, timestamp: t,
                                classification: .routingBroadcast,
                                duplicateStatus: .unique)

        let neighbours = router.currentNeighbors().map(\.call)
        XCTAssertFalse(neighbours.contains("WIDE1"),
                       "an alias is not a station and can never be a neighbour")
        let routes = router.currentRoutes()
        XCTAssertFalse(routes.contains { $0.origin == "WIDE1" },
                       "nothing may be routed through an alias")
        if let route = routes.first(where: { $0.destination == "W0ARP-1" }) {
            XCTAssertEqual(route.origin, "WQ8M-9",
                           "the station that actually keyed up is the next hop")
        }
    }

    /// A path of nothing but aliases leaves no station to point at, so the
    /// frame teaches nothing rather than teaching something invented.
    func testAPathOfOnlyAliasesInfersNothing() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let t = Date(timeIntervalSince1970: 1_700_000_000)

        let packet = makePacket(
            from: "W0ARP-1", to: "NODES",
            via: [("WIDE1", true), ("WIDE2-1", false)],
            frameType: .ui, control: 0x03, info: "NODES", timestamp: t)
        inference.observePacket(packet, timestamp: t,
                                classification: .routingBroadcast,
                                duplicateStatus: .unique)

        XCTAssertTrue(router.currentRoutes().isEmpty)
        XCTAssertTrue(router.currentNeighbors().isEmpty)
    }

    // MARK: - A beacon is not a routable path

    /// The case from the air: an APRS position report digipeated across the
    /// channel became a NET/ROM route, and was then advertised to the packet
    /// network as somewhere a circuit could be opened.
    func testADigipeatedAPRSBeaconCreatesNoRoute() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let t = Date(timeIntervalSince1970: 1_700_000_000)

        let packet = makePacket(
            from: "AC0VP-10", to: "APJYC1",
            via: [("WQ8M-9", true), ("WIDE1", true), ("WIDE2-1", false)],
            frameType: .ui, control: 0x03,
            info: "=3925.61NI10525.66W&PHG0080", timestamp: t)
        inference.observePacket(packet, timestamp: t,
                                classification: .uiBeacon,
                                duplicateStatus: .unique)

        XCTAssertTrue(router.currentRoutes().isEmpty,
                      "a tracker that beacons is not a station you can connect to")
        XCTAssertTrue(router.currentNeighbors().isEmpty)
    }

    /// And the thing that must keep working: a NODES broadcast is a UI frame
    /// too, and is exactly how node tables are supposed to be learned.
    func testANodeBroadcastStillTeachesTheTable() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let t = Date(timeIntervalSince1970: 1_700_000_000)

        let packet = makePacket(
            from: "W0ARP-1", to: "NODES",
            via: [("K0NTS-7", true)],
            frameType: .ui, control: 0x03, info: "NODES", timestamp: t)
        inference.observePacket(packet, timestamp: t,
                                classification: .routingBroadcast,
                                duplicateStatus: .unique)

        XCTAssertFalse(router.currentRoutes().isEmpty,
                       "routing broadcasts are the normal way a table fills")
    }

    // MARK: - A broadcast promises only what its own radio can reach

    private func route(_ destination: String, via origin: String,
                       radio: RadioID, now: Date) -> RouteInfo {
        RouteInfo(destination: destination, origin: origin, quality: 120,
                  path: [origin, destination], lastUpdated: now,
                  sourceType: "inferred", radioID: radio)
    }

    private func neighbour(_ call: String, radio: RadioID, now: Date) -> NeighborInfo {
        NeighborInfo(call: call, quality: 200, lastSeen: now,
                     obsolescenceCount: 6, sourceType: "classic",
                     isOfficial: true, radioID: radio)
    }

    func testRoutesOnAnotherRadioAreNotAdvertised() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let packet = RadioID(rawValue: "packet")
        let aprs = RadioID(rawValue: "aprs")

        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("W0ARP-1", via: "K0NTS-7", radio: packet, now: now),
                     route("AC0VP-10", via: "WQ8M-9", radio: aprs, now: now)],
            neighbors: [neighbour("K0NTS-7", radio: packet, now: now),
                        neighbour("WQ8M-9", radio: aprs, now: now)],
            now: now,
            radio: packet)

        let advertised = decision.advertisable.map(\.destination)
        XCTAssertTrue(advertised.contains("W0ARP-1"))
        XCTAssertFalse(advertised.contains("AC0VP-10"),
                       "another antenna's reach is not this channel's to promise")
    }

    /// A neighbour on one radio cannot vouch for a route on another.
    func testANeighbourOnAnotherRadioCannotVouchForARoute() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let packet = RadioID(rawValue: "packet")
        let aprs = RadioID(rawValue: "aprs")

        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("SOMEWHERE", via: "WQ8M-9", radio: packet, now: now)],
            neighbors: [neighbour("WQ8M-9", radio: aprs, now: now)],
            now: now,
            radio: packet)

        XCTAssertTrue(decision.advertisable.isEmpty)
        XCTAssertFalse(decision.withheld.isEmpty, "and it says why")
    }
}
