//
//  NetRomEndpoint.swift
//  AXTerm
//
//  NET/ROM L4 endpoint: owns the circuit table, allocates circuit
//  handles, matches inbound datagrams to circuits by the kernel's
//  nr_find_socket / nr_find_peer rules, and drives per-circuit timers.
//
//  The endpoint is transport-agnostic: it hands encoded datagrams to
//  `onTransmitDatagram` and never touches AX.25 sessions itself — the
//  link driver (SessionCoordinator side) binds it to real neighbor
//  links. That keeps every behavior here testable with a fake wire.
//
//  Deliberate omissions, so nothing is invented (CLAUDE.md §15):
//  - No L3 forwarding: a datagram whose destination is not this node is
//    logged and dropped. Routing is the router's job, and this station
//    is not yet a router.
//  - No resets: an unmatched frame is ignored. The kernel source
//    records that unsolicited CONACK|CHOKE replies kill BPQ boxes, and
//    opcode-7 resets are an Xrouter extension (off by default there too).
//

import Foundation

// MARK: - Identifiers

nonisolated struct NetRomCircuitID: Hashable, Sendable, CustomStringConvertible {
    let raw: UUID
    init() { raw = UUID() }
    var description: String { String(raw.uuidString.prefix(8)) }
}

nonisolated enum NetRomTimerKind: String, CaseIterable, Sendable {
    case t1, t2, t4
}

// MARK: - Timer scheduling

/// Injected so tests can fire timers deterministically.
nonisolated protocol NetRomTimerScheduler: AnyObject {
    func schedule(circuit: NetRomCircuitID, timer: NetRomTimerKind, seconds: Double, fire: @escaping () -> Void)
    func cancel(circuit: NetRomCircuitID, timer: NetRomTimerKind)
    func cancelAll(circuit: NetRomCircuitID)
}

