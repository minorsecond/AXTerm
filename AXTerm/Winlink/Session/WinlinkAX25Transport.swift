import Foundation

/// B2F transport over an AX.25 connected-mode session.
///
/// Claims the session's delivered byte stream exclusively (see
/// `AX25SessionManager.claimDelivery`) so the terminal never line-splits
/// B2F bytes and AXDP reassembly never sees SOH/STX framing. Outbound
/// data rides `sendData` with PID 0xF0 and no AXDP envelope — B2F is a
/// wire-exact third-party protocol (AXTERM-TRANSMISSION-SPEC §5.3/§6).
@MainActor
final class WinlinkAX25Transport: WinlinkTransport {

    private let sessionManager: AX25SessionManager
    private let sendFrames: ([OutboundFrame]) -> Void
    private let destination: AX25Address
    private let path: DigiPath
    private let radio: RadioID
    private let connectTimeout: TimeInterval

    private var claim: SessionDeliveryClaim?
    private var closed = false
    /// `close()` was asked for while frames were still unacknowledged; the
    /// DISC goes once they are.
    private var closeWhenDrained = false

    var onReceive: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    var onDeliveryProgress: ((Int, Int) -> Void)?
    var onStandAside: ((String) -> Void)?

    private var submittedBytes = 0

    var endpointDescription: String {
        path.isEmpty ? destination.display : "\(destination.display) via \(path.display)"
    }

    init(
        sessionManager: AX25SessionManager,
        sendFrames: @escaping ([OutboundFrame]) -> Void,
        destination: AX25Address,
        path: DigiPath = DigiPath(),
        radio: RadioID = .primary,
        connectTimeout: TimeInterval = 90
    ) {
        self.sessionManager = sessionManager
        self.sendFrames = sendFrames
        self.destination = destination
        self.path = path
        self.radio = radio
        self.connectTimeout = connectTimeout
    }

    func open() async throws {
        let key = SessionKey(destination: destination, path: path, radio: radio)

        // Claim before any frame goes out so no delivered byte can leak
        // to the terminal path, and so a terminal session to the same
        // station blocks us instead of corrupting both.
        guard let claim = sessionManager.claimDelivery(
            for: key,
            handler: { [weak self] _, data in self?.onReceive?(data) },
            stateHandler: { [weak self] _, _, newState in
                guard let self, !self.closed else { return }
                if newState == .disconnected || newState == .error {
                    self.closed = true
                    self.releaseClaim()
                    self.onClose?(newState == .error ? "AX.25 session error" : nil)
                }
            },
            ackHandler: { [weak self] session, _ in
                self?.reportDeliveryProgress(session: session)
                self?.disconnectIfDrained(session)
            },
            netRomHandler: { [weak self] session in
                self?.standAside(for: session)
            }
        ) else {
            throw WinlinkTransportError.sessionBusy(
                "another session to \(destination.display) is already active")
        }
        self.claim = claim

        if let existing = sessionManager.existingSession(for: destination, path: path, radio: radio),
           existing.state == .connected {
            return  // already connected (e.g. retry after a failed handshake)
        }

        if let sabm = sessionManager.connect(to: destination, path: path, radio: radio) {
            sendFrames([sabm])
        }

        switch await sessionManager.awaitConnectionOutcome(key: key, timeout: connectTimeout) {
        case .connected:
            return
        case .refused:
            releaseClaim()
            throw WinlinkTransportError.connectRefused(destination.display)
        case .timeout:
            if let session = sessionManager.existingSession(for: destination, path: path, radio: radio) {
                sessionManager.forceDisconnect(session: session)
            }
            releaseClaim()
            throw WinlinkTransportError.connectTimeout(destination.display)
        }
    }

    func send(_ data: Data) {
        submittedBytes += data.count
        let frames = sessionManager.sendData(
            data,
            to: destination,
            path: path,
            radio: radio,
            pid: 0xF0,
            displayInfo: "Winlink B2F (\(data.count) bytes)")
        sendFrames(frames)
        if let session = sessionManager.existingSession(for: destination, path: path, radio: radio) {
            reportDeliveryProgress(session: session)
        }
    }

    /// Delivered = submitted − (queued behind the window + in flight).
    /// Exact: the session exposes both its pending queue and send buffer.
    private func reportDeliveryProgress(session: AX25Session) {
        let pendingQueued = session.pendingDataQueue.reduce(0) { $0 + $1.data.count }
        let inFlight = session.sendBuffer.values.reduce(0) { $0 + $1.payload.count }
        let delivered = max(0, submittedBytes - pendingQueued - inFlight)
        onDeliveryProgress?(delivered, submittedBytes)
    }

    /// Drops data queued behind the window. Frames already numbered must
    /// still be delivered, so they stay.
    func discardUnsent() {
        guard let session = sessionManager.existingSession(for: destination, path: path, radio: radio) else { return }
        _ = sessionManager.discardQueuedData(for: session.key)
    }

    /// Ends the link once everything sent has been acknowledged.
    ///
    /// A disconnect discards whatever is queued or unacknowledged (AX.25 2.2,
    /// Figure C4.4, DL-DISCONNECT request), so asking for one straight after
    /// the last send dropped the exchange's closing FQ (smoke run
    /// 2026-10-03-1, issue 32(e)). The wait is bounded by the link itself:
    /// a peer that never acknowledges runs T1 out to N2 and the link fails.
    /// A second call disconnects at once.
    func close() {
        guard !closed else { return }
        if let session = sessionManager.existingSession(for: destination, path: path, radio: radio),
           session.state == .connected || session.state == .connecting {
            if session.state == .connected, !closeWhenDrained, !Self.isDrained(session) {
                closeWhenDrained = true
                return
            }
            sendDisconnect(session)
        } else {
            closed = true
            releaseClaim()
            onClose?(nil)
        }
    }

    /// NET/ROM arrived on the link: the station at the other end is a node
    /// using it for a circuit, not a Winlink caller (smoke run 2026-10-03-1,
    /// issue 73). The link is the node's, so it stays up; only B2F lets go.
    private func standAside(for session: AX25Session) {
        guard !closed else { return }
        closed = true
        closeWhenDrained = false
        discardUnsent()
        releaseClaim()
        onStandAside?("\(session.remoteAddress.display) is using this link for NET/ROM, "
                      + "so the Winlink answerer stepped aside and left it to the node.")
    }

    private static func isDrained(_ session: AX25Session) -> Bool {
        session.pendingDataQueue.isEmpty && session.sendBuffer.isEmpty
    }

    private func disconnectIfDrained(_ session: AX25Session) {
        guard closeWhenDrained, !closed, session.state == .connected, Self.isDrained(session) else { return }
        sendDisconnect(session)
    }

    private func sendDisconnect(_ session: AX25Session) {
        closeWhenDrained = false
        if let disc = sessionManager.disconnect(session: session) {
            sendFrames([disc])
        }
        // The DISC/UA exchange completes asynchronously; the state
        // handler fires onClose and releases the claim when it lands.
    }

    private func releaseClaim() {
        if let claim {
            sessionManager.releaseDelivery(claim)
            self.claim = nil
        }
    }
}
