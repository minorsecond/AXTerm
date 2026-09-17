import Foundation
import Network

nonisolated enum IcomLANError: Error, Equatable, Sendable {
    case timeout(String)
    case badCredentials
    case rejected(String)
    case radioDisconnected
    case network(String)
    case notConnected
    case localNetworkDenied

    var message: String {
        switch self {
        // The radio keeps one session and takes its time releasing it, so
        // this is far more often the previous connection still being held
        // than a radio with its networking off — especially right after the
        // app is killed and relaunched, which never sends a clean release.
        // Blaming WLAN first sent the operator to check settings that were
        // fine while the next attempt was already about to succeed
        // (2026-09-17).
        case .timeout(let what):
            return "the radio did not answer (\(what)). It keeps one session at a time and can "
                + "hold the last one for a few seconds \u{2014} the next attempt usually gets in. "
                + "If it keeps failing, check the radio's WLAN and that Network Control is on."
        case .badCredentials: return "the radio refused the username or password. Check the radio's Network User name and its password (on an IC-705: Menu \u{203A} Set \u{203A} Network), and that they match what you entered here."
        case .rejected(let why): return why
        case .radioDisconnected: return "the radio ended the connection"
        case .network(let why): return why
        case .notConnected: return "not connected to the radio"
        // macOS, not the radio. Every socket to a LAN address is refused
        // until AXTerm is allowed local network access, and the refusal is
        // silent: the connection sits in .waiting forever and the handshake
        // simply runs out. Reported as a timeout it reads as a dead radio,
        // which is why this branch exists (2026-09-17).
        case .localNetworkDenied:
            return Self.localNetworkDenialAdvice(debugged: Self.isBeingDebugged())
        }
    }

    /// What to tell the operator when macOS refuses the LAN.
    ///
    /// Only what is known. macOS does not say which identity it judged, and
    /// this refusal is intermittent in practice: the same build is refused
    /// on one attempt and satisfied on the next, and a second copy of the
    /// app starting (a test host shares the bundle identifier) can take the
    /// running one's sockets down with it.
    ///
    /// An earlier version of this message asserted that a debugged build is
    /// judged as Xcode and told the operator to turn Xcode on. That was
    /// inferred from debugserver being the parent process, never checked,
    /// and Xcode does not necessarily even appear in that list. Naming the
    /// wrong switch is the failure this whole message exists to avoid, so
    /// this one names the switch we know of and stops (2026-09-17).
    static func localNetworkDenialAdvice(debugged: Bool) -> String {
        let setting = "System Settings \u{203A} Privacy & Security \u{203A} Local Network"
        var advice = "macOS is refusing this build access to devices on your network, which is "
            + "not something the radio can answer for. Check AXTerm under " + setting + "; if it "
            + "is already on, switching it off and back on can clear it, because a rebuilt copy "
            + "may be judged as a different app."
        if debugged {
            advice += " This copy is running under a debugger, and a second copy of the app "
                + "(a test run shares its identifier) can take the running one's connection "
                + "down with it."
        }
        return advice
    }

    /// Whether a debugger is attached, by the documented P_TRACED check.
    static func isBeingDebugged() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// The denial macOS reports on an unsatisfied path, when it is one we
    /// can name. Everything else stays whatever the caller was going to
    /// say — a path can be unsatisfied for reasons that really are the
    /// network's fault.
    static func denial(for reason: NWPath.UnsatisfiedReason?) -> IcomLANError? {
        guard let reason else { return nil }
        if case .localNetworkDenied = reason { return .localNetworkDenied }
        return nil
    }
}

/// What a socket state means to a handshake still waiting on it.
///
/// Pulled out of the state handler so the decisions can be checked without
/// a live socket. The one that matters is `.waiting`: macOS refusing local
/// network access parks the connection there and reports nothing, so the
/// old handler sat through the handshake's whole window and then blamed the
/// radio for not answering (2026-09-17).
nonisolated enum IcomLANSocketOutcome: Equatable {
    case ready
    case keepWaiting
    case fail(IcomLANError)

    /// `denial` is what macOS says about the path, when it is a refusal we
    /// can name. A named refusal ends the wait; anything else is the
    /// network being slow, which is worth waiting out.
    static func of(_ state: NWConnection.State, denial: IcomLANError?) -> IcomLANSocketOutcome {
        switch state {
        case .ready: return .ready
        case .failed(let error): return .fail(denial ?? .network(error.localizedDescription))
        case .cancelled: return .fail(.network("cancelled"))
        case .waiting: return denial.map(IcomLANSocketOutcome.fail) ?? .keepWaiting
        default: return .keepWaiting
        }
    }
}

