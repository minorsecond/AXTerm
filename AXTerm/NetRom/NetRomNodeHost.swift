//
//  NetRomNodeHost.swift
//  AXTerm
//
//  The service behind the acceptor: inbound circuits land in a
//  NetRomNodeShell, BBS drops them into the mailbox, and everything
//  the caller types stays out of the operator's transcript. Owned by
//  SessionCoordinator; providers are injected by the shell that has
//  the stores (ContentView), following the nodeAliases pattern.
//
//  Runs on the main thread by convention, not isolation: the transport
//  delivers frames there (the same assumption the coordinator's own
//  circuit-data closure has always made), and a MainActor class would
//  abort in deinit when tests tear the coordinator down off-main — the
//  module's documented trap. BBS touch points re-assert isolation.
//

import Foundation

nonisolated final class NetRomNodeHost {

    /// A caller mid-session: at the node prompt, or handed to the BBS.
    private enum Mode {
        case node(NetRomNodeShell)
        case bbs(BBSService.CircuitSession)
    }

    private struct Caller {
        var callsign: String
        var mode: Mode
        var buffer = Data()
    }

    /// The operator's switch, pushed from settings.
    var isEnabled = false

    // Injected by the shell that owns the stores.
    var identityProvider: () -> (alias: String, call: String, version: String) =
        { ("NODE", "N0CALL", "AXTerm") }
    var snapshotProvider: () -> NetRomNodeShell.Snapshot = { .init() }
    var bbsSessionFactory: (@MainActor (String) -> BBSService.CircuitSession?)?
    var onOperatorNote: ((String) -> Void)?

    private weak var driver: NetRomLinkDriver?
    private var callers: [NetRomCircuitID: Caller] = [:]
    /// Accepted but not yet connected — the greeting waits for CONACK.
    private var pending: [NetRomCircuitID: String] = [:]

    var activeCallerCount: Int { callers.count + pending.count }

    /// Chains onto the driver's callbacks. Must run AFTER the
    /// coordinator's own wiring so the previous data consumer is
    /// preserved for circuits this host does not own.
    func install(on driver: NetRomLinkDriver) {
        self.driver = driver

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
            self?.pending[id] = user.display
        }
        driver.hostedCircuitCheck = { [weak self] id in
            guard let self else { return false }
            return self.callers[id] != nil || self.pending[id] != nil
        }
        driver.onCircuitBecameConnected = { [weak self] id in
            self?.circuitConnected(id)
        }
        driver.onCircuitTornDown = { [weak self] id in
            self?.circuitClosed(id)
        }

        let previousData = driver.onCircuitData
        driver.onCircuitData = { [weak self] id, data in
            if self?.consume(id: id, data: data) ?? false { return }
            previousData?(id, data)
        }
    }

    // MARK: - Lifecycle

    private func circuitConnected(_ id: NetRomCircuitID) {
        guard let callsign = pending.removeValue(forKey: id) else { return }
        let identity = identityProvider()
        let shell = NetRomNodeShell(
            nodeAlias: identity.alias, nodeCall: identity.call,
            version: identity.version, caller: callsign)
        callers[id] = Caller(callsign: callsign, mode: .node(shell))
        write(shell.greeting(), to: id)
        onOperatorNote?("\(callsign) connected to this node over NET/ROM.")
    }

    private func circuitClosed(_ id: NetRomCircuitID) {
        pending.removeValue(forKey: id)
        if let caller = callers.removeValue(forKey: id) {
            onOperatorNote?("\(caller.callsign) left this node.")
        }
    }

    // MARK: - Data

    /// Returns true when this host owns the circuit and consumed the
    /// bytes; false hands them to whoever was wired before us.
    private func consume(id: NetRomCircuitID, data: Data) -> Bool {
        guard callers[id] != nil else { return false }
        callers[id]?.buffer.append(data)
        drainLines(id)
        return true
    }

    private func drainLines(_ id: NetRomCircuitID) {
        while var caller = callers[id],
              let index = caller.buffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let lineBytes = caller.buffer[caller.buffer.startIndex..<index]
            caller.buffer.removeSubrange(caller.buffer.startIndex...index)
            callers[id] = caller
            let line = String(decoding: lineBytes, as: UTF8.self)
            process(line: line, on: id)
        }
    }

    private func process(line: String, on id: NetRomCircuitID) {
        guard let caller = callers[id] else { return }
        switch caller.mode {
        case .node(var shell):
            let output = shell.handle(
                line: line, snapshot: snapshotProvider(), now: Date())
            callers[id]?.mode = .node(shell)
            write(output, to: id)
            for effect in output.effects {
                switch effect {
                case .disconnect:
                    driver?.disconnect(id)
                case .enterBBS:
                    enterBBS(id, caller: caller.callsign)
                }
            }
        case .bbs(let session):
            let result = MainActor.assumeIsolated { session.handle(line: line) }
            writeLines(result.lines, prompt: result.prompt, to: id)
            if result.closed {
                // Leaving the mailbox returns to the node level, the way
                // BPQ does — the caller said BYE to the BBS, not to us.
                let identity = identityProvider()
                let shell = NetRomNodeShell(
                    nodeAlias: identity.alias, nodeCall: identity.call,
                    version: identity.version, caller: caller.callsign)
                callers[id]?.mode = .node(shell)
                writeLines(["Back at the node."], prompt: shell.greeting().prompt, to: id)
            }
        }
    }

    private func enterBBS(_ id: NetRomCircuitID, caller: String) {
        let session = MainActor.assumeIsolated { bbsSessionFactory?(caller) }
        guard let session else {
            // The shell only offers BBS when the snapshot said it was on
            // the air, but the mailbox can wink out between keystrokes.
            let identity = identityProvider()
            writeLines(["The mailbox is not on the air."],
                       prompt: "\(identity.alias):\(identity.call)} ", to: id)
            return
        }
        callers[id]?.mode = .bbs(session)
        let greeting = MainActor.assumeIsolated { session.greeting() }
        writeLines(greeting.lines, prompt: greeting.prompt, to: id)
    }

    // MARK: - Output

    private func write(_ output: NetRomNodeShell.Output, to id: NetRomCircuitID) {
        writeLines(output.lines, prompt: output.prompt, to: id)
    }

    private func writeLines(_ lines: [String], prompt: String?, to id: NetRomCircuitID) {
        var text = lines.map { $0 + "\r" }.joined()
        if let prompt { text += prompt }
        guard !text.isEmpty, let driver else { return }
        driver.send(Data(text.utf8), on: id)
    }
}
