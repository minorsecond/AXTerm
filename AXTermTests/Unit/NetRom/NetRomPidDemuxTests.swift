import XCTest
@testable import AXTerm

/// PID plumbing: the protocol demux that lets one AX.25 link carry both
/// terminal text (0xF0) and NET/ROM datagrams (0xCF).
///
/// The state-machine half proves the PID survives delivery — including
/// frames that waited in the resequencing buffer, where a lost frame's
/// heal releases a mixed run of protocols in one burst. The manager half
/// proves 0xCF bytes reach only the NET/ROM tap, and everything else
/// still flows to the terminal exactly as before.
final class NetRomPidDemuxTests: XCTestCase {

    private func connectedMachine() -> AX25StateMachine {
        var machine = AX25StateMachine(config: AX25SessionConfig())
        _ = machine.handle(event: .connectRequest)
        _ = machine.handle(event: .receivedUA)
        XCTAssertEqual(machine.state, .connected)
        return machine
    }

    private func deliveries(_ actions: [AX25SessionAction]) -> [(Data, UInt8?)] {
        actions.compactMap {
            if case let .deliverData(data, pid) = $0 { return (data, pid) }
            return nil
        }
    }

    // MARK: - State machine carries the PID

    func testInSequenceDeliveryCarriesPid() {
        var machine = connectedMachine()
        let actions = machine.handle(
            event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data([0x01]), pid: 0xCF))
        let out = deliveries(actions)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].1, 0xCF)
    }

    func testEventWithoutPidDeliversNilPid() {
        // Every pre-existing call site constructs the event without a
        // pid; delivery must keep meaning "terminal text" for them.
        var machine = connectedMachine()
        let actions = machine.handle(
            event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data([0x01])))
        XCTAssertEqual(deliveries(actions).first?.1, nil)
    }

    func testReorderedFramesKeepTheirOwnPids() {
        // ns=1 (0xCF) and ns=2 (0xF0) arrive before ns=0 (0xF0). When the
        // gap heals, each delivery must carry the PID of the frame that
        // brought it — not the PID of the frame that healed the gap.
        var machine = connectedMachine()
        _ = machine.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("NETROM".utf8), pid: 0xCF))
        _ = machine.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("TEXT2".utf8), pid: 0xF0))
        let actions = machine.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("TEXT1".utf8), pid: 0xF0))
        let out = deliveries(actions)
        XCTAssertEqual(out.map { String(decoding: $0.0, as: UTF8.self) }, ["TEXT1", "NETROM", "TEXT2"])
        XCTAssertEqual(out.map { $0.1 }, [0xF0, 0xCF, 0xF0],
                       "per-frame PID survives the resequencing buffer")
    }

    func testReceiveGapFlushKeepsPids() {
        // The relay-handshake gap flush delivers buffered frames too.
        var machine = connectedMachine()
        _ = machine.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("HELD".utf8), pid: 0xCF))
        let actions = machine.skipReceiveGapForHandshake()
        let out = deliveries(actions)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].1, 0xCF)
    }

    // MARK: - Manager demux

    @MainActor
    private func connectedManagerSession() -> (AX25SessionManager, AX25Address) {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let neighbor = AX25Address(call: "KE0NCQ", ssid: 0)
        let session = manager.session(for: neighbor, path: DigiPath(), channel: 0)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        XCTAssertEqual(session.state, .connected)
        return (manager, neighbor)
    }

    @MainActor
    func testNetRomPidRoutesToNetRomTapOnly() {
        let (manager, neighbor) = connectedManagerSession()
        var netromPayloads: [Data] = []
        var terminalPayloads: [Data] = []
        var reassemblyPayloads: [Data] = []
        manager.onNetRomDatagram = { _, data in netromPayloads.append(data) }
        manager.onDataReceived = { _, data in terminalPayloads.append(data) }
        manager.onDataDeliveredForReassembly = { _, data in reassemblyPayloads.append(data) }

        let datagram = Data([0xDE, 0xAD, 0xBE, 0xEF])
        _ = manager.handleInboundIFrame(
            from: neighbor, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: false, payload: datagram, pid: 0xCF)

        XCTAssertEqual(netromPayloads, [datagram], "0xCF goes to the NET/ROM tap")
        XCTAssertTrue(terminalPayloads.isEmpty, "…and never to the terminal")
        XCTAssertTrue(reassemblyPayloads.isEmpty, "…and never to AXDP reassembly")
    }

    @MainActor
    func testTextPidStillFlowsToTerminalAndReassembly() {
        let (manager, neighbor) = connectedManagerSession()
        var netromPayloads: [Data] = []
        var terminalPayloads: [Data] = []
        manager.onNetRomDatagram = { _, data in netromPayloads.append(data) }
        manager.onDataReceived = { _, data in terminalPayloads.append(data) }

        let text = Data("HELLO\r".utf8)
        _ = manager.handleInboundIFrame(
            from: neighbor, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: false, payload: text, pid: 0xF0)

        XCTAssertEqual(terminalPayloads, [text])
        XCTAssertTrue(netromPayloads.isEmpty)
    }

    @MainActor
    func testMixedTrafficOnOneLinkSplitsCleanly() {
        // The real neighbor-link shape: a node banner in 0xF0 interleaved
        // with NET/ROM datagrams in 0xCF on the same L2 session.
        let (manager, neighbor) = connectedManagerSession()
        var netromPayloads: [Data] = []
        var terminalPayloads: [Data] = []
        manager.onNetRomDatagram = { _, data in netromPayloads.append(data) }
        manager.onDataReceived = { _, data in terminalPayloads.append(data) }

        let banner = Data("###CONNECTED TO NODE\r".utf8)
        let datagram1 = Data([0x01, 0x02])
        let datagram2 = Data([0x03, 0x04])
        _ = manager.handleInboundIFrame(from: neighbor, path: DigiPath(), channel: 0,
                                        ns: 0, nr: 0, pf: false, payload: banner, pid: 0xF0)
        _ = manager.handleInboundIFrame(from: neighbor, path: DigiPath(), channel: 0,
                                        ns: 1, nr: 0, pf: false, payload: datagram1, pid: 0xCF)
        _ = manager.handleInboundIFrame(from: neighbor, path: DigiPath(), channel: 0,
                                        ns: 2, nr: 0, pf: false, payload: datagram2, pid: 0xCF)

        XCTAssertEqual(terminalPayloads, [banner])
        XCTAssertEqual(netromPayloads, [datagram1, datagram2])
    }

    @MainActor
    func testNetRomPidBypassesDeliveryClaims() {
        // A Winlink-style claim owns a session's bytes — but a claim is
        // an application-protocol conversation in 0xF0. Protocol demux
        // by PID happens first: 0xCF is never a claim's traffic.
        let (manager, neighbor) = connectedManagerSession()
        guard let session = manager.sessions.values.first else { return XCTFail("no session") }
        var claimed: [Data] = []
        var netrom: [Data] = []
        _ = manager.claimDelivery(for: session.key, handler: { _, data in claimed.append(data) })
        manager.onNetRomDatagram = { _, data in netrom.append(data) }

        _ = manager.handleInboundIFrame(from: neighbor, path: DigiPath(), channel: 0,
                                        ns: 0, nr: 0, pf: false, payload: Data([0xAA]), pid: 0xCF)
        _ = manager.handleInboundIFrame(from: neighbor, path: DigiPath(), channel: 0,
                                        ns: 1, nr: 0, pf: false, payload: Data([0xBB]), pid: 0xF0)

        XCTAssertEqual(netrom, [Data([0xAA])])
        XCTAssertEqual(claimed, [Data([0xBB])], "the claim still gets its own protocol's bytes")
    }
}
