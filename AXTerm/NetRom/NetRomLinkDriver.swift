//
//  NetRomLinkDriver.swift
//  AXTerm
//
//  Binds the NET/ROM transport (NetRomEndpoint) to real AX.25 neighbor
//  links and to this station's route table.
//
//  The endpoint speaks L3/L4 and knows nothing about radios; the session
//  manager speaks AX.25 and knows nothing about NET/ROM. This is the
//  seam between them, and it owns exactly three decisions:
//
//   1. **Which neighbor carries a destination.** Resolved once from the
//      route table when a circuit opens, then *pinned* for that
//      circuit's lifetime. Routes decay and re-rank continuously; a
//      circuit that changed next hop mid-stream would strand its
//      sequence state at the old neighbor.
//   2. **Whether a datagram fits.** One NET/ROM datagram must ride one
//      I-frame — the receiver parses each I-frame as a whole datagram,
//      so a fragmented one decodes as garbage. Fragment sizing comes
//      from the neighbor link's paclen at open, and an oversized
//      datagram is refused rather than split (see `datagramCapacity`).
//   3. **What a dead link means.** When the L2 session to a neighbor
//      drops, every circuit pinned to it fails immediately instead of
//      retrying into a void until N2.
//
//  Everything the driver needs from the rest of the app arrives through
//  `NetRomLinkTransport` and the next-hop resolver, so the whole thing
//  is testable without a radio.
//

import Foundation
import Combine

// MARK: - Transport seam

/// What the driver needs from the AX.25 layer.
nonisolated protocol NetRomLinkTransport: AnyObject {
    /// Largest NET/ROM datagram, in bytes, that will ride a single
    /// I-frame to this neighbor right now — i.e. the link's paclen.
    /// `nil` means the neighbor is unusable (no port, no session
    /// possible).
    func datagramCapacity(toNeighbor neighbor: AX25Address) -> Int?

    /// Send one datagram as a single PID-0xCF I-frame to `neighbor`,
    /// establishing the L2 link first if needed. Returns false only if
    /// it could not be accepted at all; a datagram queued behind a
    /// pending SABM counts as accepted.
    func sendDatagram(_ data: Data, toNeighbor neighbor: AX25Address) -> Bool

    /// Send one unconnected UI frame to "NODES" with PID 0xCF — a
    /// routing broadcast, heard by every neighbor at once.
    /// - Parameter summary: what the frame contains, for the console.
    ///   The payload is binary, so without this the operator sees a
    ///   broadcast go out and has no way to learn what was in it.
    func sendNodesBroadcast(_ payload: Data, summary: String) -> Bool
}

// MARK: - UI-facing summary

nonisolated struct NetRomCircuitSummary: Identifiable, Equatable, Sendable {
    let id: NetRomCircuitID
    /// The far endpoint as addressed on the air — always a callsign when
    /// one could be resolved.
    let destination: AX25Address
    /// The alias the operator named, when it differs from `destination`.
    /// Kept so the Terminal can still say "COSCO" for a circuit whose
    /// L3 header carries KE0GB-7.
    var requestedAlias: String? = nil
    /// The neighbor actually carrying it.
    let neighbor: AX25Address
    let state: NetRomCircuitState
    let openedAt: Date

    /// What to call this circuit: the alias the operator knows, with the
    /// callsign actually on the air.
    var displayName: String {
        guard let requestedAlias, requestedAlias != destination.display else {
            return destination.display
        }
        return "\(requestedAlias) (\(destination.display))"
    }

    /// One line an operator can read without knowing the protocol.
    var statusLine: String {
        switch state {
        case .connecting:
            return "Asking \(neighbor.display) to reach \(displayName)…"
        case .connected:
            return neighbor.display == destination.display
                ? "Circuit to \(displayName)"
                : "Circuit to \(displayName) through \(neighbor.display)"
        case .disconnecting:
            return "Closing the circuit to \(displayName)…"
        case .disconnected:
            return "Circuit to \(displayName) closed"
        }
    }
}

