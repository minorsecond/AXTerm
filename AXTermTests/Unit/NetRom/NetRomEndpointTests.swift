import XCTest
@testable import AXTerm

/// Tests for the NET/ROM endpoint: circuit-handle allocation, inbound
/// matching (nr_find_socket / nr_find_peer semantics), refusals, timer
/// routing, and transport-failure handling.
final class NetRomEndpointTests: XCTestCase {

    private let node = AX25Address(call: "K0EPI", ssid: 7)
    private let user = AX25Address(call: "K0EPI", ssid: 0)
    private let remote = AX25Address(call: "KB5YZB", ssid: 7)
    private let otherRemote = AX25Address(call: "W0ARP", ssid: 10)

    /// Manual scheduler: timers fire only when the test says so.
    nonisolated final class TestScheduler: NetRomTimerScheduler {
        var pending: [String: () -> Void] = [:]
        private func key(_ c: NetRomCircuitID, _ t: NetRomTimerKind) -> String { "\(c)/\(t.rawValue)" }
        func schedule(circuit: NetRomCircuitID, timer: NetRomTimerKind, seconds: Double, fire: @escaping () -> Void) {
            pending[key(circuit, timer)] = fire
        }
        func cancel(circuit: NetRomCircuitID, timer: NetRomTimerKind) {
            pending[key(circuit, timer)] = nil
        }
        func cancelAll(circuit: NetRomCircuitID) {
            pending = pending.filter { !$0.key.hasPrefix("\(circuit)/") }
        }
        func fire(_ circuit: NetRomCircuitID, _ timer: NetRomTimerKind) {
            pending.removeValue(forKey: key(circuit, timer))?()
        }
        func has(_ circuit: NetRomCircuitID, _ timer: NetRomTimerKind) -> Bool {
            pending[key(circuit, timer)] != nil
        }
    }

    private nonisolated final class Harness {
        let endpoint: NetRomEndpoint
        let scheduler = TestScheduler()
        var transmitted: [(datagram: NetRomDatagram, destination: AX25Address)] = []
        var routable = true
        var connected: [NetRomCircuitID] = []
        var disconnected: [(NetRomCircuitID, NetRomDisconnectReason)] = []
        var dataByCircuit: [NetRomCircuitID: Data] = [:]
        var unmatched: [NetRomDatagram] = []

        init(node: AX25Address, user: AX25Address) {
            endpoint = NetRomEndpoint(
                localNode: node, localUser: user,
                scheduler: scheduler
            )
            endpoint.onTransmitDatagram = { [weak self] data, destination in
                guard let self else { return false }
                guard self.routable else { return false }
                guard let parsed = NetRomTransportWire.parse(data) else {
                    XCTFail("endpoint emitted an unparseable datagram")
                    return false
                }
                self.transmitted.append((parsed, destination))
                return true
            }
            endpoint.onCircuitConnected = { [weak self] id, _ in self?.connected.append(id) }
            endpoint.onCircuitDisconnected = { [weak self] id, reason in
                self?.disconnected.append((id, reason))
            }
            endpoint.onCircuitData = { [weak self] id, data in
                self?.dataByCircuit[id, default: Data()].append(data)
            }
            endpoint.onUnmatchedFrame = { [weak self] datagram, _ in
                self?.unmatched.append(datagram)
            }
        }

        func lastTransport() -> NetRomL4Frame? { transmitted.last?.datagram.transport }

        /// Feed an inbound datagram built from parts.
        func inbound(_ transport: NetRomL4Frame, from origin: AX25Address, to destination: AX25Address? = nil) {
            let datagram = NetRomDatagram(
                origin: origin,
                destination: destination ?? endpoint.localNode,
                ttl: 25, transport: transport
            )
            endpoint.handleInboundDatagram(NetRomTransportWire.encode(datagram), fromNeighbor: origin)
        }
    }

    // MARK: - Opening a circuit

