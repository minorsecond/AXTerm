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
    private let channel: UInt8
    private let connectTimeout: TimeInterval

    private var claim: SessionDeliveryClaim?
    private var closed = false

    var onReceive: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    var onDeliveryProgress: ((Int, Int) -> Void)?

    private var submittedBytes = 0

    var endpointDescription: String {
        path.isEmpty ? destination.display : "\(destination.display) via \(path.display)"
    }

    init(
        sessionManager: AX25SessionManager,
        sendFrames: @escaping ([OutboundFrame]) -> Void,
        destination: AX25Address,
        path: DigiPath = DigiPath(),
        channel: UInt8 = 0,
        connectTimeout: TimeInterval = 90
    ) {
        self.sessionManager = sessionManager
        self.sendFrames = sendFrames
        self.destination = destination
        self.path = path
        self.channel = channel
        self.connectTimeout = connectTimeout
    }

    func open() async throws {
        let key = SessionKey(destination: destination, path: path, channel: channel)

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
            }
        ) else {
            throw WinlinkTransportError.sessionBusy(
                "another session to \(destination.display) is already active")
        }
        self.claim = claim

        if let existing = sessionManager.existingSession(for: destination, path: path, channel: channel),
           existing.state == .connected {
            return  // already connected (e.g. retry after a failed handshake)
        }

        if let sabm = sessionManager.connect(to: destination, path: path, channel: channel) {
            sendFrames([sabm])
        }

        switch await sessionManager.awaitConnectionOutcome(key: key, timeout: connectTimeout) {
        case .connected:
            return
        case .refused:
            releaseClaim()
            throw WinlinkTransportError.connectRefused(destination.display)
        case .timeout:
            if let session = sessionManager.existingSession(for: destination, path: path, channel: channel) {
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
            channel: channel,
            pid: 0xF0,
            displayInfo: "Winlink B2F (\(data.count) bytes)")
        sendFrames(frames)
        if let session = sessionManager.existingSession(for: destination, path: path, channel: channel) {
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

    func close() {
        guard !closed else { return }
        if let session = sessionManager.existingSession(for: destination, path: path, channel: channel),
           session.state == .connected || session.state == .connecting {
            if let disc = sessionManager.disconnect(session: session) {
                sendFrames([disc])
            }
            // The DISC/UA exchange completes asynchronously; the state
            // handler fires onClose and releases the claim when it lands.
        } else {
            closed = true
            releaseClaim()
            onClose?(nil)
        }
    }

    private func releaseClaim() {
        if let claim {
            sessionManager.releaseDelivery(claim)
            self.claim = nil
        }
    }
}
