import Foundation

/// What a link session reports upward: bytes, deframed frames with their
/// port, the link's state, and its telemetry.
@MainActor
protocol LinkSessionDelegate: AnyObject {
    func linkSession(_ session: LinkSession, didReceiveBytes data: Data)
    func linkSession(_ session: LinkSession, didReceiveAX25 frame: Data, port: UInt8)
    func linkSession(_ session: LinkSession, didReceiveTelemetry frame: Data, port: UInt8)
    func linkSession(_ session: LinkSession, didReceiveUnknown command: UInt8, payload: Data)
    func linkSession(_ session: LinkSession, didChangeState state: KISSLinkState, from previous: KISSLinkState)
    func linkSession(_ session: LinkSession, didError message: String)
    func linkSession(_ session: LinkSession, didUpdateModemTelemetry telemetry: ModemTelemetry)
    func linkSession(_ session: LinkSession, didUpdateRigStatus status: RigStatus, model: String?)
}

extension LinkSessionDelegate {
    func linkSession(_ session: LinkSession, didUpdateModemTelemetry telemetry: ModemTelemetry) {}
    func linkSession(_ session: LinkSession, didUpdateRigStatus status: RigStatus, model: String?) {}
}

/// One byte stream to one TNC: a `KISSLink` and the parser that reassembles
/// its frames.
///
/// The parser has to live here and not with a radio, because a KISS frame
/// can be split across TCP reads and the pieces belong to the stream, not to
/// whichever port the finished frame turns out to be for. Once a frame is
/// whole, its port nibble says which radio it is for, and `RadioManager`
/// hands it on. A Direwolf with two channels is one of these carrying two
/// radios.
///
/// Telemetry — what the TNC called itself, a Mobilinkd's battery and input
/// level — is a fact about the TNC, so it is kept here per link.
@MainActor
final class LinkSession: KISSLinkDelegate {
    /// The transport identity: `RadioProfile.linkKey`.
    let key: String
    let link: KISSLink
    let transport: RadioTransportKind
    /// The TCP endpoint, for packet provenance. Nil for serial and Bluetooth.
    let tcpEndpoint: KISSEndpoint?

    private var parser = KISSFrameParser()
    private(set) var state: KISSLinkState = .disconnected
    private(set) var tncIdentity: String?
    private(set) var mobilinkdBatteryLevel: Int?
    private(set) var mobilinkdInputLevel: MobilinkdInputLevel?
    private(set) var lastError: String?
    /// The built-in modem's telemetry, when this link is one.
    private(set) var modemTelemetry: ModemTelemetry?
    /// What the radio says about itself over CI-V, when this link has one.
    private(set) var rigStatus: RigStatus?

    weak var delegate: LinkSessionDelegate?

    var endpointDescription: String { link.endpointDescription }

    /// Explicit nonisolated deinit: an implicitly isolated deallocating
    /// deinit aborts when the last reference is dropped off the main
    /// executor (see AdaptiveStatusStore and [[axterm-mainactor-default-isolation]]).
    nonisolated deinit {}