    func testOpenCircuitSendsConreqWithNonzeroHandle() {
        let h = Harness(node: node, user: user)
        let id = h.endpoint.openCircuit(to: remote)
        XCTAssertEqual(h.endpoint.circuitState(id), .connecting)
        guard case let .connectRequest(myIndex, myId, _, u, n, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ, got \(String(describing: h.lastTransport()))")
        }
        XCTAssertNotEqual(myIndex, 0, "circuit index 0 is invalid (nr_find_next_circuit)")
        XCTAssertNotEqual(myId, 0)
        XCTAssertEqual(u, user)
        XCTAssertEqual(n, node)
        XCTAssertTrue(h.scheduler.has(id, .t1))
        XCTAssertEqual(h.transmitted.last?.destination, remote)
    }

    func testHandleAllocationSkipsLiveCircuits() {
        let h = Harness(node: node, user: user)
        var handles = Set<UInt16>()
        for _ in 0..<40 {
            let id = h.endpoint.openCircuit(to: remote)
            guard let box = h.endpoint.circuits[id] else { return XCTFail("missing circuit") }
            let handle = UInt16(box.machine.myIndex) << 8 | UInt16(box.machine.myId)
            XCTAssertTrue(handles.insert(handle).inserted, "live circuits must have distinct handles")
        }
    }

    func testConackRoutesByOurEchoedHandle() {
        let h = Harness(node: node, user: user)
        let id = h.endpoint.openCircuit(to: remote)
        guard case let .connectRequest(myIndex, myId, _, _, _, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ")
        }
        h.inbound(.connectAck(yourIndex: myIndex, yourId: myId,
                              myIndex: 0x21, myId: 0x42,
                              acceptedWindow: 4, ttl: nil, refused: false),
                  from: remote)
        XCTAssertEqual(h.endpoint.circuitState(id), .connected)
        XCTAssertEqual(h.connected, [id])
    }

    func testConackForUnknownHandleIsIgnoredNotReset() {
        let h = Harness(node: node, user: user)
        _ = h.endpoint.openCircuit(to: remote)
        let before = h.transmitted.count
        h.inbound(.connectAck(yourIndex: 0x77, yourId: 0x66,
                              myIndex: 1, myId: 1,
                              acceptedWindow: 4, ttl: nil, refused: false),
                  from: remote)
        XCTAssertEqual(h.transmitted.count, before,
                       "no reset for unknown circuits — the kernel notes they kill BPQ boxes")
        XCTAssertEqual(h.unmatched.count, 1)
    }

    func testRefusalRoutesAndFailsTheCircuit() {
        let h = Harness(node: node, user: user)
        let id = h.endpoint.openCircuit(to: remote)
        guard case let .connectRequest(myIndex, myId, _, _, _, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ")
        }
        // Standard refusal shape.
        h.inbound(.connectAck(yourIndex: myIndex, yourId: myId,
                              myIndex: 0, myId: 0,
                              acceptedWindow: 0, ttl: nil, refused: true),
                  from: remote)
        XCTAssertNil(h.endpoint.circuits[id], "refused circuit is removed")
        XCTAssertEqual(h.disconnected.map { $0.1 }, [.refused])
    }

    func testExoticZeroIndexRefusalAlsoRoutes() {
        let h = Harness(node: node, user: user)
        let id = h.endpoint.openCircuit(to: remote)
        guard case let .connectRequest(myIndex, myId, _, _, _, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ")
        }
        // Wire shape [0, 0, ourIdx, ourId] CONACK|CHOKE — the parser
        // normalizes it so yourIndex/yourId carry our handle.
        let wire = NetRomTransportWire.encode(NetRomDatagram(
            origin: remote, destination: node, ttl: 25,
            transport: .connectAck(yourIndex: myIndex, yourId: myId,
                                   myIndex: 0, myId: 0,
                                   acceptedWindow: nil, ttl: nil, refused: true)))
        // Build the exotic shape manually: swap handle into bytes 17/18.
        var bytes = [UInt8](wire)
        bytes[17] = bytes[15]; bytes[18] = bytes[16]
        bytes[15] = 0; bytes[16] = 0
        h.endpoint.handleInboundDatagram(Data(bytes), fromNeighbor: remote)
        XCTAssertNil(h.endpoint.circuits[id])
        XCTAssertEqual(h.disconnected.map { $0.1 }, [.refused])
    }

