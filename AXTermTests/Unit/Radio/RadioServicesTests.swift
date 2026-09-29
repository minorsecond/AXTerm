import XCTest
@testable import AXTerm

/// Station-wide services on a station with two radios: a probe leaves on
/// the radio that heard the station, a NODES broadcast leaves on every
/// announcing radio, and a node per radio answers as itself.
final class RadioServicesTests: XCTestCase {

    private let base = RadioID.primary
    private let uhf = RadioID(rawValue: "uhf")
    private let node = AX25Address(call: "K0EPI", ssid: 7)
    private let uhfNode = AX25Address(call: "K0EPI", ssid: 1)

    // MARK: - Ping

    func testAProbeLeavesOnTheRadioThatHeardTheStationAsThatRadiosCallsign() {
        let prober = PingProber(
            defaults: UserDefaults(suiteName: "RadioServicesTests.\(UUID().uuidString)")!)
        var sent: [OutboundFrame] = []
        prober.sendFrame = { frame in sent.append(frame); return true }
        prober.localAddress = { [uhf, uhfNode, node] radio in radio == uhf ? uhfNode : node }
        prober.candidateProvider = { [uhf] in
            [PingPolicy.Candidate(call: "K0NTS-1", source: .heardDirect, lastActivity: Date(), radio: uhf)]
        }

        prober.probeNow("K0NTS-1")

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.radio, uhf)
        XCTAssertEqual(sent.first?.source, uhfNode, "the probe is signed by the radio that asks")
    }

    func testAProbeOfAStationNobodyListedGoesOutOnThePrimary() {
        let prober = PingProber(
            defaults: UserDefaults(suiteName: "RadioServicesTests.\(UUID().uuidString)")!)
        var sent: [OutboundFrame] = []
        prober.sendFrame = { frame in sent.append(frame); return true }
        prober.localAddress = { [node] _ in node }

        prober.probeNow("W0ARP-10")

        XCTAssertEqual(sent.first?.radio, .primary)
    }

    // MARK: - NODES

    private nonisolated final class RadioTransport: NetRomLinkTransport {
        var broadcasts: [(payload: Data, summary: String, radio: RadioID)] = []
        func datagramCapacity(toNeighbor neighbor: AX25Address) -> Int? { 128 }
        func sendDatagram(_ data: Data, toNeighbor neighbor: AX25Address) -> Bool { true }
        func sendNodesBroadcast(_ payload: Data, summary: String) -> Bool {
            sendNodesBroadcast(payload, summary: summary, radio: .primary)
        }
        func sendNodesBroadcast(_ payload: Data, summary: String, radio: RadioID) -> Bool {
            broadcasts.append((payload, summary, radio))
            return true
        }
    }

    private func announcingDriver(_ transport: RadioTransport) -> (NetRomLinkDriver, [String]) {
        let driver = NetRomLinkDriver(localNode: node, localUser: node, transport: transport,
                                      scheduler: NetRomEndpointTests.TestScheduler())
        driver.localAlias = "EPINOD"
        driver.advertisesItself = true
        return (driver, [])
    }

    /// Without a provider the driver behaves as it always has: one frame,
    /// the primary radio.
    func testOneRadioAnnouncesOnceOnThePrimary() {
        let transport = RadioTransport()
        let (driver, _) = announcingDriver(transport)
        XCTAssertEqual(driver.broadcastNodes(), 1)
        XCTAssertEqual(transport.broadcasts.map(\.radio), [.primary])
    }

    /// One node on every radio: the same payload leaves each announcing
    /// radio, and the operator reads one line.
    func testOneNodeOnEveryRadioSendsTheSamePayloadFromEachRadio() {
        let transport = RadioTransport()
        let (driver, _) = announcingDriver(transport)
        var notes: [String] = []
        driver.onOperatorNote = { notes.append($0) }
        driver.announcementsProvider = { [base, uhf, node] in
            [NetRomAnnouncement(radio: base, node: node, alias: "EPINOD"),
             NetRomAnnouncement(radio: uhf, node: node, alias: "EPINOD")]
        }

        XCTAssertEqual(driver.broadcastNodes(), 2)
        XCTAssertEqual(transport.broadcasts.map(\.radio), [base, uhf])
        XCTAssertEqual(transport.broadcasts[0].payload, transport.broadcasts[1].payload)
        XCTAssertEqual(notes, ["Announced this station as EPINOD on 2 radios."])
    }

    /// One node per radio: each radio advertises its own callsign and alias,
    /// and the operator reads one line per node.
    func testOneNodePerRadioSendsEachRadiosOwnNode() {
        let transport = RadioTransport()
        let (driver, _) = announcingDriver(transport)
        var notes: [String] = []
        driver.onOperatorNote = { notes.append($0) }
        driver.announcementsProvider = { [base, uhf, node, uhfNode] in
            [NetRomAnnouncement(radio: base, node: node, alias: "EPINOD"),
             NetRomAnnouncement(radio: uhf, node: uhfNode, alias: "UHFNOD")]
        }

        XCTAssertEqual(driver.broadcastNodes(), 2)
        XCTAssertNotEqual(transport.broadcasts[0].payload, transport.broadcasts[1].payload)
        XCTAssertEqual(Array(transport.broadcasts[1].payload[1..<7]), Array("UHFNOD".utf8),
                       "the origin alias is the radio's own")
        XCTAssertEqual(notes, ["Announced this station as EPINOD; this station as UHFNOD."])
    }

    // MARK: - A node per radio answers as itself

    func testACircuitToARadiosNodeIsAcceptedAndAnsweredFromThatNode() {
        let endpoint = NetRomEndpoint(localNode: node, localUser: node,
                                      scheduler: NetRomEndpointTests.TestScheduler())
        endpoint.additionalLocalNodes = [uhfNode]
        endpoint.inboundAcceptor = { _, _ in true }
        var transmitted: [NetRomDatagram] = []
        endpoint.onTransmitDatagram = { data, _ in
            transmitted.append(NetRomTransportWire.parse(data)!)
            return true
        }
        let remote = AX25Address(call: "KB5YZB", ssid: 7)
        let conreq = NetRomDatagram(
            origin: remote, destination: uhfNode, ttl: 25,
            transport: .connectRequest(myIndex: 0x0A, myId: 0x0B, proposedWindow: 2,
                                       user: remote, originNode: remote, t1Seconds: 60))
        endpoint.handleInboundDatagram(NetRomTransportWire.encode(conreq), fromNeighbor: remote)

        XCTAssertEqual(endpoint.circuits.count, 1, "addressed to one of our nodes")
        XCTAssertEqual(transmitted.last?.origin, uhfNode, "the answer comes from the node that was called")
        guard case .connectAck(_, _, _, _, _, _, let refused)? = transmitted.last?.transport else {
            return XCTFail("expected CONACK")
        }
        XCTAssertFalse(refused)
    }

    /// The station's own node still answers as before, and a stranger's
    /// callsign is still somebody else's.
    func testOtherNodesStayForeign() {
        let endpoint = NetRomEndpoint(localNode: node, localUser: node,
                                      scheduler: NetRomEndpointTests.TestScheduler())
        endpoint.additionalLocalNodes = [uhfNode]
        XCTAssertTrue(endpoint.isLocalNode(node))
        XCTAssertTrue(endpoint.isLocalNode(uhfNode))
        XCTAssertFalse(endpoint.isLocalNode(AX25Address(call: "K0EPI", ssid: 2)))
    }
}