/// Production scheduler: main-runloop timers, one per (circuit, kind).
nonisolated final class NetRomFoundationTimerScheduler: NetRomTimerScheduler {
    private var timers: [NetRomCircuitID: [NetRomTimerKind: Timer]] = [:]

    func schedule(circuit: NetRomCircuitID, timer kind: NetRomTimerKind, seconds: Double, fire: @escaping () -> Void) {
        timers[circuit]?[kind]?.invalidate()
        let timer = Timer(timeInterval: max(0.05, seconds), repeats: false) { _ in
            // Fires on the main runloop — the same thread the endpoint
            // is driven from.
            fire()
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[circuit, default: [:]][kind] = timer
    }

    func cancel(circuit: NetRomCircuitID, timer kind: NetRomTimerKind) {
        timers[circuit]?[kind]?.invalidate()
        timers[circuit]?[kind] = nil
    }

    func cancelAll(circuit: NetRomCircuitID) {
        timers[circuit]?.values.forEach { $0.invalidate() }
        timers[circuit] = nil
    }
}

// MARK: - Endpoint

/// Deliberately `nonisolated`: this is a protocol engine, like the state
/// machine it owns. Concurrency discipline is single-executor by
/// convention (drive it from the main thread, as SessionCoordinator
/// does); implicit MainActor isolation is avoided because isolated
/// deinits crashed in libmalloc under the test runner (2026-08-27).
nonisolated final class NetRomEndpoint {

    // MARK: Identity & configuration

    /// This station's node callsign — the L3 origin of everything we send
    /// and the only L3 destination we accept.
    var localNode: AX25Address
    /// The operator callsign carried in CONREQ's user field.
    var localUser: AX25Address
    var circuitConfig: NetRomCircuitConfig

    // MARK: Wiring

    /// Encoded datagram out. Return false if it could not be routed —
    /// the owning circuit is failed with `.transportFailure`.
    var onTransmitDatagram: ((Data, _ destination: AX25Address) -> Bool)?
    var onCircuitData: ((NetRomCircuitID, Data) -> Void)?
    var onCircuitConnected: ((NetRomCircuitID, _ window: Int) -> Void)?
    var onCircuitDisconnected: ((NetRomCircuitID, NetRomDisconnectReason) -> Void)?
    /// Arbitration for inbound CONREQs. Return true to accept. When nil,
    /// everything is refused — the honest default for a station running
    /// no services yet.
    var inboundAcceptor: ((_ user: AX25Address, _ originNode: AX25Address) -> Bool)?
    /// Diagnostic tap for frames that matched nothing.
    var onUnmatchedFrame: ((NetRomDatagram, _ neighbor: AX25Address) -> Void)?
    /// A datagram addressed to some other node. Returning without acting
    /// drops it, which is what an endpoint does; the link driver
    /// implements transit routing on top of this when the operator has
    /// turned forwarding on.
    var onTransitDatagram: ((NetRomDatagram, _ neighbor: AX25Address) -> Void)?

    // MARK: State

    /// Plain data box; `nonisolated` keeps its deinit a normal deinit —
    /// the implicit MainActor isolation would route deallocation through
    /// swift_task_deinitOnExecutor, which crashed in libmalloc under the
    /// test runner (2026-08-27).
    nonisolated final class CircuitBox {
        let id: NetRomCircuitID
        var machine: NetRomCircuitStateMachine
        init(id: NetRomCircuitID, machine: NetRomCircuitStateMachine) {
            self.id = id
            self.machine = machine
        }
    }

    private(set) var circuits: [NetRomCircuitID: CircuitBox] = [:]
    private let scheduler: NetRomTimerScheduler
    /// Rolling allocator matching nr_find_next_circuit: a 16-bit counter
    /// split into index/id, skipping any half that is zero and any pair
    /// already in use.
    private var circuitCounter: UInt16

    init(
        localNode: AX25Address,
        localUser: AX25Address,
        circuitConfig: NetRomCircuitConfig = NetRomCircuitConfig(),
        scheduler: NetRomTimerScheduler? = nil,
        firstCircuitNumber: UInt16 = 0x0101
    ) {
        self.localNode = localNode
        self.localUser = localUser
        self.circuitConfig = circuitConfig
        self.scheduler = scheduler ?? NetRomFoundationTimerScheduler()
        self.circuitCounter = firstCircuitNumber
    }

    // MARK: Public API

    /// Open an outbound circuit to a remote node. The CONREQ goes out
    /// immediately (or the circuit fails with `.transportFailure` if the
    /// datagram cannot be routed).
    @discardableResult
    func openCircuit(to remoteNode: AX25Address) -> NetRomCircuitID {
        let (index, id) = allocateHandle()
        let box = CircuitBox(
            id: NetRomCircuitID(),
            machine: NetRomCircuitStateMachine(
                config: circuitConfig,
                localUser: localUser,
                localNode: localNode,
                remoteNode: remoteNode,
                myIndex: index,
                myId: id
            )
        )
        circuits[box.id] = box
        dispatch(box, event: .connectRequest)
        return box.id
    }

    func send(_ data: Data, on id: NetRomCircuitID) {
        guard let box = circuits[id] else { return }
        dispatch(box, event: .sendData(data))
    }

    func disconnect(_ id: NetRomCircuitID) {
        guard let box = circuits[id] else { return }
        dispatch(box, event: .disconnectRequest)
    }

    func setLocalBusy(_ busy: Bool, on id: NetRomCircuitID) {
        guard let box = circuits[id] else { return }
        dispatch(box, event: .localBusy(busy))
    }

    func circuitState(_ id: NetRomCircuitID) -> NetRomCircuitState? {
        circuits[id]?.machine.state
    }

    /// Fail one circuit because the layer below it went away (the L2 link
    /// to its neighbor dropped, the port closed). Distinct from
    /// `disconnect`: no DISCREQ is attempted, because there is nothing
    /// left to carry it.
    func failCircuit(_ id: NetRomCircuitID, reason: String) {
        guard let box = circuits[id] else { return }
        dispatch(box, event: .transportFailure(reason))
    }

    /// Every live circuit, oldest handle first, for drivers and UI.
    func liveCircuits() -> [(id: NetRomCircuitID, remote: AX25Address, state: NetRomCircuitState)] {
        circuits.values
            .map { (id: $0.id, remote: $0.machine.remoteNode, state: $0.machine.state) }
            .sorted { $0.remote.display < $1.remote.display }
    }

    func remoteNode(of id: NetRomCircuitID) -> AX25Address? {
        circuits[id]?.machine.remoteNode
    }

    // MARK: Inbound

    /// Feed one received PID-0xCF I-frame payload (one L3 datagram).
    func handleInboundDatagram(_ data: Data, fromNeighbor neighbor: AX25Address) {
        guard let datagram = NetRomTransportWire.parse(data) else {
            TxLog.debug(.session, "NET/ROM datagram failed to parse", [
                "neighbor": neighbor.display, "bytes": data.count
            ])
            return
        }

        // Not addressed to this node. Offer it for transit; with no
        // handler installed this is simply a drop, which is the correct
        // behavior for a station that is not a router.
        guard CallsignNormalizer.addressesMatch(datagram.destination, localNode) else {
            TxLog.debug(.session, "NET/ROM datagram for another node", [
                "origin": datagram.origin.display,
                "destination": datagram.destination.display,
                "neighbor": neighbor.display,
                "ttl": Int(datagram.ttl)
            ])
            onTransitDatagram?(datagram, neighbor)
            return
        }

        switch datagram.transport {
        case .protocolExtension:
            // INP3 / L3RTT / IP: outside the transport's charter.
            onUnmatchedFrame?(datagram, neighbor)

        case let .connectRequest(theirIndex, theirId, proposedWindow, user, originNode, t1Seconds):
            handleInboundConnectRequest(
                datagram: datagram, neighbor: neighbor,
                theirIndex: theirIndex, theirId: theirId,
                proposedWindow: proposedWindow,
                user: user, originNode: originNode, t1Seconds: t1Seconds
            )

        case let .connectAck(yourIndex, yourId, _, _, _, _, _):
            // Routed by OUR handle, echoed in bytes 15/16 (nr_find_socket
            // — with the parser normalizing the exotic zero-index shape
            // into the same fields).
            if let box = findByMyHandle(index: yourIndex, id: yourId) {
                dispatch(box, event: .received(datagram.transport))
            } else {
                onUnmatchedFrame?(datagram, neighbor)
            }

        case let .disconnectRequest(yourIndex, yourId),
             let .disconnectAck(yourIndex, yourId),
             let .reset(yourIndex, yourId):
            if let box = findByMyHandle(index: yourIndex, id: yourId) {
                dispatch(box, event: .received(datagram.transport))
            } else {
                onUnmatchedFrame?(datagram, neighbor)
            }

        case let .information(yourIndex, yourId, _, _, _, _, _, _),
             let .informationAck(yourIndex, yourId, _, _, _):
            if let box = findByMyHandle(index: yourIndex, id: yourId) {
                dispatch(box, event: .received(datagram.transport))
            } else {
                onUnmatchedFrame?(datagram, neighbor)
            }
        }
    }

    private func handleInboundConnectRequest(
        datagram: NetRomDatagram, neighbor: AX25Address,
        theirIndex: UInt8, theirId: UInt8,
        proposedWindow: UInt8,
        user: AX25Address, originNode: AX25Address, t1Seconds: UInt16?
    ) {
        // Duplicate detection (nr_find_peer): their handle + origin.
        if let existing = findByTheirHandle(index: theirIndex, id: theirId, origin: datagram.origin) {
            // Our CONACK was lost; the machine re-sends it.
            dispatch(existing, event: .received(datagram.transport))
            return
        }

        let accepted = inboundAcceptor?(user, originNode) ?? false
        guard accepted else {
            transmitRefusal(of: datagram, theirIndex: theirIndex, theirId: theirId)
            return
        }

        let (index, id) = allocateHandle()
        let box = CircuitBox(
            id: NetRomCircuitID(),
            machine: NetRomCircuitStateMachine(
                config: circuitConfig,
                localUser: localUser,
                localNode: localNode,
                remoteNode: datagram.origin,
                myIndex: index,
                myId: id
            )
        )
        circuits[box.id] = box
        dispatch(box, event: .acceptInbound(
            theirIndex: theirIndex, theirId: theirId,
            proposedWindow: proposedWindow,
            t1Seconds: t1Seconds,
            bpqExtension: t1Seconds != nil
        ))
    }

    /// Kernel-shape refusal: CONACK|CHOKE, requester's handle in 15/16,
    /// zeros in 17/18, single zero data byte.
    private func transmitRefusal(of datagram: NetRomDatagram, theirIndex: UInt8, theirId: UInt8) {
        let refusal = NetRomDatagram(
            origin: localNode,
            destination: datagram.origin,
            ttl: circuitConfig.ttl,
            transport: .connectAck(
                yourIndex: theirIndex, yourId: theirId,
                myIndex: 0, myId: 0,
                acceptedWindow: 0, ttl: nil,
                refused: true
            )
        )
        _ = onTransmitDatagram?(NetRomTransportWire.encode(refusal), datagram.origin)
    }

    // MARK: Matching

    private func findByMyHandle(index: UInt8, id: UInt8) -> CircuitBox? {
        guard index != 0 || id != 0 else { return nil }
        return circuits.values.first { $0.machine.myIndex == index && $0.machine.myId == id }
    }

    private func findByTheirHandle(index: UInt8, id: UInt8, origin: AX25Address) -> CircuitBox? {
        circuits.values.first {
            $0.machine.yourIndex == index && $0.machine.yourId == id
                && CallsignNormalizer.addressesMatch($0.machine.remoteNode, origin)
                && $0.machine.state != .disconnected
        }
    }

    /// nr_find_next_circuit: both halves nonzero, pair not in use.
    private func allocateHandle() -> (UInt8, UInt8) {
        for _ in 0...Int(UInt16.max) {
            let index = UInt8(circuitCounter >> 8)
            let id = UInt8(circuitCounter & 0xFF)
            circuitCounter &+= 1
            guard index != 0, id != 0 else { continue }
            let inUse = circuits.values.contains {
                $0.machine.myIndex == index && $0.machine.myId == id
                    && $0.machine.state != .disconnected
            }
            if !inUse { return (index, id) }
        }
        // 65k live circuits on a 1200-baud port is not a real state;
        // hand back a pair and let the collision be the peer's problem.
        return (1, 1)
    }

    // MARK: Action dispatch

    private func dispatch(_ box: CircuitBox, event: NetRomCircuitEvent) {
        let actions = box.machine.handle(event: event)
        var transmitFailed = false

        for action in actions {
            switch action {
            case .send(let frame):
                let datagram = NetRomDatagram(
                    origin: localNode,
                    destination: box.machine.remoteNode,
                    ttl: circuitConfig.ttl,
                    transport: frame
                )
                let encoded = NetRomTransportWire.encode(datagram)
                let sent = onTransmitDatagram?(encoded, box.machine.remoteNode) ?? false
                if !sent { transmitFailed = true }

            case .startT1:
                armTimer(box, kind: .t1, seconds: box.machine.effectiveT1)
            case .stopT1:
                scheduler.cancel(circuit: box.id, timer: .t1)
            case .startT2:
                armTimer(box, kind: .t2, seconds: box.machine.config.t2)
            case .stopT2:
                scheduler.cancel(circuit: box.id, timer: .t2)
            case .startT4:
                armTimer(box, kind: .t4, seconds: box.machine.config.t4)
            case .stopT4:
                scheduler.cancel(circuit: box.id, timer: .t4)

            case .deliverData(let data):
                onCircuitData?(box.id, data)

            case .notifyConnected(let window):
                TxLog.debug(.session, "NET/ROM circuit established", [
                    "circuit": box.id.description,
                    "remote": box.machine.remoteNode.display,
                    "window": window
                ])
                onCircuitConnected?(box.id, window)

            case .notifyDisconnected(let reason):
                TxLog.debug(.session, "NET/ROM circuit closed", [
                    "circuit": box.id.description,
                    "remote": box.machine.remoteNode.display,
                    "reason": String(describing: reason)
                ])
                scheduler.cancelAll(circuit: box.id)
                circuits[box.id] = nil
                onCircuitDisconnected?(box.id, reason)
            }
        }

        // A send that could not be routed fails the circuit — after the
        // action loop, so we never re-enter the machine mid-dispatch.
        if transmitFailed, circuits[box.id] != nil {
            dispatch(box, event: .transportFailure("No route to \(box.machine.remoteNode.display)"))
        }
    }

    private func armTimer(_ box: CircuitBox, kind: NetRomTimerKind, seconds: Double) {
        let circuitID = box.id
        scheduler.schedule(circuit: circuitID, timer: kind, seconds: seconds) { [weak self] in
            guard let self, let box = self.circuits[circuitID] else { return }
            switch kind {
            case .t1: self.dispatch(box, event: .t1Timeout)
            case .t2: self.dispatch(box, event: .t2Timeout)
            case .t4: self.dispatch(box, event: .t4Timeout)
            }
        }
    }
}
