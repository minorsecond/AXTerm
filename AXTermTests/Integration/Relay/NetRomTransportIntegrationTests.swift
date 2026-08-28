import XCTest
@testable import AXTerm

/// End-to-end through the real AX.25 session manager: a NET/ROM circuit
/// opened over a live L2 link to a neighbor, with every byte crossing
/// the actual frame builder and the actual PID demux.
///
/// The scenario is the one from the field capture of 2026-08-27 —
/// reaching COSCO, which this station cannot hear, through DRLNOD,
/// which it can. The terminal relay needed two node prompts to do that.
/// The transport needs one connect request.
final class NetRomTransportIntegrationTests: XCTestCase {

    private let localNode = AX25Address(call: "K0EPI", ssid: 7)
    private let drlnod = AX25Address(call: "DRLNOD", ssid: 0)
    private let cosco = AX25Address(call: "COSCO", ssid: 0)

    /// Wires a real AX25SessionManager to a driver, exactly as
    /// SessionCoordinator does, and captures what would hit the radio.
    /// Mirrors production's `NetRomSessionTransport`: nonisolated, because
    /// the transport protocol is, and hopping with `assumeIsolated` where it
    /// touches the MainActor session manager.
    private nonisolated final class Rig: NetRomLinkTransport {
        let manager: AX25SessionManager
        var driver: NetRomLinkDriver!
        var transmitted: [OutboundFrame] = []
        /// Datagrams as handed to the link layer — independent of how
        /// OutboundFrame happens to store its info field.
        var sentDatagramBytes: [Data] = []
        var operatorNotes: [String] = []
        var circuitData: [Data] = []

        init(localNode: AX25Address, routes: [String: String]) {
            manager = MainActor.assumeIsolated { AX25SessionManager(localCallsign: localNode) }
            driver = NetRomLinkDriver(
                localNode: localNode, localUser: localNode,
                transport: nil,
                scheduler: NetRomEndpointTests.TestScheduler()
            )
            driver.setTransport(self)
            driver.nextHopResolver = { routes[$0.uppercased()] }
            driver.onOperatorNote = { [weak self] in self?.operatorNotes.append($0) }
            driver.onCircuitData = { [weak self] _, data in self?.circuitData.append(data) }
            MainActor.assumeIsolated {
                manager.onSendFrame = { [weak self] frame in self?.transmitted.append(frame) }
                // The production demux: PID 0xCF never reaches the terminal.
                manager.onNetRomDatagram = { [weak self] session, data in
                    self?.driver.handleInboundDatagram(data, fromNeighbor: session.remoteAddress)
                }
            }
        }

        func datagramCapacity(toNeighbor neighbor: AX25Address) -> Int? {
            MainActor.assumeIsolated {
                manager.session(for: neighbor, path: DigiPath(), channel: 0)
                    .stateMachine.config.paclen
            }
        }

        func sendDatagram(_ data: Data, toNeighbor neighbor: AX25Address) -> Bool {
            sentDatagramBytes.append(data)
            let frames = MainActor.assumeIsolated {
                manager.sendData(
                    data, to: neighbor, path: DigiPath(), channel: 0, pid: NetRomWire.pid)
            }
            transmitted.append(contentsOf: frames)
            return true
        }

        var broadcasts: [Data] = []
        func sendNodesBroadcast(_ payload: Data, summary: String) -> Bool {
            broadcasts.append(payload)
            MainActor.assumeIsolated {
                let frame = AX25FrameBuilder.buildUI(
                    from: manager.localCallsign,
                    to: AX25Address(call: NetRomNodesBroadcast.destinationCall, ssid: 0),
                    via: DigiPath(),
                    pid: NetRomWire.pid,
                    payload: payload
                )
                transmitted.append(frame)
            }
            return true
        }

        /// Bring the L2 link to `neighbor` up, as a UA would.
        func completeL2Handshake(with neighbor: AX25Address) {
            MainActor.assumeIsolated {
                let session = manager.session(for: neighbor, path: DigiPath(), channel: 0)
                if session.state == .disconnected {
                    _ = session.stateMachine.handle(event: .connectRequest)
                }
                manager.handleInboundUA(from: neighbor, path: DigiPath(), channel: 0)
            }
        }

        /// Deliver one NET/ROM datagram inbound as a real PID-0xCF I-frame.
        func receiveDatagram(_ datagram: NetRomDatagram, fromNeighbor neighbor: AX25Address, ns: Int) {
            MainActor.assumeIsolated {
                _ = manager.handleInboundIFrame(
                    from: neighbor, path: DigiPath(), channel: 0,
                    ns: ns, nr: 0, pf: false,
                    payload: NetRomTransportWire.encode(datagram),
                    pid: NetRomWire.pid)
            }
        }

        /// Terminal-side text on the same link, for the demux tests.
        func receiveText(_ text: String, fromNeighbor neighbor: AX25Address, ns: Int) {
            MainActor.assumeIsolated {
                _ = manager.handleInboundIFrame(
                    from: neighbor, path: DigiPath(), channel: 0,
                    ns: ns, nr: 0, pf: false,
                    payload: Data(text.utf8), pid: 0xF0)
            }
        }

        func observeTerminalText(_ sink: @escaping (Data) -> Void) {
            MainActor.assumeIsolated {
                manager.onDataReceived = { _, data in sink(data) }
            }
        }

        /// Every NET/ROM datagram we put on the air, decoded.
        var sentDatagrams: [NetRomDatagram] {
            sentDatagramBytes.compactMap { NetRomTransportWire.parse($0) }
        }
    }

