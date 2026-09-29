import XCTest
@testable import AXTerm

/// Tests for the seam between the NET/ROM transport and real AX.25
/// links: next-hop selection from the route table, neighbor pinning,
/// the one-datagram-one-I-frame rule, and what a dropped link means.
final class NetRomLinkDriverTests: XCTestCase {

    private let node = AX25Address(call: "K0EPI", ssid: 7)
    private let cosco = AX25Address(call: "COSCO", ssid: 0)
    private let drlnod = AX25Address(call: "DRLNOD", ssid: 0)
    private let horse = AX25Address(call: "HORSE", ssid: 0)

    /// Records everything the driver asks of the AX.25 layer.
    private nonisolated final class FakeTransport: NetRomLinkTransport {
        var capacityByNeighbor: [String: Int] = [:]
        var defaultCapacity: Int? = 128
        var accept = true
        var sent: [(data: Data, neighbor: AX25Address)] = []

        func datagramCapacity(toNeighbor neighbor: AX25Address) -> Int? {
            capacityByNeighbor[neighbor.display] ?? defaultCapacity
        }
        func sendDatagram(_ data: Data, toNeighbor neighbor: AX25Address) -> Bool {
            guard accept else { return false }
            sent.append((data, neighbor))
            return true
        }
        var broadcasts: [Data] = []
        var broadcastSummaries: [String] = []
        func sendNodesBroadcast(_ payload: Data, summary: String) -> Bool {
            guard accept else { return false }
            broadcasts.append(payload)
            broadcastSummaries.append(summary)
            return true
        }
        var sentDatagrams: [NetRomDatagram] {
            sent.compactMap { NetRomTransportWire.parse($0.data) }
        }
    }

    private func makeDriver(
        routes: [String: String] = ["COSCO": "DRLNOD"],
        transport: FakeTransport = FakeTransport()
    ) -> (NetRomLinkDriver, FakeTransport, NetRomEndpointTests.TestScheduler) {
        let scheduler = NetRomEndpointTests.TestScheduler()
        let driver = NetRomLinkDriver(
            localNode: node, localUser: node,
            transport: transport,
            scheduler: scheduler
        )
        driver.nextHopResolver = { routes[$0.uppercased()] }
        return (driver, transport, scheduler)
    }

    // MARK: - Next hop from the route table

