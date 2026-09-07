import Foundation
import Network

nonisolated enum IcomLANError: Error, Equatable, Sendable {
    case timeout(String)
    case badCredentials
    case rejected(String)
    case radioDisconnected
    case network(String)
    case notConnected

    var message: String {
        switch self {
        case .timeout(let what): return "the radio did not answer (\(what)). Is its WLAN on and Network Control enabled?"
        case .badCredentials: return "the radio refused the username or password"
        case .rejected(let why): return why
        case .radioDisconnected: return "the radio ended the connection"
        case .network(let why): return why
        case .notConnected: return "not connected to the radio"
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
    /// The last measured ping round trip, seconds.
    private(set) var roundTrip: Double = 0

    /// Every datagram that is not a ping or a retransmit request. Queue.
    var onPacket: ((Data) -> Void)?
    /// The socket died. Queue.
    var onFailure: ((String) -> Void)?

    private var connection: NWConnection?
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
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    self.localID = self.deriveLocalID(connection)
                    self.trace("socket ready")
                    self.receiveLoop()
                    if !resumed { resumed = true; continuation.resume() }
                case .failed(let error):
                    self.isReady = false
                    self.trace("socket failed: " + error.localizedDescription)
                    if !resumed { resumed = true; continuation.resume(throwing: IcomLANError.network(error.localizedDescription)) }
                    else { self.onFailure?(error.localizedDescription) }
                case .cancelled:
                    self.isReady = false
                    self.trace("socket cancelled")
                    if !resumed { resumed = true; continuation.resume(throwing: IcomLANError.network("cancelled")) }
                case .waiting(let error):
                    self.trace("socket waiting: " + error.localizedDescription)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if !resumed { resumed = true; continuation.resume(throwing: IcomLANError.timeout("\(self.name) socket")) }
            }
        }

        // are-you-there → I-am-here (which names the radio's session).
        // Retry: after another controller drops, the radio can take a few
        // seconds to answer a fresh controller, so resend rather than fail.
        trace("sending are-you-there")
        let hello = IcomLAN.control(.areYouThere, local: localID, remote: 0)
        var here: Data?
        for attempt in 0..<8 {
            send(hello); send(hello)
            if let d = try? await expect(timeout: 0.8, what: "\(name) I-am-here", { $0.count == 16 && $0[$0.startIndex + 4] == 0x04 }) {
                here = d
                break
            }
            trace("are-you-there attempt \(attempt + 1) unanswered, retrying")
        }
        guard let answer = here else { throw IcomLANError.timeout("\(name) I-am-here") }
        remoteID = IcomLAN.Header.parse(answer)!.senderID
        trace("got I-am-here")
        let ready = IcomLAN.control(.ready, sequence: 1, local: localID, remote: remoteID)
        send(ready); send(ready)
        _ = try await expect(timeout: timeout, what: "\(name) ready") { d in
            d.count == 16 && d[d.startIndex + 4] == 0x06
        }
        trace("handshake complete")
    }

    /// The session ID the radio will know us by: our address and port, as
    /// the other implementations do, or a random word when the path hides them.
    private func deriveLocalID(_ connection: NWConnection) -> UInt32 {
        if case .hostPort(let host, let port)? = connection.currentPath?.localEndpoint,
           case .ipv4(let v4) = host {
            let bytes = [UInt8](withUnsafeBytes(of: v4.rawValue) { Data($0) })
            if bytes.count == 4 {
                return UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(port.rawValue)
            }
        }
        return UInt32.random(in: 0x1000_0000...0xFFFF_FFFF)
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

    func send(_ data: Data) {
        guard isReady, let connection else { trace("send skipped (not ready)"); return }
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

    private func handle(_ d: Data) {
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

    static var now: Double { CFAbsoluteTimeGetCurrent() }
}
