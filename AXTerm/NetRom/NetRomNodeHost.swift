//
//  NetRomNodeHost.swift
//  AXTerm
//
//  The service behind the acceptor: callers land in a NetRomNodeShell,
//  BBS drops them into the mailbox, C bridges them onward through an
//  outbound circuit, and everything they type stays out of the
//  operator's transcript. Callers arrive two ways — inbound NET/ROM
//  circuits, and plain AX.25 sessions to the node alias (a KA-node
//  neighbor cannot open circuits; L2 is the only door it has).
//
//  Runs on the main thread by convention, not isolation: the transport
//  delivers frames there (the same assumption the coordinator's own
//  circuit-data closure has always made), and a MainActor class would
//  abort in deinit when tests tear the coordinator down off-main — the
//  module's documented trap. BBS touch points re-assert isolation.
//
//  Bridging discipline: one caller may hold one outbound circuit; the
//  pipe is transparent both ways; either side dying returns the caller
//  to the node prompt (their link) or tears the outbound down (ours).
//  A dial that has not connected in 60 seconds is abandoned — the
//  circuit layer would otherwise retry CONREQ for six minutes under a
//  caller who has long concluded nothing is happening.
//

import Foundation

/// What the host needs from a mailbox session — a seam so tests can
/// fake the BBS. BBSService.CircuitSession is the real conformer.
// Isolation lives on the METHODS, not the protocol: a MainActor class
// hits the module's isolated-deinit trap (here it corrupted malloc,
// not just aborted — CircuitSession.__deallocating_deinit →
// swift_task_deinitOnExecutorImpl, crash report 2026-08-29 09:17).
nonisolated protocol NodeMailboxSession: AnyObject {
    @MainActor func greeting() -> (lines: [String], prompt: String?)
    /// One line, with the caller's owner console: the mailbox uses it and
    /// hands it back changed, so a sign-in carries between node and mailbox.
    @MainActor func handle(line: String, owner: inout OwnerConsole) -> NodeMailboxReply
}

/// What the mailbox says to one line through the node. Control commands
/// come back for the host to run, since it knows what kind of link the
/// caller is on.
nonisolated struct NodeMailboxReply {
    var lines: [String]
    var prompt: String?
    var closed: Bool
    var controls: [(command: OwnerControlCommand, argument: String)] = []
}

/// What the host needs from the circuit layer — a seam so tests can
/// fake the driver. NetRomLinkDriver is the real conformer.
nonisolated protocol NodeCircuitOps: AnyObject {
    func send(_ data: Data, on id: NetRomCircuitID)
    func disconnect(_ id: NetRomCircuitID)
    /// Nil when no route exists — the only distinction the host acts on.
    func openNodeCircuit(to destination: AX25Address) -> NetRomCircuitID?
}

// The driver is nonisolated and so is `NodeCircuitOps`; only this
// extension was not, because an un-annotated declaration defaults to the
// main actor. That made the conformance main-actor-isolated and unusable
// from the nonisolated host that exists to call it.
nonisolated extension NetRomLinkDriver: NodeCircuitOps {
    func openNodeCircuit(to destination: AX25Address) -> NetRomCircuitID? {
        switch openCircuit(to: destination) {
        case .success(let id): return id
        case .failure: return nil
        }
    }
}