    func testOpenUsesRouteTableNextHop() {
        let (driver, transport, _) = makeDriver()
        guard case .success = driver.openCircuit(to: cosco) else {
            return XCTFail("expected the circuit to open")
        }
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].neighbor, drlnod,
                       "the CONREQ rides the link to the next hop, not to COSCO")
        guard let datagram = transport.sentDatagrams.first else {
            return XCTFail("CONREQ should parse")
        }
        XCTAssertEqual(datagram.destination, cosco,
                       "…but it is addressed, at layer 3, to COSCO")
        XCTAssertEqual(datagram.origin, node)
        guard case .connectRequest = datagram.transport else {
            return XCTFail("expected CONREQ, got \(datagram.transport)")
        }
    }

    func testUnknownDestinationDoesNotTransmit() {
        let (driver, transport, _) = makeDriver(routes: [:])
        guard case let .failure(reason) = driver.openCircuit(to: cosco) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(reason, .noRoute("COSCO"))
        XCTAssertTrue(transport.sent.isEmpty, "nothing goes on the air without a route")
        XCTAssertTrue(driver.circuits.isEmpty)
    }

    func testUnusableNeighborDoesNotTransmit() {
        let transport = FakeTransport()
        transport.defaultCapacity = nil
        let (driver, _, _) = makeDriver(transport: transport)
        guard case let .failure(reason) = driver.openCircuit(to: cosco) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(reason, .neighborUnusable("DRLNOD"))
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testDirectNeighborDestinationNeedsNoRelayWording() {
        var notes: [String] = []
        let (driver, _, _) = makeDriver(routes: ["DRLNOD": "DRLNOD"])
        driver.onOperatorNote = { notes.append($0) }
        _ = driver.openCircuit(to: drlnod)
        XCTAssertEqual(notes.first, "Opening a NET/ROM circuit to DRLNOD.",
                       "no 'through X' when X is the destination")
    }

    func testRelayWordingNamesTheHop() {
        var notes: [String] = []
        let (driver, _, _) = makeDriver()
        driver.onOperatorNote = { notes.append($0) }
        _ = driver.openCircuit(to: cosco)
        XCTAssertEqual(notes.first?.contains("through DRLNOD"), true)
    }

    // MARK: - Neighbor pinning

    func testNeighborIsPinnedForTheCircuitLifetime() {
        var routes = ["COSCO": "DRLNOD"]
        let transport = FakeTransport()
        let scheduler = NetRomEndpointTests.TestScheduler()
        let driver = NetRomLinkDriver(
            localNode: node, localUser: node, transport: transport, scheduler: scheduler)
        driver.nextHopResolver = { routes[$0.uppercased()] }

        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        // The route table re-ranks mid-circuit — a real thing, since
        // quality decays continuously.
        routes["COSCO"] = "HORSE"
        establish(driver: driver, transport: transport, destination: cosco)
        driver.send(Data("HELLO".utf8), on: driver.circuits[0].id)

        let neighbors = Set(transport.sent.map { $0.neighbor.display })
        XCTAssertEqual(neighbors, ["DRLNOD"],
                       "a circuit does not change hop mid-stream; its sequence state lives at DRLNOD")
    }

    func testInboundPinsTheReplyPathToWhereItArrived() {
        // A node reaches us through HORSE even though our own table
        // would send traffic to it via DRLNOD. Replies must go back the
        // way the traffic came.
        let (driver, transport, _) = makeDriver(routes: ["COSCO": "DRLNOD"])
        driver.endpoint.inboundAcceptor = { _, _ in true }

        let conreq = NetRomTransportWire.encode(NetRomDatagram(
            origin: cosco, destination: node, ttl: 25,
            transport: .connectRequest(myIndex: 5, myId: 6, proposedWindow: 4,
                                       user: cosco, originNode: cosco, t1Seconds: nil)))
        driver.handleInboundDatagram(conreq, fromNeighbor: horse)

        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].neighbor, horse,
                       "the CONACK returns via HORSE, not via the route table's DRLNOD")
    }

    // MARK: - One datagram, one I-frame

    func testFragmentSizeFollowsTheNeighborPaclen() {
        let transport = FakeTransport()
        transport.capacityByNeighbor["DRLNOD"] = 128
        let (driver, _, _) = makeDriver(transport: transport)
        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        establish(driver: driver, transport: transport, destination: cosco)

        driver.send(Data(repeating: 0x41, count: 400), on: driver.circuits[0].id)

        let infoSizes = transport.sent.map { $0.data.count }.filter { $0 > 20 }
        XCTAssertFalse(infoSizes.isEmpty, "data should have gone out")
        for size in infoSizes {
            XCTAssertLessThanOrEqual(size, 128,
                                     "no datagram may exceed the link's frame size")
        }
    }

    func testDegradedPaclenStillNeverSplitsADatagram() {
        // Your own logs show adaptive collapsing paclen to 64 under
        // loss. A 236-byte NET/ROM payload would then span two I-frames
        // and decode as garbage — so fragments must size to 64, not 236.
        let transport = FakeTransport()
        transport.capacityByNeighbor["DRLNOD"] = 64
        let (driver, _, _) = makeDriver(transport: transport)
        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        establish(driver: driver, transport: transport, destination: cosco)

        driver.send(Data(repeating: 0x42, count: 300), on: driver.circuits[0].id)
        for sent in transport.sent {
            XCTAssertLessThanOrEqual(sent.data.count, 64,
                                     "every datagram fits one 64-byte I-frame")
            XCTAssertNotNil(NetRomTransportWire.parse(sent.data),
                            "and each one is a whole, parseable datagram")
        }
    }

    func testOversizedDatagramIsRefusedNotSplit() {
        // The backstop: if capacity shrinks below what a circuit was
        // sized for, the datagram is refused and the circuit fails
        // loudly rather than putting a split datagram on the air.
        let transport = FakeTransport()
        transport.capacityByNeighbor["DRLNOD"] = 256
        let (driver, _, _) = makeDriver(transport: transport)
        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        establish(driver: driver, transport: transport, destination: cosco)
        let id = driver.circuits[0].id

        transport.capacityByNeighbor["DRLNOD"] = 30  // link degraded hard
        transport.sent.removeAll()
        driver.send(Data(repeating: 0x43, count: 200), on: id)

        XCTAssertTrue(transport.sent.isEmpty, "nothing oversized goes on the air")
        XCTAssertTrue(driver.circuits.isEmpty, "the circuit fails instead")
    }

    // MARK: - Link failure

    func testDroppedNeighborLinkFailsItsCircuits() {
        var notes: [String] = []
        let (driver, transport, _) = makeDriver(
            routes: ["COSCO": "DRLNOD", "KB5YZB-7": "HORSE"])
        driver.onOperatorNote = { notes.append($0) }
        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        guard case .success = driver.openCircuit(to: AX25Address(call: "KB5YZB", ssid: 7)) else {
            return XCTFail("open second")
        }
        XCTAssertEqual(driver.circuits.count, 2)
        _ = transport

        driver.neighborLinkDropped(drlnod)

        XCTAssertEqual(driver.circuits.count, 1, "only the DRLNOD circuit dies")
        XCTAssertEqual(driver.circuits[0].neighbor, horse)
        XCTAssertTrue(notes.contains { $0.contains("COSCO") && $0.contains("Could not carry") },
                      "and the operator is told which one and why: \(notes)")
    }

    func testDroppedUnrelatedNeighborChangesNothing() {
        let (driver, _, _) = makeDriver()
        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        driver.neighborLinkDropped(horse)
        XCTAssertEqual(driver.circuits.count, 1)
    }

    func testRefusedTransmitFailsTheCircuit() {
        let transport = FakeTransport()
        transport.accept = false
        let (driver, _, _) = makeDriver(transport: transport)
        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        XCTAssertTrue(driver.circuits.isEmpty,
                      "a CONREQ the link layer will not take fails the circuit at once")
    }

    // MARK: - Alias resolution on the air

    func testCircuitToAnAliasAddressesTheCallsign() {
        // The operator clicks COSCO on the Routes page; the L3 header
        // must carry KE0GB-7, which is what NET/ROM routes on.
        let (driver, transport, _) = makeDriver(routes: ["KE0GB-7": "DRLNOD"])
        driver.callsignForAliasResolver = { $0 == "COSCO" ? "KE0GB-7" : nil }

        guard case .success = driver.openCircuit(to: AX25Address(call: "COSCO", ssid: 0)) else {
            return XCTFail("expected the circuit to open")
        }
        guard let datagram = transport.sentDatagrams.first else { return XCTFail("no CONREQ") }
        XCTAssertEqual(datagram.destination.display, "KE0GB-7",
                       "the alias never reaches the address field")
        XCTAssertEqual(transport.sent[0].neighbor, drlnod)
    }

    func testAliasCircuitStillReadsAsTheNameTheOperatorUsed() {
        let (driver, _, _) = makeDriver(routes: ["KE0GB-7": "DRLNOD"])
        driver.callsignForAliasResolver = { $0 == "COSCO" ? "KE0GB-7" : nil }
        _ = driver.openCircuit(to: AX25Address(call: "COSCO", ssid: 0))

        XCTAssertEqual(driver.circuits.first?.displayName, "COSCO (KE0GB-7)")
        XCTAssertEqual(driver.circuits.first?.statusLine,
                       "Asking DRLNOD to reach COSCO (KE0GB-7)…")
    }

    func testARouteLearnedUnderTheAliasIsStillFound() {
        // The route table is keyed by whatever the broadcast said. After
        // resolving to a callsign we must still find a route stored under
        // the alias, or resolution would break connections that worked.
        let (driver, transport, _) = makeDriver(routes: ["COSCO": "DRLNOD"])
        driver.callsignForAliasResolver = { $0 == "COSCO" ? "KE0GB-7" : nil }

        guard case .success = driver.openCircuit(to: AX25Address(call: "COSCO", ssid: 0)) else {
            return XCTFail("a route under the alias must still be usable")
        }
        XCTAssertEqual(transport.sent.first?.neighbor, drlnod)
        XCTAssertEqual(transport.sentDatagrams.first?.destination.display, "KE0GB-7")
    }

    func testUnknownAliasIsStillDialledAsNamed() {
        // DRLNOD answers a SABM sent to "DRLNOD"; refusing unresolvable
        // names would break what works on this network today. Six
        // characters, because that is all an AX.25 address field holds —
        // which is also why NET/ROM aliases are six characters.
        let (driver, transport, _) = makeDriver(routes: ["MYSTRY": "DRLNOD"])
        driver.callsignForAliasResolver = { _ in nil }
        guard case .success = driver.openCircuit(to: AX25Address(call: "MYSTRY", ssid: 0)) else {
            return XCTFail("expected the circuit to open anyway")
        }
        XCTAssertEqual(transport.sentDatagrams.first?.destination.display, "MYSTRY")
    }

    func testAutoTryResolvesTheAliasToo() {
        let (driver, transport, _) = makeDriver(routes: [:])
        driver.callsignForAliasResolver = { $0 == "COSCO" ? "KE0GB-7" : nil }
        driver.candidateHopsResolver = { $0 == "KE0GB-7" ? ["DRLNOD", "HORSE"] : [] }

        guard case .success = driver.autoConnect(to: AX25Address(call: "COSCO", ssid: 0)) else {
            return XCTFail("expected an attempt")
        }
        XCTAssertEqual(transport.sentDatagrams.first?.destination.display, "KE0GB-7")
    }

    func testForwardingResolvesAliasKeyedRoutes() {
        // A transit datagram carries a callsign; our route to it may have
        // been learned under the alias.
        let (driver, transport, _) = makeDriver(routes: ["COSCO": "DRLNOD"])
        driver.forwardingEnabled = true
        driver.callsignForAliasResolver = { $0 == "COSCO" ? "KE0GB-7" : nil }

        let datagram = NetRomTransportWire.encode(NetRomDatagram(
            origin: AX25Address(call: "W0ARP", ssid: 10),
            destination: AX25Address(call: "COSCO", ssid: 0), ttl: 25,
            transport: .disconnectRequest(yourIndex: 1, yourId: 1)))
        driver.handleInboundDatagram(datagram, fromNeighbor: horse)

        XCTAssertEqual(transport.sent.count, 1, "the alias-keyed route must still be found")
        XCTAssertEqual(transport.sent[0].neighbor, drlnod)
    }

    // MARK: - Announcing this station

    func testNothingIsAnnouncedByDefault() {
        let (driver, transport, _) = makeDriver()
        driver.localAlias = "EPINOD"
        XCTAssertEqual(driver.broadcastNodes(), 0,
                       "announcing writes this station into other operators' tables; "
                       + "it must be opted into")
        XCTAssertTrue(transport.broadcasts.isEmpty)
    }

    func testAnnouncingAdvertisesOnlyOurselvesWithoutForwarding() {
        let (driver, transport, _) = makeDriver()
        driver.localAlias = "EPINOD"
        driver.advertisesItself = true
        driver.advertisableRoutesProvider = {
            [NetRomNodesBroadcast.KnownRoute(
                destination: self.cosco, alias: "COSCO",
                nextHop: self.drlnod, quality: 200)]
        }

        XCTAssertEqual(driver.broadcastNodes(), 1)
        guard let payload = transport.broadcasts.first else { return XCTFail("no broadcast") }
        // One entry: ourselves. We will not carry COSCO, so we do not
        // claim it.
        let entryBytes = payload.count - 1 - NetRomNodesBroadcast.aliasLength
        XCTAssertEqual(entryBytes / NetRomNodesBroadcast.entryLength, 1)
    }

    func testForwardingStationAdvertisesWhatItWillCarry() {
        let (driver, transport, _) = makeDriver()
        driver.localAlias = "EPINOD"
        driver.advertisesItself = true
        driver.forwardingEnabled = true
        driver.advertisableRoutesProvider = {
            // COSCO is an alias; the callsign behind it is KE0GB-7, and
            // the wire field is a callsign.
            [NetRomNodesBroadcast.KnownRoute(
                destination: AX25Address(call: "KE0GB", ssid: 7), alias: "COSCO",
                nextHop: self.drlnod, quality: 200)]
        }

        XCTAssertEqual(driver.broadcastNodes(), 1)
        guard let payload = transport.broadcasts.first else { return XCTFail("no broadcast") }
        let entryBytes = payload.count - 1 - NetRomNodesBroadcast.aliasLength
        XCTAssertEqual(entryBytes / NetRomNodesBroadcast.entryLength, 2,
                       "ourselves plus the route we will actually forward")
    }

    // MARK: - Transit routing

    func testTransitDatagramIsDroppedWhenNotARouter() {
        let (driver, transport, _) = makeDriver(routes: ["COSCO": "DRLNOD"])
        let datagram = NetRomTransportWire.encode(NetRomDatagram(
            origin: AX25Address(call: "W0ARP", ssid: 10),
            destination: cosco, ttl: 25,
            transport: .disconnectRequest(yourIndex: 1, yourId: 1)))
        driver.handleInboundDatagram(datagram, fromNeighbor: horse)
        XCTAssertTrue(transport.sent.isEmpty, "forwarding is off by default")
    }

    func testTransitDatagramIsForwardedWhenEnabled() {
        let (driver, transport, _) = makeDriver(routes: ["COSCO": "DRLNOD"])
        driver.forwardingEnabled = true
        let datagram = NetRomTransportWire.encode(NetRomDatagram(
            origin: AX25Address(call: "W0ARP", ssid: 10),
            destination: cosco, ttl: 25,
            transport: .disconnectRequest(yourIndex: 1, yourId: 1)))
        driver.handleInboundDatagram(datagram, fromNeighbor: horse)

        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].neighbor, drlnod)
        guard let forwarded = NetRomTransportWire.parse(transport.sent[0].data) else {
            return XCTFail("forwarded datagram should parse")
        }
        XCTAssertEqual(forwarded.ttl, 24)
        XCTAssertEqual(forwarded.destination, cosco)
        XCTAssertEqual(forwarded.origin.display, "W0ARP-10",
                       "we are transit; the origin stays the original sender")
    }

    func testTransitDatagramTooBigForTheNextHopIsDropped() {
        let transport = FakeTransport()
        transport.capacityByNeighbor["DRLNOD"] = 30
        let (driver, _, _) = makeDriver(routes: ["COSCO": "DRLNOD"], transport: transport)
        driver.forwardingEnabled = true
        let datagram = NetRomTransportWire.encode(NetRomDatagram(
            origin: AX25Address(call: "W0ARP", ssid: 10),
            destination: cosco, ttl: 25,
            transport: .information(yourIndex: 1, yourId: 1, txSeq: 0, rxSeq: 0,
                                    choke: false, nak: false, moreFollows: false,
                                    payload: Data(repeating: 0x41, count: 200))))
        driver.handleInboundDatagram(datagram, fromNeighbor: horse)
        XCTAssertTrue(transport.sent.isEmpty,
                      "a datagram that would have to be split is dropped, not fragmented")
    }

    // MARK: - Auto-try

    func testAutoConnectUsesTheBestHopFirst() {
        let (driver, transport, _) = makeDriver()
        driver.candidateHopsResolver = { _ in ["DRLNOD", "HORSE"] }
        guard case .success = driver.autoConnect(to: cosco) else {
            return XCTFail("expected an attempt")
        }
        XCTAssertEqual(transport.sent.first?.neighbor, drlnod)
    }

    func testAutoConnectFallsThroughToTheSecondHopOnTimeout() {
        let (driver, transport, _) = makeDriver()
        var notes: [String] = []
        driver.onOperatorNote = { notes.append($0) }
        driver.candidateHopsResolver = { _ in ["DRLNOD", "HORSE"] }
        guard case .success = driver.autoConnect(to: cosco) else { return XCTFail("open") }
        XCTAssertEqual(transport.sent.first?.neighbor, drlnod)

        // DRLNOD never answers: N2 exhausts on the circuit.
        failActiveCircuit(driver, timesOut: true)

        XCTAssertEqual(transport.sent.last?.neighbor, horse,
                       "the second-best route is tried automatically")
        XCTAssertTrue(notes.contains { $0.contains("Trying the next route") },
                      "and the operator is told why: \(notes)")
    }

    func testAutoConnectStopsWhenTheStationRefuses() {
        let (driver, transport, _) = makeDriver()
        var notes: [String] = []
        driver.onOperatorNote = { notes.append($0) }
        driver.candidateHopsResolver = { _ in ["DRLNOD", "HORSE"] }
        guard case .success = driver.autoConnect(to: cosco) else { return XCTFail("open") }
        let before = transport.sent.count

        refuseActiveCircuit(driver)

        XCTAssertEqual(transport.sent.count, before,
                       "a station that answered 'no' must not be retried through another hop")
        XCTAssertTrue(notes.contains { $0.contains("refused") }, "\(notes)")
    }

    func testAutoConnectReportsWhenEveryRouteIsSpent() {
        let (driver, _, _) = makeDriver()
        var notes: [String] = []
        driver.onOperatorNote = { notes.append($0) }
        driver.candidateHopsResolver = { _ in ["DRLNOD", "HORSE"] }
        guard case .success = driver.autoConnect(to: cosco) else { return XCTFail("open") }
        failActiveCircuit(driver, timesOut: true)   // DRLNOD gives up
        failActiveCircuit(driver, timesOut: true)   // HORSE gives up

        XCTAssertTrue(driver.circuits.isEmpty)
        XCTAssertTrue(notes.contains { $0.contains("Tried DRLNOD, HORSE") },
                      "the summary names every route attempted: \(notes)")
    }

    func testAutoConnectWithNoRoutesTransmitsNothing() {
        let (driver, transport, _) = makeDriver(routes: [:])
        driver.candidateHopsResolver = { _ in [] }
        guard case let .failure(reason) = driver.autoConnect(to: cosco) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(reason, .noRoute("COSCO"))
        XCTAssertTrue(transport.sent.isEmpty)
    }

    /// Drive the live circuit to a failure the way the network would.
    private func failActiveCircuit(_ driver: NetRomLinkDriver, timesOut: Bool) {
        guard let summary = driver.circuits.first else { return }
        driver.endpoint.failCircuit(summary.id, reason: "link down")
    }

    private func refuseActiveCircuit(_ driver: NetRomLinkDriver) {
        guard let summary = driver.circuits.first,
              let box = driver.endpoint.circuits[summary.id] else { return }
        let refusal = NetRomDatagram(
            origin: summary.destination, destination: node, ttl: 25,
            transport: .connectAck(yourIndex: box.machine.myIndex, yourId: box.machine.myId,
                                   myIndex: 0, myId: 0,
                                   acceptedWindow: 0, ttl: nil, refused: true))
        driver.handleInboundDatagram(NetRomTransportWire.encode(refusal),
                                     fromNeighbor: summary.neighbor)
    }

    // MARK: - Observable state for the Terminal

    func testCircuitSummaryReadsAsPlainEnglish() {
        let (driver, transport, _) = makeDriver()
        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        XCTAssertEqual(driver.circuits[0].state, .connecting)
        XCTAssertEqual(driver.circuits[0].statusLine,
                       "Asking DRLNOD to reach COSCO…")

        establish(driver: driver, transport: transport, destination: cosco)
        XCTAssertEqual(driver.circuits[0].state, .connected)
        XCTAssertEqual(driver.circuits[0].statusLine,
                       "Circuit to COSCO through DRLNOD")
    }

    func testDeliveredDataSurfacesOnItsCircuit() {
        let (driver, transport, _) = makeDriver()
        var received: [Data] = []
        driver.onCircuitData = { _, data in received.append(data) }
        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        let handle = establish(driver: driver, transport: transport, destination: cosco)

        let info = NetRomTransportWire.encode(NetRomDatagram(
            origin: cosco, destination: node, ttl: 25,
            transport: .information(yourIndex: handle.index, yourId: handle.id,
                                    txSeq: 0, rxSeq: 0,
                                    choke: false, nak: false, moreFollows: false,
                                    payload: Data("Welcome to COSCO".utf8))))
        driver.handleInboundDatagram(info, fromNeighbor: drlnod)
        XCTAssertEqual(received, [Data("Welcome to COSCO".utf8)])
    }

    func testCircuitDisappearsFromTheListWhenClosed() {
        let (driver, transport, _) = makeDriver()
        guard case .success = driver.openCircuit(to: cosco) else { return XCTFail("open") }
        let handle = establish(driver: driver, transport: transport, destination: cosco)
        driver.disconnect(driver.circuits[0].id)
        XCTAssertEqual(driver.circuits.first?.state, .disconnecting)

        let discack = NetRomTransportWire.encode(NetRomDatagram(
            origin: cosco, destination: node, ttl: 25,
            transport: .disconnectAck(yourIndex: handle.index, yourId: handle.id)))
        driver.handleInboundDatagram(discack, fromNeighbor: drlnod)
        XCTAssertTrue(driver.circuits.isEmpty)
    }

    // MARK: - Helpers

    /// Answer the CONREQ the driver just sent, so the circuit comes up.
    /// Returns our own handle, which the peer echoes on later frames.
    @discardableResult
    private func establish(driver: NetRomLinkDriver,
                           transport: FakeTransport,
                           destination: AX25Address,
                           file: StaticString = #filePath, line: UInt = #line)
    -> (index: UInt8, id: UInt8) {
        guard let conreq = transport.sentDatagrams.last,
              case let .connectRequest(myIndex, myId, _, _, _, _) = conreq.transport else {
            XCTFail("no CONREQ to answer", file: file, line: line)
            return (0, 0)
        }
        let conack = NetRomTransportWire.encode(NetRomDatagram(
            origin: destination, destination: node, ttl: 25,
            transport: .connectAck(yourIndex: myIndex, yourId: myId,
                                   myIndex: 0x33, myId: 0x44,
                                   acceptedWindow: 4, ttl: nil, refused: false)))
        driver.handleInboundDatagram(conack, fromNeighbor: drlnod)
        return (myIndex, myId)
    }

    // MARK: - Saying what went out

    /// The console could only ever report that a broadcast happened. The
    /// same sentence covered a frame with one entry and a frame with
    /// eleven, and the operator had no way to tell which had just left the
    /// antenna (2026-08-27).
    func testSummaryNamesTheStationWhenThereAreNoRoutes() {
        let entries = [NetRomNodesBroadcast.Entry(
            destination: AX25Address(call: "K0EPI", ssid: 7), alias: "EPINOD",
            bestNeighbor: AX25Address(call: "K0EPI", ssid: 7), quality: 255)]
        XCTAssertEqual(NetRomLinkDriver.summarize(alias: "EPINOD", entries: entries),
                       "this station as EPINOD")
    }

    func testSummaryNamesTheRoutesBeingPromised() {
        let entries = [
            NetRomNodesBroadcast.Entry(
                destination: AX25Address(call: "K0EPI", ssid: 7), alias: "EPINOD",
                bestNeighbor: AX25Address(call: "K0EPI", ssid: 7), quality: 255),
            NetRomNodesBroadcast.Entry(
                destination: AX25Address(call: "KB5YZB", ssid: 1), alias: "YZBBBS",
                bestNeighbor: AX25Address(call: "DRLNOD", ssid: 0), quality: 23)
        ]
        XCTAssertEqual(NetRomLinkDriver.summarize(alias: "EPINOD", entries: entries),
                       "this station as EPINOD, and routes to YZBBBS")
    }

    /// A blank alias is what a station announces before the operator has
    /// set one, and it is worth saying out loud rather than printing a gap.
    func testSummarySaysWhenNoAliasIsSet() {
        let entries = [NetRomNodesBroadcast.Entry(
            destination: AX25Address(call: "K0EPI", ssid: 7), alias: "",
            bestNeighbor: AX25Address(call: "K0EPI", ssid: 7), quality: 255)]
        XCTAssertEqual(NetRomLinkDriver.summarize(alias: "   ", entries: entries),
                       "this station (no alias set)")
    }

    func testSummaryTruncatesALongTable() {
        var entries = [NetRomNodesBroadcast.Entry(
            destination: AX25Address(call: "K0EPI", ssid: 7), alias: "EPINOD",
            bestNeighbor: AX25Address(call: "K0EPI", ssid: 7), quality: 255)]
        for index in 1...10 {
            entries.append(NetRomNodesBroadcast.Entry(
                destination: AX25Address(call: "DEST\(index)", ssid: 0), alias: "",
                bestNeighbor: AX25Address(call: "DRLNOD", ssid: 0), quality: 20))
        }
        let summary = NetRomLinkDriver.summarize(alias: "EPINOD", entries: entries)
        XCTAssertTrue(summary.hasSuffix("and 4 more"), summary)
    }
}