    // MARK: - Inbound connects

    func testInboundConreqRefusedByDefaultWithKernelShape() {
        let h = Harness(node: node, user: user)
        h.inbound(.connectRequest(myIndex: 0x0A, myId: 0x0B, proposedWindow: 4,
                                  user: user, originNode: remote, t1Seconds: 120),
                  from: remote)
        guard case let .connectAck(yourIndex, yourId, myIndex, myId, window, _, refused)? = h.lastTransport() else {
            return XCTFail("expected refusal CONACK, got \(String(describing: h.lastTransport()))")
        }
        XCTAssertTrue(refused)
        XCTAssertEqual(yourIndex, 0x0A, "requester's handle echoed in 15/16")
        XCTAssertEqual(yourId, 0x0B)
        XCTAssertEqual(myIndex, 0); XCTAssertEqual(myId, 0)
        XCTAssertEqual(window, 0)
        XCTAssertTrue(h.endpoint.circuits.isEmpty, "no circuit is created for a refused connect")
    }

    func testInboundConreqAcceptedCreatesCircuitAndConacks() {
        let h = Harness(node: node, user: user)
        h.endpoint.inboundAcceptor = { _, _ in true }
        h.inbound(.connectRequest(myIndex: 0x0A, myId: 0x0B, proposedWindow: 2,
                                  user: user, originNode: remote, t1Seconds: 60),
                  from: remote)
        XCTAssertEqual(h.endpoint.circuits.count, 1)
        XCTAssertEqual(h.connected.count, 1)
        guard case let .connectAck(yourIndex, yourId, myIndex, myId, window, ttl, refused)? = h.lastTransport() else {
            return XCTFail("expected CONACK")
        }
        XCTAssertFalse(refused)
        XCTAssertEqual(yourIndex, 0x0A); XCTAssertEqual(yourId, 0x0B)
        XCTAssertNotEqual(myIndex, 0); XCTAssertNotEqual(myId, 0)
        XCTAssertEqual(window, 2, "negotiated down to the proposal")
        XCTAssertEqual(ttl, 25, "extended CONREQ (with T1) earns the TTL byte")
    }

    func testDuplicateConreqReconacksSameCircuit() {
        let h = Harness(node: node, user: user)
        h.endpoint.inboundAcceptor = { _, _ in true }
        let conreq = NetRomL4Frame.connectRequest(
            myIndex: 0x0A, myId: 0x0B, proposedWindow: 4,
            user: user, originNode: remote, t1Seconds: nil)
        h.inbound(conreq, from: remote)
        XCTAssertEqual(h.endpoint.circuits.count, 1)
        let conacksBefore = h.transmitted.count
        h.inbound(conreq, from: remote)
        XCTAssertEqual(h.endpoint.circuits.count, 1, "the duplicate matches the live circuit (nr_find_peer)")
        XCTAssertEqual(h.transmitted.count, conacksBefore + 1, "and the lost CONACK is repeated")
        XCTAssertEqual(h.connected.count, 1, "no second connected notification")
    }

    func testSameHandleDifferentOriginIsADifferentCircuit() {
        let h = Harness(node: node, user: user)
        h.endpoint.inboundAcceptor = { _, _ in true }
        h.inbound(.connectRequest(myIndex: 0x0A, myId: 0x0B, proposedWindow: 4,
                                  user: user, originNode: remote, t1Seconds: nil),
                  from: remote)
        h.inbound(.connectRequest(myIndex: 0x0A, myId: 0x0B, proposedWindow: 4,
                                  user: user, originNode: otherRemote, t1Seconds: nil),
                  from: otherRemote)
        XCTAssertEqual(h.endpoint.circuits.count, 2,
                       "handle collision across origins is legal — matching includes the origin")
    }

    // MARK: - Data flow across two circuits