    init(key: String, link: KISSLink, transport: RadioTransportKind, tcpEndpoint: KISSEndpoint?) {
        self.key = key
        self.link = link
        self.transport = transport
        self.tcpEndpoint = tcpEndpoint
        link.delegate = self
        #if os(macOS)
        if let modem = link as? ModemRadioLink {
            modem.onTelemetry = { [weak self] telemetry in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.modemTelemetry = telemetry
                    self.delegate?.linkSession(self, didUpdateModemTelemetry: telemetry)
                }
            }
            modem.onRigStatus = { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.rigStatus = status
                    self.delegate?.linkSession(self, didUpdateRigStatus: status, model: modem.rigModel)
                }
            }
        }
        #endif
    }

    /// Marks the link as opening before the transport has said so, so a
    /// caller that connects and then reads the state sees "connecting" and
    /// not the stale "disconnected" the transport will replace a moment
    /// later. Transports report their own transitions after this.
    func open() {
        if state == .disconnected || state == .failed {
            transition(to: .connecting)
        }
        link.open()
    }

    func close() {
        link.close()
        parser.reset()
    }

    /// The machine is going to sleep. The link goes down deliberately and
    /// stays wanted; the parser is reset because a half-read KISS frame will
    /// not be finished by a socket that is about to stop existing.
    func suspend() {
        link.suspend()
        parser.reset()
    }

    /// The machine is back.
    func resume() {
        link.resume()
    }

    /// Raw KISS-framed bytes — hardware commands and the like.
    func send(_ kissFramed: Data, completion: @escaping (Error?) -> Void) {
        link.send(kissFramed, completion: completion)
    }

    /// An AX.25 frame, KISS-framed for the given port.
    func sendAX25(_ ax25: Data, port: UInt8, completion: @escaping (Error?) -> Void) {
        send(KISS.encodeFrame(payload: ax25, port: port), completion: completion)
    }

    /// Asks the TNC to name itself: the KISS SetHardware "TNC:" query.
    /// Direwolf answers; hardware TNCs that do not implement the extension
    /// ignore it. Nothing is transmitted on the air.
    func identifyTNC() {
        send(Data(TNCIdentifier.queryFrame())) { _ in }
    }

    // MARK: - KISSLinkDelegate

    func linkDidReceive(_ data: Data) {
        delegate?.linkSession(self, didReceiveBytes: data)
        for frame in parser.feedFrames(data) {
            switch frame.output {
            case .ax25(let ax25):
                delegate?.linkSession(self, didReceiveAX25: ax25, port: frame.port)
            case .mobilinkdTelemetry(let telemetry):
                absorb(telemetry)
                delegate?.linkSession(self, didReceiveTelemetry: telemetry, port: frame.port)
            case .unknown(let command, let payload):
                delegate?.linkSession(self, didReceiveUnknown: command, payload: payload)
            }
        }
    }

    func linkDidChangeState(_ newState: KISSLinkState) {
        transition(to: newState)
    }

    func linkDidError(_ message: String) {
        // A link that dropped because this machine slept has nothing to put in
        // the connection banner. The raw text is still handed upward — the
        // console says what happened in plain words and the debug log keeps the
        // original — but `lastError` is what `recomputeConnectionError` reads,
        // and an operator coming back to their desk should not be met with
        // `Socket is not connected (NWError 57)` for having closed their lid.
        #if os(macOS)
        if SystemPowerMonitor.shared.cause(forDropAt: Date()) == .systemSleep {
            delegate?.linkSession(self, didError: message)
            return
        }
        #endif
        lastError = message
        delegate?.linkSession(self, didError: message)
    }

    // MARK: - Private

    private func transition(to newState: KISSLinkState) {
        let previous = state
        guard newState != previous else { return }
        state = newState
        if newState != .connected {
            // A TNC that has gone away has not identified itself to us.
            tncIdentity = nil
        }
        if newState == .connected {
            lastError = nil
            #if os(macOS)
            // The modem is ours: it needs no KISS query to say what it is.
            if let modem = link as? ModemRadioLink { tncIdentity = modem.identity }
            #endif
        }
        delegate?.linkSession(self, didChangeState: newState, from: previous)
    }

    /// Reads the TNC's telemetry into this link's own record of it. The
    /// identity check comes first: Direwolf's answer rides the same
    /// SetHardware command Mobilinkd telemetry uses.
    private func absorb(_ telemetry: Data) {
        if let identity = TNCIdentifier.identity(fromTelemetryFrame: telemetry) {
            tncIdentity = identity
        } else if let level = MobilinkdTNC.parseInputLevel(telemetry) {
            mobilinkdInputLevel = level
        } else if let battery = MobilinkdTNC.parseBatteryLevel(telemetry) {
            mobilinkdBatteryLevel = battery
        }
    }
}