    // MARK: - The COSCO scenario

    func testCircuitToAStationTwoHopsAwayRidesOneNeighborLink() {
        let rig = Rig(localNode: localNode, routes: ["COSCO": "DRLNOD"])

        guard case let .success(id) = rig.driver.openCircuit(to: cosco) else {
            return XCTFail("route table says COSCO is reachable via DRLNOD")
        }

        // Nothing is on the air to COSCO — it is not a neighbor and we
        // have never heard it. Everything goes to DRLNOD.
        let addressedTo = Set(rig.transmitted.map { $0.destination.display })
        XCTAssertEqual(addressedTo, ["DRLNOD"],
                       "L2 frames go to the neighbor; COSCO is addressed at layer 3")

        // The first frame is the L2 connect, because the link was down.
        XCTAssertTrue(rig.transmitted.contains { $0.frameType == "u" },
                      "a U-frame (SABM/XID) opens the link to DRLNOD first")

        rig.completeL2Handshake(with: drlnod)

        // Now the queued CONREQ goes out as a PID-0xCF I-frame.
        guard let conreq = rig.sentDatagrams.first else {
            return XCTFail("the CONREQ should be on the air once the link is up")
        }
        XCTAssertEqual(conreq.origin, localNode)
        XCTAssertEqual(conreq.destination, cosco,
                       "one connect request, addressed to COSCO, routed by the network")
        guard case let .connectRequest(myIndex, myId, _, user, node, _) = conreq.transport else {
            return XCTFail("expected CONREQ, got \(conreq.transport)")
        }
        XCTAssertEqual(user, localNode)
        XCTAssertEqual(node, localNode)

        // COSCO accepts, its CONACK routed back to us by DRLNOD.
        rig.receiveDatagram(NetRomDatagram(
            origin: cosco, destination: localNode, ttl: 24,
            transport: .connectAck(yourIndex: myIndex, yourId: myId,
                                   myIndex: 0x11, myId: 0x22,
                                   acceptedWindow: 4, ttl: nil, refused: false)),
            fromNeighbor: drlnod, ns: 0)

        XCTAssertEqual(rig.driver.circuitState(id), .connected)
        XCTAssertEqual(rig.driver.circuits.first?.statusLine,
                       "Circuit to COSCO through DRLNOD")
        XCTAssertTrue(rig.operatorNotes.contains { $0.contains("Connected to COSCO") },
                      "the operator is told plainly: \(rig.operatorNotes)")
    }

    func testDataFlowsBothWaysOverTheCircuit() {
        let rig = Rig(localNode: localNode, routes: ["COSCO": "DRLNOD"])
        guard case let .success(id) = rig.driver.openCircuit(to: cosco) else {
            return XCTFail("open")
        }
        rig.completeL2Handshake(with: drlnod)
        guard case let .connectRequest(myIndex, myId, _, _, _, _) =
                rig.sentDatagrams.first?.transport else { return XCTFail("no CONREQ") }
        rig.receiveDatagram(NetRomDatagram(
            origin: cosco, destination: localNode, ttl: 24,
            transport: .connectAck(yourIndex: myIndex, yourId: myId,
                                   myIndex: 0x11, myId: 0x22,
                                   acceptedWindow: 4, ttl: nil, refused: false)),
            fromNeighbor: drlnod, ns: 0)

        // Outbound: our text becomes an INFO datagram inside an I-frame.
        rig.driver.send(Data("N\r".utf8), on: id)
        guard let info = rig.sentDatagrams.last,
              case let .information(peerIdx, peerId, txSeq, _, _, _, _, payload) = info.transport else {
            return XCTFail("expected an INFO datagram, got \(String(describing: rig.sentDatagrams.last))")
        }
        XCTAssertEqual(peerIdx, 0x11, "addressed by COSCO's circuit handle")
        XCTAssertEqual(peerId, 0x22)
        XCTAssertEqual(txSeq, 0)
        XCTAssertEqual(payload, Data("N\r".utf8))

        // Inbound: COSCO's reply comes back and is delivered to the app,
        // not to the terminal transcript.
        rig.receiveDatagram(NetRomDatagram(
            origin: cosco, destination: localNode, ttl: 24,
            transport: .information(yourIndex: myIndex, yourId: myId,
                                    txSeq: 0, rxSeq: 1,
                                    choke: false, nak: false, moreFollows: false,
                                    payload: Data("COSCO:KE0GB-7\r".utf8))),
            fromNeighbor: drlnod, ns: 1)
        XCTAssertEqual(rig.circuitData, [Data("COSCO:KE0GB-7\r".utf8)])
    }