    func testInterleavedCircuitsRouteIndependently() {
        let h = Harness(node: node, user: user)
        let idA = h.endpoint.openCircuit(to: remote)
        guard case let .connectRequest(aIdx, aId, _, _, _, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ A")
        }
        let idB = h.endpoint.openCircuit(to: otherRemote)
        guard case let .connectRequest(bIdx, bId, _, _, _, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ B")
        }
        h.inbound(.connectAck(yourIndex: aIdx, yourId: aId, myIndex: 1, myId: 1,
                              acceptedWindow: 4, ttl: nil, refused: false), from: remote)
        h.inbound(.connectAck(yourIndex: bIdx, yourId: bId, myIndex: 1, myId: 1,
                              acceptedWindow: 4, ttl: nil, refused: false), from: otherRemote)

        h.inbound(.information(yourIndex: aIdx, yourId: aId, txSeq: 0, rxSeq: 0,
                               choke: false, nak: false, moreFollows: false,
                               payload: Data("FOR-A".utf8)), from: remote)
        h.inbound(.information(yourIndex: bIdx, yourId: bId, txSeq: 0, rxSeq: 0,
                               choke: false, nak: false, moreFollows: false,
                               payload: Data("FOR-B".utf8)), from: otherRemote)

        XCTAssertEqual(h.dataByCircuit[idA], Data("FOR-A".utf8))
        XCTAssertEqual(h.dataByCircuit[idB], Data("FOR-B".utf8))
    }

    func testSendGoesOutAsInfoDatagramToTheRemote() {
        let h = Harness(node: node, user: user)
        let id = h.endpoint.openCircuit(to: remote)
        guard case let .connectRequest(myIndex, myId, _, _, _, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ")
        }
        h.inbound(.connectAck(yourIndex: myIndex, yourId: myId, myIndex: 0x21, myId: 0x42,
                              acceptedWindow: 4, ttl: nil, refused: false), from: remote)
        h.endpoint.send(Data("PAYLOAD".utf8), on: id)
        guard case let .information(yourIndex, yourId, txSeq, _, _, _, _, payload)? = h.lastTransport() else {
            return XCTFail("expected INFO, got \(String(describing: h.lastTransport()))")
        }
        XCTAssertEqual(yourIndex, 0x21, "INFO addressed by the peer's handle")
        XCTAssertEqual(yourId, 0x42)
        XCTAssertEqual(txSeq, 0)
        XCTAssertEqual(payload, Data("PAYLOAD".utf8))
        XCTAssertEqual(h.transmitted.last?.datagram.origin, node)
        XCTAssertEqual(h.transmitted.last?.datagram.destination, remote)
    }

    // MARK: - Datagrams that are not ours

    func testDatagramForAnotherNodeIsDropped() {
        let h = Harness(node: node, user: user)
        h.endpoint.inboundAcceptor = { _, _ in true }
        h.inbound(.connectRequest(myIndex: 1, myId: 1, proposedWindow: 4,
                                  user: user, originNode: remote, t1Seconds: nil),
                  from: remote, to: AX25Address(call: "N0TME", ssid: 3))
        XCTAssertTrue(h.endpoint.circuits.isEmpty, "we are not a router yet — no forwarding, no accepting")
        XCTAssertTrue(h.transmitted.isEmpty)
    }

    func testUnparseableDatagramIsDropped() {
        let h = Harness(node: node, user: user)
        h.endpoint.handleInboundDatagram(Data([0x01, 0x02, 0x03]), fromNeighbor: remote)
        XCTAssertTrue(h.endpoint.circuits.isEmpty)
        XCTAssertTrue(h.transmitted.isEmpty)
    }

    func testProtocolExtensionSurfacesAsUnmatched() {
        let h = Harness(node: node, user: user)
        var bytes = [UInt8](NetRomTransportWire.encode(NetRomDatagram(
            origin: remote, destination: node, ttl: 25,
            transport: .disconnectRequest(yourIndex: 1, yourId: 1))))
        bytes[19] = 0x00  // opcode 0: protocol extension
        h.endpoint.handleInboundDatagram(Data(bytes), fromNeighbor: remote)
        XCTAssertEqual(h.unmatched.count, 1, "INP3/L3RTT/IP is observed, never interpreted")
    }

    // MARK: - Timers