nonisolated final class NetRomNodeHost {

    /// How a caller reached us, and therefore how bytes go back.
    enum CallerKey: Hashable {
        case circuit(NetRomCircuitID)
        case ax25(String)
    }

    /// A caller mid-session.
    private enum Mode {
        case node(NetRomNodeShell)
        case bbs(NodeMailboxSession)
        /// C issued; outbound circuit dialing.
        case dialing(target: String, outbound: NetRomCircuitID)
        /// Transparent pipe to the far station.
        case bridged(target: String, outbound: NetRomCircuitID)
    }

    private struct Caller {
        var callsign: String
        var mode: Mode
        var buffer = Data()
        /// How to write to this caller. Circuits use the driver; AX.25
        /// callers carry their own writer from the coordinator.
        var send: (Data) -> Void
        var hangUp: () -> Void
        /// The owner's sign-in on this link, kept across node and mailbox.
        var owner: OwnerConsole
        /// What decides whether this link may change the station.
        var facts: RemoteControlService.LinkFacts
    }

    /// The operator's switch, pushed from settings.
    var isEnabled = false
    /// A circuit caller's first bytes were AXDP, not typing: another AXTerm
    /// that wants a conversation, not the node prompt. The host lets the
    /// circuit go and hands over what arrived (Docs/RemoteAccessPlan.md).
    var onAXDPCircuit: ((NetRomCircuitID, _ caller: String, _ data: Data) -> Void)?

    // Injected by the shell that owns the stores.
    var identityProvider: () -> (alias: String, call: String, version: String) =
        { ("NODE", "N0CALL", "AXTerm") }
    var snapshotProvider: () -> NetRomNodeShell.Snapshot = { .init() }
    var bbsSessionFactory: (@MainActor (String) -> NodeMailboxSession?)?
    /// The station's remote control, shared with the mailbox.
    var remoteControlProvider: (@MainActor () -> RemoteControlService?)?
    var onOperatorNote: ((String) -> Void)?
    /// Test seam for the dial timeout.
    // `@Sendable`, because the default implementation hands the closure to
    // `DispatchQueue.asyncAfter`, which runs it on another thread and asks
    // for that guarantee.
    var scheduleTimeout: (_ seconds: Double, _ work: @escaping @Sendable () -> Void) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private weak var circuitOps: (any NodeCircuitOps)?
    private var callers: [CallerKey: Caller] = [:]
    /// Inbound circuits accepted but not yet connected — greeting waits
    /// for CONACK.
    private var pending: [NetRomCircuitID: String] = [:]
    /// Outbound bridge circuits, back to the caller that owns each.
    private var bridges: [NetRomCircuitID: CallerKey] = [:]

    var activeCallerCount: Int { callers.count + pending.count }

    /// Chains onto the driver's callbacks. Must run AFTER the
    /// coordinator's own wiring so the previous data consumer is
    /// preserved for circuits this host does not own.
    func install(on driver: NetRomLinkDriver) {
        self.circuitOps = driver

        driver.endpoint.inboundAcceptor = { [weak self] user, _ in
            guard let self else { return false }
            let accept = NetRomInboundPolicy.shouldAccept(
                enabled: self.isEnabled,
                activeCallers: self.activeCallerCount)
            if !accept, self.isEnabled {
                TxLog.debug(.session, "Inbound circuit refused: at capacity", [
                    "caller": user.display
                ])
            }
            return accept
        }
        driver.endpoint.onInboundCircuitOpened = { [weak self] id, user, _ in
            self?.inboundCircuitOpened(id, caller: user.display)
        }
        driver.hostedCircuitCheck = { [weak self] id in
            guard let self else { return false }
            return self.callers[.circuit(id)] != nil
                || self.pending[id] != nil
                || self.bridges[id] != nil
        }
        driver.onCircuitBecameConnected = { [weak self] id in
            self?.circuitConnected(id)
        }
        driver.onCircuitTornDown = { [weak self] id in
            self?.circuitClosed(id)
        }

        let previousData = driver.onCircuitData
        driver.onCircuitData = { [weak self] id, data in
            if self?.consumeCircuit(id: id, data: data) ?? false { return }
            previousData?(id, data)
        }
    }

    // MARK: - AX.25 callers (the KA-node neighbor's door)

    /// The coordinator answered a SABM at the node alias and claimed the
    /// session; from here the caller is ours.
    /// `dialed` is the address the caller connected to, usually the alias:
    /// their device signs owner commands for that name.
    func attachAX25Caller(key: String, callsign: String, dialed: String = "",
                          radio: RadioID? = nil, digipeated: Bool = false,
                          send: @escaping (Data) -> Void,
                          hangUp: @escaping () -> Void) {
        let identity = identityProvider()
        let owner = OwnerConsole(caller: callsign, station: dialed.isEmpty ? identity.alias : dialed.uppercased(),
                                 ownerCallsign: identity.call)
        let shell = NetRomNodeShell(
            nodeAlias: identity.alias, nodeCall: identity.call,
            version: identity.version, caller: callsign, owner: owner)
        callers[.ax25(key)] = Caller(
            callsign: callsign, mode: .node(shell), send: send, hangUp: hangUp, owner: owner,
            facts: .init(radio: radio, digipeated: digipeated, relayed: false))
        write(shell.greeting(snapshot: snapshotProvider()), to: .ax25(key))
        onOperatorNote?("\(callsign) connected to this node over AX.25.")
    }

    func ax25CallerReceived(key: String, data: Data) {
        consume(key: .ax25(key), data: data)
    }

    /// `failed` when the link gave up rather than being closed: the
    /// remote control's fail-safe puts back what the caller changed.
    func ax25CallerClosed(key: String, failed: Bool = false) {
        callerLeft(.ax25(key), failed: failed)
    }

    // MARK: - Circuit lifecycle

    /// Endpoint callback; also the test seam for inbound arrival.
    func inboundCircuitOpened(_ id: NetRomCircuitID, caller: String) {
        pending[id] = caller
    }

    /// Test seam: lets a fake circuit layer stand in for the driver.
    func useCircuitOps(_ ops: any NodeCircuitOps) {
        circuitOps = ops
    }

    /// Driver callback; also the test seam for circuit lifecycle.
    func circuitConnected(_ id: NetRomCircuitID) {
        if let callsign = pending.removeValue(forKey: id) {
            let identity = identityProvider()
            let owner = OwnerConsole(caller: callsign, station: identity.call)
            let shell = NetRomNodeShell(
                nodeAlias: identity.alias, nodeCall: identity.call,
                version: identity.version, caller: callsign, owner: owner)
            let key = CallerKey.circuit(id)
            // Other stations relay a circuit: it may read the station, not
            // change it (97.213 wants a direct control link).
            callers[key] = Caller(
                callsign: callsign, mode: .node(shell),
                send: { [weak self] data in self?.circuitOps?.send(data, on: id) },
                hangUp: { [weak self] in self?.circuitOps?.disconnect(id) },
                owner: owner, facts: .init(radio: nil, digipeated: false, relayed: true))
            write(shell.greeting(snapshot: snapshotProvider()), to: key)
            onOperatorNote?("\(callsign) connected to this node over NET/ROM.")
            return
        }
        // An outbound bridge came up: the caller is through.
        if let owner = bridges[id], var caller = callers[owner],
           case .dialing(let target, let outbound) = caller.mode, outbound == id {
            caller.mode = .bridged(target: target, outbound: id)
            callers[owner] = caller
            writeLines(["*** Connected to \(target)"], prompt: nil, to: owner)
        }
    }

    /// Driver callback; also the test seam for circuit lifecycle.
    func circuitClosed(_ id: NetRomCircuitID) {
        pending.removeValue(forKey: id)
        if callers[.circuit(id)] != nil {
            callerLeft(.circuit(id), failed: true)
            return
        }
        // An outbound bridge died. The caller comes back to the prompt.
        if let owner = bridges.removeValue(forKey: id), var caller = callers[owner] {
            let identity = identityProvider()
            let shell = NetRomNodeShell(
                nodeAlias: identity.alias, nodeCall: identity.call,
                version: identity.version, caller: caller.callsign, owner: caller.owner)
            switch caller.mode {
            case .dialing(let target, _):
                caller.mode = .node(shell)
                callers[owner] = caller
                writeLines(["*** Failure with \(target)"],
                           prompt: shell.greeting().prompt, to: owner)
            case .bridged(let target, _):
                caller.mode = .node(shell)
                callers[owner] = caller
                writeLines(["*** Disconnected from \(target) — back at the node."],
                           prompt: shell.greeting().prompt, to: owner)
            default:
                break
            }
        }
    }

    private func callerLeft(_ key: CallerKey, failed: Bool = false) {
        guard let caller = callers.removeValue(forKey: key) else { return }
        let link = controlLink(key)
        MainActor.assumeIsolated { remoteControlProvider?()?.linkEnded(link, failed: failed) }
        // Take any bridge down with its owner.
        switch caller.mode {
        case .dialing(_, let outbound), .bridged(_, let outbound):
            bridges.removeValue(forKey: outbound)
            circuitOps?.disconnect(outbound)
        default:
            break
        }
        onOperatorNote?("\(caller.callsign) left this node.")
    }

    // MARK: - Data

    /// Driver callback; also the test seam for circuit data.
    @discardableResult
    func consumeCircuit(id: NetRomCircuitID, data: Data) -> Bool {
        if callers[.circuit(id)] != nil {
            consume(key: .circuit(id), data: data)
            return true
        }
        // Data from the far side of a bridge flows straight to the caller.
        if let owner = bridges[id], let caller = callers[owner] {
            caller.send(data)
            return true
        }
        return false
    }

    private func consume(key: CallerKey, data: Data) {
        guard var caller = callers[key] else { return }
        // Heard from the caller: their link is working.
        let link = controlLink(key)
        MainActor.assumeIsolated { remoteControlProvider?()?.heard(link) }
        // AXDP at the prompt, before anything was typed: hand the circuit to
        // the station's AXDP conversation and stop hosting it.
        if case .circuit(let id) = key, case .node = caller.mode, caller.buffer.isEmpty,
           AXDP.hasMagic(data), let onAXDPCircuit {
            callers.removeValue(forKey: key)
            onOperatorNote?("\(caller.callsign) is talking AXDP over NET/ROM; the node let the circuit go.")
            onAXDPCircuit(id, caller.callsign, data)
            return
        }
        // Bridged callers are a transparent pipe — no line assembly, no
        // command interception; BYE belongs to the far node now.
        if case .bridged(_, let outbound) = caller.mode {
            circuitOps?.send(data, on: outbound)
            return
        }
        // While dialing, keystrokes have nowhere meaningful to go; a
        // caller mashing Return must not leak into the far session that
        // is about to exist.
        if case .dialing = caller.mode { return }

        caller.buffer.append(data)
        callers[key] = caller
        drainLines(key)
    }

    private func drainLines(_ key: CallerKey) {
        while var caller = callers[key],
              let index = caller.buffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let lineBytes = caller.buffer[caller.buffer.startIndex..<index]
            caller.buffer.removeSubrange(caller.buffer.startIndex...index)
            callers[key] = caller
            let line = String(decoding: lineBytes, as: UTF8.self)
            process(line: line, on: key)
        }
    }

    private func process(line: String, on key: CallerKey) {
        guard var caller = callers[key] else { return }
        // The owner settings as they are now, before the line is read.
        MainActor.assumeIsolated { remoteControlProvider?()?.refresh(&caller.owner) }
        switch caller.mode {
        case .node(var shell):
            shell.owner = caller.owner
            let output = shell.handle(
                line: line, snapshot: snapshotProvider(), now: Date())
            callers[key]?.owner = shell.owner
            callers[key]?.mode = .node(shell)
            write(output, to: key)
            for effect in output.effects {
                switch effect {
                case .disconnect:
                    callers[key]?.hangUp()
                case .enterBBS:
                    enterBBS(key, caller: caller.callsign)
                case .connectOnward(let target):
                    dial(target, for: key)
                case .ownerSignIn(let accepted):
                    let text = accepted ? "signed in as the owner" : "gave a wrong owner code"
                    onOperatorNote?("\(caller.callsign) \(text) at the node.")
                    MainActor.assumeIsolated {
                        remoteControlProvider?()?.record(text, caller: caller.callsign, door: "node")
                    }
                case .runControl(let command, let argument):
                    runControl(command, argument: argument, for: key, prompt: shell.greeting().prompt)
                }
            }
        case .bbs(let session):
            var owner = caller.owner
            let result = MainActor.assumeIsolated { session.handle(line: line, owner: &owner) }
            callers[key]?.owner = owner
            writeLines(result.lines, prompt: result.controls.isEmpty ? result.prompt : nil, to: key)
            for control in result.controls {
                runControl(control.command, argument: control.argument, for: key, prompt: result.prompt)
            }
            if result.closed {
                // Leaving the mailbox returns to the node level, the way
                // BPQ does — the caller said BYE to the BBS, not to us.
                let identity = identityProvider()
                let shell = NetRomNodeShell(
                    nodeAlias: identity.alias, nodeCall: identity.call,
                    version: identity.version, caller: caller.callsign, owner: owner)
                callers[key]?.mode = .node(shell)
                writeLines(["Back at the node."],
                           prompt: shell.greeting().prompt, to: key)
            }
        case .dialing, .bridged:
            break // handled byte-wise in consume()
        }
    }

    // MARK: - Remote control

    /// The fail-safe's name for a caller's link.
    private func controlLink(_ key: CallerKey) -> String {
        switch key {
        case .ax25(let session): return "node:ax25:\(session)"
        case .circuit(let id): return "node:circuit:\(id)"
        }
    }

    /// Runs a control command through the station's remote control, with
    /// what the host knows about the caller's link, then the prompt.
    private func runControl(_ command: OwnerControlCommand, argument: String, for key: CallerKey, prompt: String?) {
        guard let caller = callers[key] else { return }
        let link = controlLink(key)
        let ran = MainActor.assumeIsolated { () -> Bool in
            guard let control = remoteControlProvider?() else { return false }
            control.run(command, argument: argument, link: link, facts: caller.facts, caller: caller.callsign,
                        door: "node", write: { [weak self] lines in
                            // The prompt arrives as the last line; it is
                            // written as a prompt, without a line end.
                            var body = lines
                            var promptLine: String?
                            if let prompt, body.last == prompt {
                                body.removeLast()
                                promptLine = prompt
                            }
                            self?.writeLines(body, prompt: promptLine, to: key)
                        }, prompt: prompt)
            return true
        }
        if !ran {
            writeLines(["Remote control is not running at this station."], prompt: prompt, to: key)
        }
    }

    // MARK: - C: onward connects

    private func dial(_ target: String, for key: CallerKey) {
        guard let ops = circuitOps else { return }
        let address = CallsignNormalizer.toAddress(target)
        switch ops.openNodeCircuit(to: address) {
        case .some(let outbound):
            bridges[outbound] = key
            callers[key]?.mode = .dialing(target: target, outbound: outbound)
            onOperatorNote?("\(callers[key]?.callsign ?? "A caller") is being "
                            + "bridged toward \(target).")
            // The circuit layer retries CONREQ for minutes; a caller
            // staring at silence deserves an answer sooner.
            scheduleTimeout(60) { [weak self] in
                guard let self,
                      let caller = self.callers[key],
                      case .dialing(_, let pendingOutbound) = caller.mode,
                      pendingOutbound == outbound else { return }
                self.circuitOps?.disconnect(outbound)
                // circuitClosed delivers "*** Failure with …".
            }
        case .none:
            let identity = identityProvider()
            writeLines(["*** No route to \(target)"],
                       prompt: "\(identity.alias):\(identity.call)} ", to: key)
        }
    }

    // MARK: - BBS

    private func enterBBS(_ key: CallerKey, caller: String) {
        let session = MainActor.assumeIsolated { bbsSessionFactory?(caller) }
        guard let session else {
            // The shell only offers BBS when the snapshot said it was on
            // the air, but the mailbox can wink out between keystrokes.
            let identity = identityProvider()
            writeLines(["The mailbox is not on the air."],
                       prompt: "\(identity.alias):\(identity.call)} ", to: key)
            return
        }
        callers[key]?.mode = .bbs(session)
        let greeting = MainActor.assumeIsolated { session.greeting() }
        writeLines(greeting.lines, prompt: greeting.prompt, to: key)
    }

    // MARK: - Output

    private func write(_ output: NetRomNodeShell.Output, to key: CallerKey) {
        writeLines(output.lines, prompt: output.prompt, to: key)
    }

    private func writeLines(_ lines: [String], prompt: String?, to key: CallerKey) {
        var text = lines.map { $0 + "\r" }.joined()
        if let prompt { text += prompt }
        guard !text.isEmpty, let caller = callers[key] else { return }
        caller.send(Data(text.utf8))
    }
}