/// One of the three UDP streams to the radio.
///
/// Owns the socket, the session IDs, the handshake, the keepalives and the
/// retransmit bookkeeping that every stream shares; what the packets mean
/// is the session's business. Everything runs on the session's queue.
nonisolated final class IcomLANStream: @unchecked Sendable {

    let name: String
    let queue: DispatchQueue
    private(set) var localID: UInt32 = 0
    private(set) var remoteID: UInt32 = 0

    /// The port the socket actually bound, when it could be read, and
    /// whether it disagrees with the one we reserved and pinned to.
    ///
    /// The radio checks the low 16 bits of our session ID against the source
    /// port of our packets. We reserve a port, pin the socket to it with
    /// `requiredLocalEndpoint`, and build the ID from the reservation — but
    /// nothing has ever checked that the pin landed. Reserving is a bind,
    /// read, close, rebind, so there is a window in which something else can
    /// take the port, and `allowLocalEndpointReuse` means a collision need
    /// not fail loudly. When it happens the radio accepts the login and
    /// silently refuses this stream's connection request, which is
    /// indistinguishable from a radio with CI-V switched off.
    private(set) var boundPort: UInt16?
    var pinnedPortMismatch: Bool {
        guard let reserved = reservedLocalPort, let bound = boundPort else { return false }
        return reserved != bound
    }
    /// The last measured ping round trip, seconds.
    private(set) var roundTrip: Double = 0

    /// Every datagram that is not a ping or a retransmit request. Queue.
    var onPacket: ((Data) -> Void)?
    /// The socket died. Queue.
    var onFailure: ((String) -> Void)?

    private var connection: NWConnection?
    /// The ephemeral source port we reserved and pinned via
    /// requiredLocalEndpoint, so the egress port equals the localID's low
    /// 16 bits by construction. nil when reservation failed.
    private var reservedLocalPort: UInt16?
    private var isReady = false
    private var trackedSequence: UInt16 = 1
    /// Tracked packets by sequence, for the radio's retransmit requests.
    private var history: [UInt16: Data] = [:]
    private var historyOrder: [UInt16] = []
    private var pingSequence: UInt16 = 1
    private var pingInnerSequence: UInt16 = 0x8304
    private var pingSentAt: Double = 0
    private var pingTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var lastTrackedAt: Double = 0
    /// When the radio last sent us anything at all — ping, idle, audio or
    /// payload. Over UDP this is the only evidence the radio still exists;
    /// `IcomLANLiveness` turns it into a verdict. Zero until first contact.
    private(set) var lastInboundAt: Double = 0
    /// When `connect()` last ran. Zero while disconnected.
    private(set) var connectedAt: Double = 0
    private var expecting: [(id: UUID, match: (Data) -> Bool, resume: (Data) -> Void)] = []

    /// Optional handshake trace for live debugging. Enabled when
    /// AXTERM_ICOMLAN_TRACE is set to anything; the file lands in the
    /// process's temp directory (writable under the test sandbox).
    static let traceEnabled = ProcessInfo.processInfo.environment["AXTERM_ICOMLAN_TRACE"] != nil
    static let tracePath = NSTemporaryDirectory() + "axterm_icomlan.trace"
    func trace(_ message: @autoclosure () -> String) {
        guard Self.traceEnabled else { return }
        let line = name + ": " + message() + "\n"
        let path = Self.tracePath
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    init(name: String, queue: DispatchQueue) {
        self.name = name
        self.queue = queue
    }

    // MARK: - Socket

    /// Open the socket and run the three-way hello: are-you-there,
    /// I-am-here (which carries the radio's session ID), ready.
    func connect(host: String, port: UInt16, timeout: Double = 2) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw IcomLANError.network("bad port \(port)") }
        // This stream object is reused across connect/disconnect cycles, so
        // every per-session counter must start fresh — the radio treats a new
        // localID as a new session and expects its tracked sequence to begin
        // at 1. Carrying a climbing sequence (or a stale remote/ready flag)
        // over from the previous connection makes the radio ignore the login,
        // which surfaces as "the radio did not answer (login)" on reconnect.
        trackedSequence = 1
        pingSequence = 1
        history.removeAll()
        historyOrder.removeAll()
        remoteID = 0
        isReady = false
        reservedLocalPort = nil
        boundPort = nil
        // Including when we last heard anything. Left over from the previous
        // session it is not silence, it is a different session's history, and
        // the liveness watchdog's first tick reads it as a radio that has
        // been dead for as long as the reconnect took — killing a session one
        // second after it connected.
        lastInboundAt = 0
        // When this session started listening. Silence is measured from here
        // until the radio first speaks, so a stream that never delivers a
        // single datagram is still judged. Without it `silence` stayed nil
        // for such a stream, `compactMap` dropped it from the watchdog, and
        // an audio path that never came up was excluded from the very check
        // that exists to catch it — the link then rode on control's pings and
        // reported "connected" indefinitely (log12, 2026-09-10: ten minutes
        // of dead audio, no verdict).
        beginListening()
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // The radio checks our session ID against the source of our
        // packets: the top 16 bits must be octets 3/4 of the source IPv4,
        // and the low 16 bits must be the source UDP port (this is exactly
        // how wfview/kappanhang build localSID). We must not merely READ the
        // port NWConnection happens to report — its `currentPath` port is
        // not reliably the real egress port, and a mismatch makes the radio
        // accept login/token/caps but silently refuse the audio+CI-V
        // connection request. So we RESERVE an ephemeral port ourselves and
        // pin the socket to it with requiredLocalEndpoint (host 0.0.0.0 so
        // macOS still chooses the interface — we do not pin the NIC), which
        // makes egress-port == localID-low by construction. The IP half
        // comes from the routed source; if we cannot determine either half
        // we fall back to letting the OS pick and reading it at .ready.
        let base = Self.routedSource(toward: host, port: port)?.base
        if let reservedPort = Self.reserveLocalPort() {
            self.reservedLocalPort = reservedPort
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0",
                                                               port: NWEndpoint.Port(rawValue: reservedPort)!)
            self.localID = (base ?? UInt32.random(in: 0x1000_0000...0xFFFF_0000)) & 0xFFFF_0000 | UInt32(reservedPort)
        } else if let base {
            self.localID = base | UInt32.random(in: 0...0xFFFF)
        } else {
            self.localID = UInt32.random(in: 0x1000_0000...0xFFFF_FFFF)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    // Authoritative: correct the session ID's IP bits from
                    // the connection's *actual* bound source (are-you-there
                    // has not been sent yet), so it matches the packets the
                    // radio really receives even if the pin above didn't
                    // land the interface we measured.
                    let ep = connection.currentPath?.localEndpoint
                    // Correct the IP half from the real bound source; keep
                    // the low 16 bits as our reserved port (the egress port
                    // is pinned to it). When we could not reserve a port,
                    // fall back to the reported port for the low half.
                    if let realBase = Self.baseFromEndpoint(ep) {
                        let low: UInt32 = self.reservedLocalPort.map(UInt32.init)
                            ?? Self.portFromEndpoint(ep).map(UInt32.init)
                            ?? (self.localID & 0xFFFF)
                        self.localID = realBase | low
                    }
                    self.boundPort = Self.portFromEndpoint(ep)
                    self.trace("socket ready, actual source \(String(describing: ep)), reserved \(String(describing: self.reservedLocalPort)), localID \(String(format: "%08x", self.localID))")
                    if self.pinnedPortMismatch {
                        // Not fatal here — the radio decides — but it is the
                        // one thing that makes a stream come up and then
                        // carry nothing, so say it where it will be read.
                        TxLog.debug(.modem, "IcomLAN: source port pin did not land",
                                    ["stream": self.name,
                                     "reserved": self.reservedLocalPort.map(String.init) ?? "-",
                                     "bound": self.boundPort.map(String.init) ?? "-"])
                    }
                    self.receiveLoop()
                    if !resumed { resumed = true; continuation.resume() }
                default:
                    switch IcomLANSocketOutcome.of(state, denial: self.denialNow()) {
                    case .ready:
                        break  // handled above
                    case .keepWaiting:
                        self.trace("socket \(state)")
                    case .fail(let why):
                        self.isReady = false
                        self.trace("socket \(state): " + why.message)
                        if !resumed { resumed = true; continuation.resume(throwing: why) }
                        else { self.onFailure?(why.message) }
                    }
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if !resumed {
                    resumed = true
                    continuation.resume(
                        throwing: self.denialNow() ?? IcomLANError.timeout("\(self.name) socket"))
                }
            }
        }

        // are-you-there → I-am-here (which names the radio's session).
        // Retry: after a controller drops uncleanly (an app kill, a crash,
        // a Wi-Fi blip), the radio keeps its single client slot and goes
        // quiet to a fresh controller until the slot times out — tens of
        // seconds. Resending across ~18s lets that heal on its own rather
        // than failing the moment the radio is briefly unreachable. A radio
        // that is genuinely off or whose Network Control is disabled simply
        // runs out the window and reports the timeout.
        trace("sending are-you-there")
        let hello = IcomLAN.control(.areYouThere, local: localID, remote: 0)
        var here: Data?
        for attempt in 0..<22 {
            send(hello); send(hello)
            if let d = try? await expect(timeout: 0.8, what: "\(name) I-am-here", { $0.count == 16 && $0[$0.startIndex + 4] == 0x04 }) {
                here = d
                break
            }
            trace("are-you-there attempt \(attempt + 1) unanswered, retrying")
            // No point spending the rest of the window on a socket macOS
            // has already refused to route.
            if let denial = denialNow() { throw denial }
        }
        guard let answer = here else { throw denialNow() ?? IcomLANError.timeout("\(name) I-am-here") }
        remoteID = IcomLAN.Header.parse(answer)!.senderID
        trace("got I-am-here")
        let ready = IcomLAN.control(.ready, sequence: 1, local: localID, remote: remoteID)
        send(ready); send(ready)
        _ = try await expect(timeout: timeout, what: "\(name) ready") { d in
            d.count == 16 && d[d.startIndex + 4] == 0x06
        }
        trace("handshake complete")
    }

    /// What macOS says about this socket's path right now, when it is a
    /// refusal we can name rather than a network that is merely down.
    private func denialNow() -> IcomLANError? {
        IcomLANError.denial(for: connection?.currentPath?.unsatisfiedReason)
    }

    /// Our source toward `host`: the dotted IPv4 string to pin the socket
    /// to, plus the session-ID `base` the radio insists on — its top 16
    /// bits are the third and fourth octets of that address (the low 16
    /// bits are the radio's don't-care field). The connected-UDP-socket
    /// getsockname names the interface the OS actually routes through,
    /// which on a host dual-homed on the radio's subnet cannot be guessed
    /// from the interface list; getifaddrs is a sandbox fallback. Exposed
    /// for the localID unit test.
    /// The session-ID base (top 16 bits) from a connection's own local
    /// endpoint — the ground-truth source the radio will see.
    static func baseFromEndpoint(_ ep: NWEndpoint?) -> UInt32? {
        guard case let .hostPort(host: host, port: _)? = ep else { return nil }
        // Take the dotted quad out of the description ("192.168.3.14",
        // possibly with a "%en0" scope), robust to how the host case prints.
        let text = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        let o = withUnsafeBytes(of: addr.s_addr) { Array($0) }
        guard o.count == 4, !(o[0] == 0 && o[1] == 0 && o[2] == 0 && o[3] == 0) else { return nil }
        return UInt32(o[2]) << 24 | UInt32(o[3]) << 16
    }

    /// The source UDP port from a connection's own local endpoint. The
    /// radio requires the low 16 bits of the session ID to be the actual
    /// source port of the control socket (this is how wfview builds its
    /// localSID: `(ip & 0xffff) << 16 | port`). A random low 16 gets the
    /// login/token/caps accepted but the audio+CI-V connection request
    /// silently refused (the 0x50 status flips to ...ffffffff and no 0x90
    /// arrives), which reads to the operator as "another client connected."
    static func portFromEndpoint(_ ep: NWEndpoint?) -> UInt16? {
        guard case let .hostPort(host: _, port: port)? = ep else { return nil }
        return port.rawValue
    }

    /// Reserve an ephemeral UDP port by binding a throwaway socket to
    /// 0.0.0.0:0, reading the OS-assigned port, and closing it. We then pin
    /// the real connection to that port with requiredLocalEndpoint. There is
    /// a small TOCTOU window before the rebind, but ephemeral collisions are
    /// rare and allowLocalEndpointReuse softens them; returning nil falls the
    /// caller back to reading whatever port the connection reports.
    static func reserveLocalPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard ok == 0 else { return nil }
        let port = UInt16(bigEndian: local.sin_port)
        return port == 0 ? nil : port
    }

    static func routedSource(toward host: String, port: UInt16) -> (ip: String, base: UInt32)? {
        var radio = in_addr()
        guard inet_pton(AF_INET, host, &radio) == 1 else { return nil }

        func result(_ a: in_addr) -> (ip: String, base: UInt32)? {
            let o = withUnsafeBytes(of: a.s_addr) { Array($0) } // network order
            guard o.count == 4, !(o[0] == 0 && o[1] == 0 && o[2] == 0 && o[3] == 0) else { return nil }
            return ("\(o[0]).\(o[1]).\(o[2]).\(o[3])", UInt32(o[2]) << 24 | UInt32(o[3]) << 16)
        }

        // Primary: the actual routed source address.
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd >= 0 {
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = radio
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connected == 0 {
                var local = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let ok = withUnsafeMutablePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
                }
                if ok == 0, let r = result(local.sin_addr) { return r }
            }
        }

        // Fallback: the interface whose network contains the radio.
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0 {
            defer { freeifaddrs(ifap) }
            var p = ifap
            while let cur = p {
                let flags = Int32(cur.pointee.ifa_flags)
                if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                   (flags & IFF_LOOPBACK) == 0, let nm = cur.pointee.ifa_netmask {
                    let ip = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    let mask = UnsafeRawPointer(nm).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    if (ip.s_addr & mask.s_addr) == (radio.s_addr & mask.s_addr) { return result(ip) }
                }
                p = cur.pointee.ifa_next
            }
        }
        return nil
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handle(data)
            }
            if let error {
                self.trace("receive error: " + error.localizedDescription)
                self.onFailure?(error.localizedDescription)
                return
            }
            if self.isReady { self.receiveLoop() }
        }
    }

    /// Datagrams actually handed to the socket, and datagrams thrown away
    /// because the stream was not ready. The second number has no other
    /// witness: a not-ready stream swallows every write in silence, which
    /// looks exactly like a radio that is ignoring us.
    private(set) var sentPackets = 0
    private(set) var droppedSends = 0

    func send(_ data: Data) {
        trace("TX " + data.prefix(48).map { String(format: "%02x", $0) }.joined())
        guard isReady, let connection else {
            droppedSends += 1
            trace("send skipped (not ready)")
            return
        }
        sentPackets += 1
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.trace("send failed: " + error.localizedDescription) }
        })
    }

    /// Stamp the next tracked sequence into a packet, remember it for a
    /// retransmit request, and send it.
    @discardableResult
    func sendTracked(_ packet: Data) -> UInt16 {
        var d = packet
        let seq = trackedSequence
        d[d.startIndex + 6] = UInt8(seq & 0xFF)
        d[d.startIndex + 7] = UInt8(seq >> 8)
        trackedSequence &+= 1
        history[seq] = d
        historyOrder.append(seq)
        while historyOrder.count > 400 {
            history.removeValue(forKey: historyOrder.removeFirst())
        }
        send(d)
        if !IcomLAN.isIdle(d) {
            lastTrackedAt = Self.now
            rearmIdle(after: 0.1)
        }
        return seq
    }

    func disconnect() {
        trace("disconnect() called")
        pingTimer?.cancel(); pingTimer = nil
        idleTimer?.cancel(); idleTimer = nil
        if isReady, remoteID != 0 {
            let bye = IcomLAN.control(.disconnect, local: localID, remote: remoteID)
            send(bye); send(bye)
        }
        isReady = false
        connection?.cancel()
        connection = nil
        // A disconnected stream has heard nothing. Anything else would be
        // this session's history answering for the next one's.
        lastInboundAt = 0
        connectedAt = 0
        for e in expecting { e.resume(Data()) }
        expecting.removeAll()
    }

    // MARK: - Expecting a packet

    /// Wait for the first datagram that matches. Anything else keeps
    /// flowing to `onPacket`.
    func expect(timeout: Double, what: String, _ match: @escaping (Data) -> Bool) async throws -> Data {
        let id = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            var resumed = false
            queue.async {
                self.expecting.append((id: id, match: match, resume: { d in
                    guard !resumed else { return }
                    resumed = true
                    if d.isEmpty { continuation.resume(throwing: IcomLANError.network("closed")) }
                    else { continuation.resume(returning: d) }
                }))
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !resumed else { return }
                resumed = true
                self.expecting.removeAll { $0.id == id }
                continuation.resume(throwing: IcomLANError.timeout(what))
            }
        }
    }

    // MARK: - Keepalives

    /// Pings every three seconds (the radio pings us far more often and we
    /// answer each one); idle packets when nothing tracked has gone out.
    func startKeepalive(pingSequence first: UInt16, idlePackets: Bool) {
        pingSequence = first
        pingTimer?.cancel()
        let ping = DispatchSource.makeTimerSource(queue: queue)
        ping.schedule(deadline: .now() + 0.5, repeating: 3.0)
        ping.setEventHandler { [weak self] in self?.sendPing() }
        ping.resume()
        pingTimer = ping
        if idlePackets { rearmIdle(after: 1.0) }
    }

    private func rearmIdle(after: Double) {
        idleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + after)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendTracked(IcomLAN.control(.idle, local: self.localID, remote: self.remoteID))
            let quiet = Self.now - self.lastTrackedAt >= 1.0
            self.rearmIdle(after: quiet ? 1.0 : 0.1)
        }
        t.resume()
        idleTimer = t
    }

    private func sendPing() {
        var id: [UInt8] = [UInt8.random(in: 0...255), UInt8(pingInnerSequence & 0xFF), UInt8(pingInnerSequence >> 8), 0x06]
        pingInnerSequence &+= 1
        if id.count < 4 { id += [0, 0, 0, 0] }
        send(IcomLAN.ping(sequence: pingSequence, local: localID, remote: remoteID, reply: false, id: id))
        pingSequence &+= 1
        pingSentAt = Self.now
    }

    // MARK: - Inbound

    /// Internal rather than private so a test can feed it a datagram without
    /// a socket: what counts as a sign of life is the whole point.
    func handle(_ d: Data) {
        // Stamped first, and for *every* datagram. Pings and idles return
        // early below and are the only things a radio sends when nothing is
        // happening — a liveness stamp taken any further down would call a
        // healthy but quiet radio dead.
        lastInboundAt = Self.now
        if !IcomLAN.isPing(d) && !IcomLAN.isIdle(d) {
            trace("RX " + d.prefix(48).map { String(format: "%02x", $0) }.joined())
        }
        if IcomLAN.isPing(d) {
            if IcomLAN.pingIsReply(d) {
                if pingSentAt > 0 { roundTrip = (roundTrip + (Self.now - pingSentAt)) / 2 }
            } else if let h = IcomLAN.Header.parse(d) {
                send(IcomLAN.ping(sequence: h.sequence, local: localID, remote: remoteID, reply: true, id: IcomLAN.pingID(d)))
            }
            return
        }
        if let wanted = IcomLAN.retransmitRequestedSequences(d) {
            for seq in wanted {
                if let again = history[seq] {
                    send(again); send(again)
                } else {
                    // Gone: an idle with that number closes the gap.
                    var idle = IcomLAN.control(.idle, sequence: seq, local: localID, remote: remoteID)
                    idle[idle.startIndex + 6] = UInt8(seq & 0xFF)
                    idle[idle.startIndex + 7] = UInt8(seq >> 8)
                    send(idle); send(idle)
                }
            }
            return
        }
        if let index = expecting.firstIndex(where: { $0.match(d) }) {
            let e = expecting.remove(at: index)
            e.resume(d)
            return
        }
        onPacket?(d)
    }

    /// Starts the clock that `silence` measures against before first contact.
    ///
    /// Internal rather than private so a test can put a stream in the state
    /// `connect()` leaves it in without opening a socket — the hole this
    /// closes is precisely "connected and never spoken to", which cannot be
    /// reached any other way.
    func beginListening(now: Double = IcomLANStream.now) {
        connectedAt = now
    }

    /// How long the radio has said nothing on this stream, or nil when the
    /// stream is not connected and there is nothing to judge.
    ///
    /// Before first contact this counts from `connectedAt`, not from zero.
    /// The two are different questions that were once the same answer: a
    /// stream carrying a *previous* session's stamp must not be judged (it
    /// killed sessions one second after connecting), but a stream that has
    /// simply never been spoken to must be — that is a radio we never reached,
    /// and it is indistinguishable, from the operator's side, from one that
    /// left.
    var silence: TimeInterval? {
        let since = max(lastInboundAt, connectedAt)
        guard since > 0 else { return nil }
        return Self.now - since
    }

    static var now: Double { CFAbsoluteTimeGetCurrent() }
}
