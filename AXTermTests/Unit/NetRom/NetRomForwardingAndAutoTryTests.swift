import XCTest
@testable import AXTerm

/// Transit routing and auto-try — the two behaviors that can hurt other
/// people if they are wrong. Forwarding spends this station's airtime on
/// somebody else's packets and can loop them; auto-try decides when
/// retrying on the air is warranted and when it is nagging.
final class NetRomForwardingAndAutoTryTests: XCTestCase {

    private let localNode = AX25Address(call: "K0EPI", ssid: 7)
    private let cosco = AX25Address(call: "COSCO", ssid: 0)
    private let drlnod = AX25Address(call: "DRLNOD", ssid: 0)
    private let horse = AX25Address(call: "HORSE", ssid: 0)
    private let w0arp = AX25Address(call: "W0ARP", ssid: 10)

    private func transit(ttl: UInt8 = 25, destination: AX25Address? = nil) -> NetRomDatagram {
        NetRomDatagram(
            origin: w0arp,
            destination: destination ?? cosco,
            ttl: ttl,
            transport: .information(yourIndex: 1, yourId: 1, txSeq: 0, rxSeq: 0,
                                    choke: false, nak: false, moreFollows: false,
                                    payload: Data("transit".utf8))
        )
    }

    private func decide(_ datagram: NetRomDatagram,
                        from neighbor: AX25Address,
                        forwarding: Bool = true,
                        routes: [String: String] = ["COSCO": "DRLNOD"]) -> NetRomForwarding.Decision {
        NetRomForwarding.decide(
            datagram: datagram,
            arrivedFrom: neighbor,
            forwardingEnabled: forwarding,
            localNode: localNode,
            nextHop: { routes[$0.uppercased()] }
        )
    }

    // MARK: - Forwarding

    func testForwardingOffIsTheDefaultAndDropsTransit() {
        XCTAssertEqual(decide(transit(), from: horse, forwarding: false), .notARouter,
                       "a station that has not opted in is an endpoint, not a router")
    }

    func testForwardedDatagramGoesToTheNextHopWithTTLDecremented() {
        guard case let .forward(forwarded, neighbor) = decide(transit(ttl: 25), from: horse) else {
            return XCTFail("should forward")
        }
        XCTAssertEqual(neighbor, drlnod)
        XCTAssertEqual(forwarded.ttl, 24, "every hop costs one")
        XCTAssertEqual(forwarded.origin, w0arp, "the origin is not rewritten — we are transit")
        XCTAssertEqual(forwarded.destination, cosco)
        XCTAssertEqual(forwarded.transport, transit().transport, "the payload is untouched")
    }

    func testTTLOfOneIsTheLastHopAndIsDropped() {
        XCTAssertEqual(decide(transit(ttl: 1), from: horse), .ttlExpired,
                       "a datagram arriving with TTL 1 has spent its last hop getting here")
    }

    func testTTLCountsDownToExpiryAcrossRepeatedHops() {
        // Walk a datagram through this station repeatedly; it must die
        // rather than circulate forever.
        var datagram = transit(ttl: 4)
        var hops = 0
        while case let .forward(next, _) = decide(datagram, from: horse) {
            datagram = next
            hops += 1
            XCTAssertLessThan(hops, 10, "TTL must terminate the walk")
        }
        XCTAssertEqual(hops, 3, "TTL 4 yields three forwards, then expiry")
        XCTAssertEqual(decide(datagram, from: horse), .ttlExpired)
    }

    func testUnknownDestinationIsDroppedNotBroadcast() {
        XCTAssertEqual(decide(transit(destination: AX25Address(call: "NOWHERE", ssid: 0)),
                              from: horse),
                       .noRoute("NOWHERE"))
    }

    func testDatagramIsNeverSentBackDownTheLinkItArrivedOn() {
        // Our table says COSCO is via DRLNOD, and the datagram arrived
        // from DRLNOD. Bouncing it back is a loop.
        XCTAssertEqual(decide(transit(), from: drlnod), .wouldLoop("DRLNOD"))
    }

    func testDatagramIsNeverForwardedToOurselves() {
        XCTAssertEqual(decide(transit(), from: horse, routes: ["COSCO": "K0EPI-7"]),
                       .wouldLoop("K0EPI-7"))
    }

    // MARK: - Auto-try policy

    func testSilenceAndDeadLinksJustifyAnotherRoute() {
        XCTAssertEqual(NetRomAutoTryPolicy.verdict(for: .timedOut), .tryNext)
        XCTAssertEqual(NetRomAutoTryPolicy.verdict(for: .transportFailure("link down")), .tryNext)
    }

    func testARefusalStopsTheCampaign() {
        // The far node answered. Asking again through a different
        // neighbor is not persistence, it is nagging a station that
        // already said no.
        guard case let .stop(why) = NetRomAutoTryPolicy.verdict(for: .refused) else {
            return XCTFail("a refusal must end the campaign")
        }
        XCTAssertTrue(why.contains("refused"), why)
    }

    func testAnAnsweredThenClosedCircuitStopsTheCampaign() {
        for reason: NetRomDisconnectReason in [.remoteRequest, .localRequest, .reset,
                                               .protocolError("bad")] {
            guard case .stop = NetRomAutoTryPolicy.verdict(for: reason) else {
                return XCTFail("\(reason) must not trigger another attempt")
            }
        }
    }

    func testExhaustedTextNamesWhatWasTried() {
        XCTAssertTrue(NetRomAutoTryPolicy.exhaustedText(destination: "COSCO", attempted: [])
                        .contains("has not heard a node advertise it"))
        XCTAssertTrue(NetRomAutoTryPolicy.exhaustedText(destination: "COSCO", attempted: ["DRLNOD"])
                        .contains("no other way there"))
        let many = NetRomAutoTryPolicy.exhaustedText(
            destination: "COSCO", attempted: ["DRLNOD", "HORSE"])
        XCTAssertTrue(many.contains("DRLNOD, HORSE"), many)
    }

    // MARK: - Campaign bookkeeping

    func testCampaignWalksHopsInOrderThenRunsOut() {
        let campaign = NetRomAutoTryCampaign(destination: cosco, hops: [drlnod, horse])
        XCTAssertEqual(campaign.nextHop(), drlnod)
        XCTAssertEqual(campaign.nextHop(), horse)
        XCTAssertNil(campaign.nextHop())
        XCTAssertEqual(campaign.attemptedDisplay, ["DRLNOD", "HORSE"])
    }

    func testFinishedCampaignOffersNoMoreHops() {
        let campaign = NetRomAutoTryCampaign(destination: cosco, hops: [drlnod, horse])
        campaign.finish()
        XCTAssertNil(campaign.nextHop())
        XCTAssertTrue(campaign.isFinished)
        XCTAssertNil(campaign.activeCircuit)
    }
}