// MARK: - Driver

/// `nonisolated` for the same reason `NetRomEndpoint` is: an implicitly
/// MainActor-isolated class gets an isolated deinit, which aborts in
/// libmalloc under the test runner on this toolchain (see
/// [[axterm-mainactor-default-isolation]]). Discipline is by
/// convention instead — every entry point is called from the main
/// thread, which is where SessionCoordinator drives it, so the
/// `@Published` updates below reach SwiftUI on the main actor.
nonisolated final class NetRomLinkDriver: ObservableObject {

    /// Live circuits, for the Terminal.
    @Published private(set) var circuits: [NetRomCircuitSummary] = []

    let endpoint: NetRomEndpoint
    /// Held strongly. The adapter on the other side keeps its own
    /// reference to the coordinator weak, so there is no cycle — and a
    /// weak reference here would deallocate the adapter the moment it
    /// was installed, silently disabling every circuit.
    private var transport: NetRomLinkTransport?

    /// Destination display string → next-hop neighbor display string.
    /// Supplied by the route table (`NetRomIntegration.bestRouteTo`).
    var nextHopResolver: ((String) -> String?)?

    /// Every known next hop for a destination, best first. Auto-try
    /// walks it; nil or empty means "only the best hop is known".
    var candidateHopsResolver: ((String) -> [String])?

    /// What this station can reach, for the NODES broadcast. Only
    /// consulted when `forwardingEnabled` — advertising a route we will
    /// not carry black-holes the network.
    var advertisableRoutesProvider: (() -> [NetRomNodesBroadcast.KnownRoute])?

    /// Alias → callsign, from the node directory. NET/ROM addresses
    /// stations by callsign; operators and node tables name them by
    /// alias, and the L3 header must carry the callsign.
    var callsignForAliasResolver: ((String) -> String?)?

    /// This station's node alias, as it appears in NODES broadcasts.
    var localAlias: String = ""

    /// Announce this station to the network. **Off by default**: every
    /// neighbor that hears a broadcast writes this station into its
    /// routing table, which is a change to other people's networks and
    /// should be a deliberate act.
    var advertisesItself = false

    /// Carry other stations' traffic. **Off by default**: transit
    /// routing spends this station's airtime on other people's packets
    /// and makes it responsible for delivering them.
    var forwardingEnabled = false

    /// Called with operator-readable text for the Terminal transcript.
    var onOperatorNote: ((String) -> Void)?
    /// Payload delivered on a circuit.
    var onCircuitData: ((NetRomCircuitID, Data) -> Void)?
    /// Fired just before `circuits` changes. A nested ObservableObject
    /// does not republish through its owner, so the owner forwards this
    /// to its own `objectWillChange` — otherwise the sidebar would hold
    /// a stale circuit list forever.
    var onCircuitsWillChange: (() -> Void)?

    /// Destination → the neighbor pinned to carry it.
    private var pinnedNeighbor: [String: AX25Address] = [:]
    /// Bookkeeping for the summaries.
    private var opened: [NetRomCircuitID: Date] = [:]
    /// One auto-try campaign per destination.
    private var campaigns: [String: NetRomAutoTryCampaign] = [:]
    /// Resolved callsign → the alias the operator named it by.
    private var requestedAlias: [String: String] = [:]

    private let clock: () -> Date

    init(
        localNode: AX25Address,
        localUser: AX25Address,
        transport: NetRomLinkTransport?,
        circuitConfig: NetRomCircuitConfig = NetRomCircuitConfig(),
        scheduler: NetRomTimerScheduler? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.endpoint = NetRomEndpoint(
            localNode: localNode,
            localUser: localUser,
            circuitConfig: circuitConfig,
            scheduler: scheduler
        )
        self.transport = transport
        self.clock = clock
        wireEndpoint()
    }

    // MARK: Identity

    var localNode: AX25Address {
        get { endpoint.localNode }
        set { endpoint.localNode = newValue }
    }

    var localUser: AX25Address {
        get { endpoint.localUser }
        set { endpoint.localUser = newValue }
    }

    func setTransport(_ transport: NetRomLinkTransport?) {
        self.transport = transport
    }

    // MARK: Naming

    /// Turn an operator-supplied name into the address that goes in the
    /// L3 header, remembering the alias for display.
    func resolveDestination(_ name: String) -> NetRomDestinationResolver.Resolution {
        let resolution = NetRomDestinationResolver.resolve(name) { [weak self] alias in
            self?.callsignForAliasResolver?(alias)
        }
        if let alias = resolution.requestedAlias {
            requestedAlias[Self.key(resolution.address)] = alias
        }
        return resolution
    }

    /// Next hop for a destination, trying both the callsign and the
    /// alias it was named by — the route table is keyed by whatever the
    /// broadcast said, and that may be either form.
    private func hopText(for resolution: NetRomDestinationResolver.Resolution) -> String? {
        for key in NetRomDestinationResolver.routeLookupKeys(for: resolution) {
            if let hop = nextHopResolver?(key), !hop.isEmpty { return hop }
        }
        return nil
    }

    // MARK: Opening a circuit

    enum OpenFailure: Error, Equatable {
        case noRoute(String)
        case neighborUnusable(String)

        var operatorText: String {
            switch self {
            case .noRoute(let destination):
                return "No NET/ROM route to \(destination). "
                    + "This station has not heard a node advertise it."
            case .neighborUnusable(let neighbor):
                return "Cannot reach \(neighbor) right now, so the circuit was not opened."
            }
        }
    }

    /// Open a native NET/ROM circuit to `destination`, choosing the next
    /// hop from the route table.
    func openCircuit(to named: AX25Address) -> Result<NetRomCircuitID, OpenFailure> {
        // NET/ROM addresses by callsign; the operator may have named an
        // alias. Resolve before anything touches the air.
        let resolution = resolveDestination(named.display)
        let destination = resolution.address
        let key = Self.key(destination)

        guard let hopText = hopText(for: resolution), !hopText.isEmpty else {
            return .failure(.noRoute(resolution.displayName))
        }
        let neighbor = CallsignNormalizer.toAddress(hopText)

        // Size fragments to what this neighbor's link will actually
        // carry in one I-frame. 20 bytes of NET/ROM header ride in
        // front of every payload.
        guard let capacity = transport?.datagramCapacity(toNeighbor: neighbor),
              capacity > NetRomWire.headerLength else {
            return .failure(.neighborUnusable(neighbor.display))
        }
        var config = endpoint.circuitConfig
        config.maxInfoPayload = max(
            Self.minimumInfoPayload,
            min(NetRomWire.maxInfoPayload, capacity - NetRomWire.headerLength)
        )
        endpoint.circuitConfig = config

        pinnedNeighbor[key] = neighbor
        let id = endpoint.openCircuit(to: destination)
        opened[id] = clock()
        refreshCircuits()

        if neighbor.display == destination.display {
            onOperatorNote?("Opening a NET/ROM circuit to \(resolution.displayName).")
        } else {
            onOperatorNote?(
                "Opening a NET/ROM circuit to \(resolution.displayName) through "
                + "\(neighbor.display) — that is this station's best known route.")
        }
        return .success(id)
    }

    func send(_ data: Data, on id: NetRomCircuitID) {
        endpoint.send(data, on: id)
    }

    func disconnect(_ id: NetRomCircuitID) {
        endpoint.disconnect(id)
        refreshCircuits()
    }

    func circuit(for id: NetRomCircuitID) -> NetRomCircuitSummary? {
        circuits.first { $0.id == id }
    }

    func circuitState(_ id: NetRomCircuitID) -> NetRomCircuitState? {
        endpoint.circuitState(id)
    }

    // MARK: Inbound

    /// One PID-0xCF I-frame payload arrived on a connected session.
    func handleInboundDatagram(_ data: Data, fromNeighbor neighbor: AX25Address) {
        // Reply toward whoever this came from, by the path it came in
        // on: a circuit's two directions must agree on the neighbor even
        // when the route table would now prefer another.
        if let datagram = NetRomTransportWire.parse(data) {
            let originKey = Self.key(datagram.origin)
            if pinnedNeighbor[originKey] == nil {
                pinnedNeighbor[originKey] = neighbor
            }
        }
        endpoint.handleInboundDatagram(data, fromNeighbor: neighbor)
        refreshCircuits()
    }

    /// The L2 link to `neighbor` went down. Every circuit riding it is
    /// finished — say so now rather than retrying into a dead link.
    func neighborLinkDropped(_ neighbor: AX25Address) {
        let doomed = endpoint.liveCircuits().filter { entry in
            pinnedNeighbor[Self.key(entry.remote)].map {
                CallsignNormalizer.addressesMatch($0, neighbor)
            } ?? false
        }
        guard !doomed.isEmpty else { return }
        for entry in doomed {
            endpoint.failCircuit(entry.id, reason: "Link to \(neighbor.display) dropped")
        }
        refreshCircuits()
    }

    // MARK: Announcing this station

    /// Send this station's NODES broadcast. Returns the number of frames
    /// put on the air — zero when announcing is off, which is the
    /// default.
    ///
    /// With forwarding off this advertises exactly one destination:
    /// ourselves. That is the whole truth about what we will carry, and
    /// advertising more would invite traffic into a black hole.
    @discardableResult
    func broadcastNodes() -> Int {
        guard advertisesItself else { return 0 }
        let routes = forwardingEnabled ? (advertisableRoutesProvider?() ?? []) : []
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: endpoint.localNode,
            localAlias: localAlias,
            forwarding: forwardingEnabled,
            routes: routes,
            callsignForAlias: { [weak self] alias in
                self?.callsignForAliasResolver?(alias)
            }
        )
        let payloads = NetRomNodesBroadcast.encode(originAlias: localAlias, entries: entries)
        let summary = Self.summarize(alias: localAlias, entries: entries)
        var sent = 0
        for payload in payloads
        where transport?.sendNodesBroadcast(payload, summary: summary) == true {
            sent += 1
        }
        if sent > 0 {
            TxLog.debug(.session, "NET/ROM NODES broadcast sent", [
                "frames": sent,
                "entries": entries.count,
                "forwarding": forwardingEnabled,
                "contents": summary
            ])
            onOperatorNote?("Announced \(summary).")
        }
        return sent
    }

    /// What went out, in words.
    ///
    /// A NODES broadcast is binary, so the console could only ever say that
    /// one happened — "Announced this station to the network" was true of a
    /// frame carrying one entry and of a frame carrying eleven, and the
    /// operator had no way to tell which had just left the antenna, or
    /// which destinations they had promised to carry (2026-08-27).
    static func summarize(alias: String, entries: [NetRomNodesBroadcast.Entry]) -> String {
        let name = alias.trimmingCharacters(in: .whitespaces).isEmpty
            ? "this station (no alias set)"
            : "this station as \(alias.trimmingCharacters(in: .whitespaces))"
        // The first entry is always ourselves; the rest are promises.
        let routes = entries.dropFirst()
        guard !routes.isEmpty else { return name }
        let named = routes.prefix(6).map { entry -> String in
            let alias = entry.alias.trimmingCharacters(in: .whitespaces)
            return alias.isEmpty ? entry.destination.display : alias
        }
        let listed = named.joined(separator: ", ")
        let rest = routes.count - named.count
        return rest > 0
            ? "\(name), and routes to \(listed) and \(rest) more"
            : "\(name), and routes to \(listed)"
    }

    /// Open a circuit to `destination`, trying every route this station
    /// knows until one comes up.
    ///
    /// This is what the learned routing table was for: the table has
    /// held several ways to a destination for a long time, and until now
    /// a single refusing or silent node ended the attempt.
    @discardableResult
    func autoConnect(to named: AX25Address) -> Result<NetRomCircuitID, OpenFailure> {
        let resolution = resolveDestination(named.display)
        let destination = resolution.address
        let key = Self.key(destination)
        let hops = candidateHops(to: destination, alias: resolution.requestedAlias)
        guard !hops.isEmpty else { return .failure(.noRoute(resolution.displayName)) }

        campaigns[key]?.finish()
        let campaign = NetRomAutoTryCampaign(destination: destination, hops: hops)
        campaigns[key] = campaign

        if hops.count > 1 {
            onOperatorNote?(
                "Trying \(resolution.displayName) — \(hops.count) routes known, "
                + "best first: \(hops.map(\.display).joined(separator: ", ")).")
        }
        return advanceCampaign(campaign)
    }

    /// Attempt the campaign's next hop, or report it spent.
    @discardableResult
    private func advanceCampaign(_ campaign: NetRomAutoTryCampaign)
    -> Result<NetRomCircuitID, OpenFailure> {
        guard let hop = campaign.nextHop() else {
            campaign.finish()
            campaigns[Self.key(campaign.destination)] = nil
            let text = NetRomAutoTryPolicy.exhaustedText(
                destination: campaign.destination.display,
                attempted: campaign.attemptedDisplay)
            onOperatorNote?(text)
            return .failure(.noRoute(campaign.destination.display))
        }

        onOperatorNote?(
            "Opening a NET/ROM circuit to \(campaign.destination.display) through \(hop.display).")
        switch openCircuit(to: campaign.destination, via: hop) {
        case .success(let id):
            campaign.noteAttemptStarted(circuit: id)
            return .success(id)
        case .failure(let reason):
            // This hop is unusable; that is exactly what auto-try exists
            // to survive, so keep walking rather than reporting failure.
            onOperatorNote?(reason.operatorText)
            return advanceCampaign(campaign)
        }
    }

    /// A circuit that belonged to a campaign has ended. Decide whether
    /// the campaign continues.
    ///
    /// Returns true when the disconnect was consumed by a campaign, so
    /// the caller can suppress the ordinary "circuit closed" note — an
    /// operator watching an auto-try wants one narrative, not one line
    /// per attempted hop.
    private func campaignHandled(circuitID: NetRomCircuitID,
                                 destination: AX25Address,
                                 reason: NetRomDisconnectReason) -> Bool {
        let key = Self.key(destination)
        guard let campaign = campaigns[key],
              campaign.activeCircuit == circuitID,
              !campaign.isFinished else { return false }

        switch NetRomAutoTryPolicy.verdict(for: reason) {
        case .stop(let why):
            campaign.finish()
            campaigns[key] = nil
            onOperatorNote?("\(destination.display) \(why).")
            return true
        case .tryNext:
            guard !campaign.remainingHops.isEmpty else {
                campaign.finish()
                campaigns[key] = nil
                onOperatorNote?(NetRomAutoTryPolicy.exhaustedText(
                    destination: destination.display,
                    attempted: campaign.attemptedDisplay))
                return true
            }
            onOperatorNote?(
                "\(campaign.attemptedHops.last?.display ?? "That route") did not get through "
                + "to \(destination.display). Trying the next route.")
            _ = advanceCampaign(campaign)
            return true
        }
    }

    /// A circuit came up; if it was an auto-try attempt, the campaign is
    /// over and succeeded.
    private func campaignSucceeded(circuitID: NetRomCircuitID, destination: AX25Address) {
        let key = Self.key(destination)
        guard let campaign = campaigns[key], campaign.activeCircuit == circuitID else { return }
        campaign.finish()
        campaigns[key] = nil
    }

    // MARK: Transit routing

    /// Decide and act on a datagram addressed to someone else.
    private func forward(_ datagram: NetRomDatagram, arrivedFrom neighbor: AX25Address) {
        let decision = NetRomForwarding.decide(
            datagram: datagram,
            arrivedFrom: neighbor,
            forwardingEnabled: forwardingEnabled,
            localNode: endpoint.localNode,
            nextHop: { [weak self] destination in
                guard let self else { return nil }
                // The datagram carries a callsign, but the route may have
                // been learned under an alias (or the reverse).
                let resolution = NetRomDestinationResolver.resolve(destination) { alias in
                    self.callsignForAliasResolver?(alias)
                }
                return self.hopText(for: resolution)
            }
        )
        switch decision {
        case let .forward(forwarded, hop):
            let encoded = NetRomTransportWire.encode(forwarded)
            if let capacity = transport?.datagramCapacity(toNeighbor: hop),
               encoded.count > capacity {
                TxLog.warning(.session, "NET/ROM transit datagram too large for the next hop", [
                    "destination": forwarded.destination.display,
                    "neighbor": hop.display,
                    "bytes": encoded.count,
                    "capacity": capacity
                ])
                return
            }
            _ = transport?.sendDatagram(encoded, toNeighbor: hop)
            TxLog.debug(.session, "NET/ROM datagram forwarded", [
                "origin": forwarded.origin.display,
                "destination": forwarded.destination.display,
                "via": hop.display,
                "ttl": Int(forwarded.ttl)
            ])
        case .notARouter:
            break  // silent: this is the normal, default state
        case .ttlExpired, .noRoute, .wouldLoop:
            TxLog.debug(.session, "NET/ROM transit datagram dropped", [
                "destination": datagram.destination.display,
                "reason": String(describing: decision)
            ])
        }
    }

    // MARK: Auto-try

    /// Ordered next hops to try for a destination, best first.
    func candidateHops(to destination: AX25Address,
                       alias: String? = nil) -> [AX25Address] {
        let resolution = NetRomDestinationResolver.Resolution(
            address: destination,
            requestedAlias: alias ?? requestedAlias[Self.key(destination)],
            didResolve: false)
        var hops: [String] = []
        for key in NetRomDestinationResolver.routeLookupKeys(for: resolution) {
            hops += candidateHopsResolver?(key) ?? []
            if hops.isEmpty, let single = nextHopResolver?(key), !single.isEmpty {
                hops.append(single)
            }
        }
        var seen = Set<String>()
        return hops.compactMap { text in
            let address = CallsignNormalizer.toAddress(text)
            guard !text.isEmpty, seen.insert(address.display.uppercased()).inserted else { return nil }
            return address
        }
    }

    /// Open a circuit through a specific neighbor, bypassing the route
    /// table's own choice. Auto-try uses this to walk alternatives.
    func openCircuit(to destination: AX25Address,
                     via neighbor: AX25Address) -> Result<NetRomCircuitID, OpenFailure> {
        guard let capacity = transport?.datagramCapacity(toNeighbor: neighbor),
              capacity > NetRomWire.headerLength else {
            return .failure(.neighborUnusable(neighbor.display))
        }
        var config = endpoint.circuitConfig
        config.maxInfoPayload = max(
            Self.minimumInfoPayload,
            min(NetRomWire.maxInfoPayload, capacity - NetRomWire.headerLength)
        )
        endpoint.circuitConfig = config

        pinnedNeighbor[Self.key(destination)] = neighbor
        let id = endpoint.openCircuit(to: destination)
        opened[id] = clock()
        refreshCircuits()
        return .success(id)
    }

    // MARK: Endpoint wiring

    private func wireEndpoint() {
        endpoint.onTransmitDatagram = { [weak self] data, destination in
            guard let self else { return false }
            return self.transmit(data, to: destination)
        }
        endpoint.onCircuitData = { [weak self] id, data in
            self?.onCircuitData?(id, data)
        }
        endpoint.onTransitDatagram = { [weak self] datagram, neighbor in
            self?.forward(datagram, arrivedFrom: neighbor)
        }
        endpoint.onCircuitConnected = { [weak self] id, window in
            guard let self else { return }
            self.refreshCircuits()
            if let summary = self.circuit(for: id) {
                self.campaignSucceeded(circuitID: id, destination: summary.destination)
                self.onOperatorNote?(
                    summary.neighbor.display == summary.destination.display
                        ? "Connected to \(summary.destination.display) over NET/ROM."
                        : "Connected to \(summary.destination.display) over NET/ROM "
                          + "through \(summary.neighbor.display).")
            }
            TxLog.debug(.session, "NET/ROM circuit up", ["window": window])
        }
        endpoint.onCircuitDisconnected = { [weak self] id, reason in
            guard let self else { return }
            let summary = self.circuit(for: id)
            let destination = summary?.destination.display ?? "the far station"
            self.opened[id] = nil
            if let summary {
                self.releasePinIfUnused(for: summary.destination, excluding: id)
            }
            self.refreshCircuits()
            if let summary,
               self.campaignHandled(circuitID: id,
                                    destination: summary.destination,
                                    reason: reason) {
                return
            }
            self.onOperatorNote?(Self.operatorText(for: reason, destination: destination))
        }
    }

    private func transmit(_ data: Data, to destination: AX25Address) -> Bool {
        let key = Self.key(destination)
        let neighbor: AX25Address
        if let pinned = pinnedNeighbor[key] {
            neighbor = pinned
        } else if let hop = hopText(for: NetRomDestinationResolver.Resolution(
                    address: destination,
                    requestedAlias: requestedAlias[key],
                    didResolve: false)), !hop.isEmpty {
            neighbor = CallsignNormalizer.toAddress(hop)
            pinnedNeighbor[key] = neighbor
        } else {
            TxLog.warning(.session, "NET/ROM datagram has no next hop", [
                "destination": destination.display
            ])
            return false
        }

        // One datagram, one I-frame. Splitting it would decode as
        // garbage at the far end, so refuse instead.
        if let capacity = transport?.datagramCapacity(toNeighbor: neighbor),
           data.count > capacity {
            TxLog.warning(.session, "NET/ROM datagram exceeds the link's frame size", [
                "destination": destination.display,
                "neighbor": neighbor.display,
                "bytes": data.count,
                "capacity": capacity
            ])
            return false
        }

        guard let transport else { return false }
        return transport.sendDatagram(data, toNeighbor: neighbor)
    }

    // MARK: Bookkeeping

    private func refreshCircuits() {
        let now = clock()
        onCircuitsWillChange?()
        circuits = endpoint.liveCircuits().map { entry in
            NetRomCircuitSummary(
                id: entry.id,
                destination: entry.remote,
                requestedAlias: requestedAlias[Self.key(entry.remote)],
                neighbor: pinnedNeighbor[Self.key(entry.remote)] ?? entry.remote,
                state: entry.state,
                openedAt: opened[entry.id] ?? now
            )
        }
    }

    /// Drop a destination's pin once no circuit still needs it — but
    /// only then, so a second circuit to the same node keeps its hop.
    private func releasePinIfUnused(for destination: AX25Address, excluding id: NetRomCircuitID) {
        let key = Self.key(destination)
        let stillUsed = endpoint.liveCircuits().contains {
            $0.id != id && Self.key($0.remote) == key
        }
        if !stillUsed { pinnedNeighbor[key] = nil }
    }

    private static func operatorText(for reason: NetRomDisconnectReason, destination: String) -> String {
        switch reason {
        case .localRequest:
            return "Circuit to \(destination) closed."
        case .remoteRequest:
            return "\(destination) closed the circuit."
        case .refused:
            return "\(destination) refused the circuit. "
                + "The node is reachable but would not accept a connection."
        case .reset:
            return "The circuit to \(destination) was reset by the far end."
        case .timedOut:
            return "\(destination) never answered — the circuit timed out."
        case .transportFailure(let detail):
            return "Could not carry the circuit to \(destination): \(detail)."
        case .protocolError(let detail):
            return "The circuit to \(destination) broke protocol: \(detail)."
        }
    }

    private static func key(_ address: AX25Address) -> String {
        address.display.uppercased()
    }

    /// Never fragment below this: a link whose paclen leaves less than
    /// this per datagram is too degraded to run a circuit over, and
    /// tiny fragments would spend more airtime on headers than data.
    static let minimumInfoPayload = 32
}