    func testNetRomTrafficNeverReachesTheTerminal() {
        let rig = Rig(localNode: localNode, routes: ["COSCO": "DRLNOD"])
        var terminalText: [Data] = []
        rig.observeTerminalText { terminalText.append($0) }

        guard case .success = rig.driver.openCircuit(to: cosco) else { return XCTFail("open") }
        rig.completeL2Handshake(with: drlnod)
        guard case let .connectRequest(myIndex, myId, _, _, _, _) =
                rig.sentDatagrams.first?.transport else { return XCTFail("no CONREQ") }
        rig.receiveDatagram(NetRomDatagram(
            origin: cosco, destination: localNode, ttl: 24,
            transport: .connectAck(yourIndex: myIndex, yourId: myId,
                                   myIndex: 0x11, myId: 0x22,
                                   acceptedWindow: 4, ttl: nil, refused: false)),
            fromNeighbor: drlnod, ns: 0)
        rig.receiveDatagram(NetRomDatagram(
            origin: cosco, destination: localNode, ttl: 24,
            transport: .information(yourIndex: myIndex, yourId: myId,
                                    txSeq: 0, rxSeq: 0,
                                    choke: false, nak: false, moreFollows: false,
                                    payload: Data("circuit payload".utf8))),
            fromNeighbor: drlnod, ns: 1)

        XCTAssertTrue(terminalText.isEmpty,
                      "PID 0xCF is protocol traffic — it must never print as node text")
        XCTAssertEqual(rig.circuitData, [Data("circuit payload".utf8)])
    }

    func testTerminalTextOnTheSameLinkStillReachesTheTerminal() {
        // A node's banner (0xF0) and circuit traffic (0xCF) share one L2
        // link. Both must land where they belong.
        let rig = Rig(localNode: localNode, routes: ["COSCO": "DRLNOD"])
        var terminalText: [Data] = []
        rig.observeTerminalText { terminalText.append($0) }

        guard case .success = rig.driver.openCircuit(to: cosco) else { return XCTFail("open") }
        rig.completeL2Handshake(with: drlnod)

        rig.receiveText("###CONNECTED TO NODE DRLNOD\r", fromNeighbor: drlnod, ns: 0)

        XCTAssertEqual(terminalText, [Data("###CONNECTED TO NODE DRLNOD\r".utf8)])
        XCTAssertTrue(rig.circuitData.isEmpty)
    }

    func testRefusalFromTheFarNodeIsExplainedNotRetried() {
        let rig = Rig(localNode: localNode, routes: ["COSCO": "DRLNOD"])
        guard case let .success(id) = rig.driver.openCircuit(to: cosco) else {
            return XCTFail("open")
        }
        rig.completeL2Handshake(with: drlnod)
        guard case let .connectRequest(myIndex, myId, _, _, _, _) =
                rig.sentDatagrams.first?.transport else { return XCTFail("no CONREQ") }

        rig.receiveDatagram(NetRomDatagram(
            origin: cosco, destination: localNode, ttl: 24,
            transport: .connectAck(yourIndex: myIndex, yourId: myId,
                                   myIndex: 0, myId: 0,
                                   acceptedWindow: 0, ttl: nil, refused: true)),
            fromNeighbor: drlnod, ns: 0)

        XCTAssertNil(rig.driver.circuitState(id))
        XCTAssertTrue(rig.operatorNotes.contains { $0.contains("refused the circuit") },
                      "a refusal is a plain sentence, not a timeout: \(rig.operatorNotes)")
    }

    func testDroppedNeighborLinkEndsTheCircuit() {
        let rig = Rig(localNode: localNode, routes: ["COSCO": "DRLNOD"])
        guard case let .success(id) = rig.driver.openCircuit(to: cosco) else {
            return XCTFail("open")
        }
        rig.completeL2Handshake(with: drlnod)
        guard case let .connectRequest(myIndex, myId, _, _, _, _) =
                rig.sentDatagrams.first?.transport else { return XCTFail("no CONREQ") }
        rig.receiveDatagram(NetRomDatagram(
            origin: cosco, destination: localNode, ttl: 24,
            transport: .connectAck(yourIndex: myIndex, yourId: myId,
                                   myIndex: 0x11, myId: 0x22,
                                   acceptedWindow: 4, ttl: nil, refused: false)),
            fromNeighbor: drlnod, ns: 0)
        XCTAssertEqual(rig.driver.circuitState(id), .connected)

        // DRLNOD disconnects the L2 link out from under the circuit.
        rig.driver.neighborLinkDropped(drlnod)

        XCTAssertNil(rig.driver.circuitState(id))
        XCTAssertTrue(rig.operatorNotes.contains { $0.contains("Could not carry") },
                      "the operator learns the link died, not that COSCO went quiet")
    }

    func testNoRouteMeansNothingIsTransmitted() {
        let rig = Rig(localNode: localNode, routes: [:])
        guard case let .failure(reason) = rig.driver.openCircuit(to: cosco) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(reason, .noRoute("COSCO"))
        XCTAssertTrue(rig.transmitted.isEmpty,
                      "an unknown destination never keys the transmitter")
    }
}