    func testT1FiringRetransmitsConreq() {
        let h = Harness(node: node, user: user)
        let id = h.endpoint.openCircuit(to: remote)
        let before = h.transmitted.count
        h.scheduler.fire(id, .t1)
        XCTAssertEqual(h.transmitted.count, before + 1)
        guard case .connectRequest? = h.lastTransport() else {
            return XCTFail("T1 in connecting retransmits the CONREQ")
        }
    }

    func testT2FiringSendsTheDelayedAck() {
        let h = Harness(node: node, user: user)
        let id = h.endpoint.openCircuit(to: remote)
        guard case let .connectRequest(myIndex, myId, _, _, _, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ")
        }
        h.inbound(.connectAck(yourIndex: myIndex, yourId: myId, myIndex: 0x21, myId: 0x42,
                              acceptedWindow: 4, ttl: nil, refused: false), from: remote)
        h.inbound(.information(yourIndex: myIndex, yourId: myId, txSeq: 0, rxSeq: 0,
                               choke: false, nak: false, moreFollows: false,
                               payload: Data("X".utf8)), from: remote)
        XCTAssertTrue(h.scheduler.has(id, .t2))
        h.scheduler.fire(id, .t2)
        guard case let .informationAck(_, _, rxSeq, _, nak)? = h.lastTransport() else {
            return XCTFail("expected INFOACK after T2")
        }
        XCTAssertEqual(rxSeq, 1)
        XCTAssertFalse(nak)
    }

    func testDeadCircuitTimersAreCancelled() {
        let h = Harness(node: node, user: user)
        let id = h.endpoint.openCircuit(to: remote)
        guard case let .connectRequest(myIndex, myId, _, _, _, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ")
        }
        h.inbound(.connectAck(yourIndex: myIndex, yourId: myId, myIndex: 0, myId: 0,
                              acceptedWindow: 0, ttl: nil, refused: true), from: remote)
        XCTAssertFalse(h.scheduler.has(id, .t1), "dead circuits leave no armed timers")
        XCTAssertFalse(h.scheduler.has(id, .t2))
        XCTAssertFalse(h.scheduler.has(id, .t4))
    }

    // MARK: - Transport failure

    func testUnroutableDatagramFailsTheCircuit() {
        let h = Harness(node: node, user: user)
        h.routable = false
        let id = h.endpoint.openCircuit(to: remote)
        XCTAssertNil(h.endpoint.circuits[id], "an unroutable CONREQ fails the circuit immediately")
        guard case .transportFailure? = h.disconnected.first?.1 else {
            return XCTFail("expected transportFailure, got \(String(describing: h.disconnected.first?.1))")
        }
    }

    // MARK: - Full lifecycle through the endpoint

    func testFullLifecycleConnectSendReceiveDisconnect() {
        let h = Harness(node: node, user: user)
        let id = h.endpoint.openCircuit(to: remote)
        guard case let .connectRequest(myIndex, myId, _, _, _, _)? = h.lastTransport() else {
            return XCTFail("expected CONREQ")
        }
        h.inbound(.connectAck(yourIndex: myIndex, yourId: myId, myIndex: 0x21, myId: 0x42,
                              acceptedWindow: 4, ttl: nil, refused: false), from: remote)
        XCTAssertEqual(h.endpoint.circuitState(id), .connected)

        h.endpoint.send(Data("HELLO NODE".utf8), on: id)
        h.inbound(.informationAck(yourIndex: myIndex, yourId: myId, rxSeq: 1,
                                  choke: false, nak: false), from: remote)
        h.inbound(.information(yourIndex: myIndex, yourId: myId, txSeq: 0, rxSeq: 1,
                               choke: false, nak: false, moreFollows: false,
                               payload: Data("HELLO USER".utf8)), from: remote)
        XCTAssertEqual(h.dataByCircuit[id], Data("HELLO USER".utf8))

        h.endpoint.disconnect(id)
        guard case .disconnectRequest? = h.lastTransport() else {
            return XCTFail("expected DISCREQ")
        }
        h.inbound(.disconnectAck(yourIndex: myIndex, yourId: myId), from: remote)
        XCTAssertNil(h.endpoint.circuits[id])
        XCTAssertEqual(h.disconnected.map { $0.1 }, [.localRequest])
    }
}
