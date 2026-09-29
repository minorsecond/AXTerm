import Foundation

nonisolated enum CIVTransportState: Equatable, Sendable {
    case closed, opening, open
    case failed(String)
}

/// Where CI-V bytes go. A serial port today; the Icom LAN protocol carries
/// the same bytes verbatim inside UDP datagrams, so `CIVClient` never needs
/// to know which.
nonisolated protocol CIVTransport: AnyObject {
    var state: CIVTransportState { get }
    var onBytes: (@Sendable (Data) -> Void)? { get set }
    var onStateChange: (@Sendable (CIVTransportState) -> Void)? { get set }
    func open()
    func close()
    func write(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    /// RTS/DTR for line-keyed PTT. No-op where there are no lines.
    func setModemLines(dtr: Bool?, rts: Bool?)
}

nonisolated enum CIVTransportError: Error, Equatable, Sendable {
    case notOpen
    case notImplemented(String)
    case io(String)
}

/// CI-V over the Icom LAN protocol: the bytes ride verbatim on the
/// session's CI-V stream, so the client is exactly the serial one.
nonisolated final class LANCIVTransport: CIVTransport, @unchecked Sendable {
    let session: IcomLANSession
    private let lock = NSLock()
    private var _state: CIVTransportState = .closed
    var state: CIVTransportState { lock.withLock { _state } }
    var onBytes: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (CIVTransportState) -> Void)?
    private var openTask: Task<Void, Never>?

    init(session: IcomLANSession) {
        self.session = session
        session.onSerialBytes = { [weak self] bytes in self?.onBytes?(bytes) }
        session.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let why): self.setState(.failed(why))
            case .idle: if self.state == .open { self.setState(.closed) }
            case .connecting, .connected: break
            }
        }
    }

    /// Opening is the whole login; `state` goes to `.opening` at once and
    /// to `.open` or `.failed` when the radio has answered.
    func open() {
        guard state != .open, state != .opening else { return }
        setState(.opening)
        openTask = Task { [self] in
            do {
                try await session.open()
                setState(.open)
            } catch {
                setState(.failed((error as? IcomLANError)?.message ?? String(describing: error)))
            }
        }
    }

    func close() {
        openTask?.cancel()
        session.close()
        setState(.closed)
    }

    func write(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        guard state == .open else { completion(CIVTransportError.notOpen); return }
        session.sendSerial(data)
        completion(nil)
    }

    /// The radio's WLAN carries no control lines; PTT is a CI-V command.
    func setModemLines(dtr: Bool?, rts: Bool?) {}

    private func setState(_ new: CIVTransportState) {
        let changed: Bool = lock.withLock {
            guard _state != new else { return false }
            _state = new
            return true
        }
        if changed { onStateChange?(new) }
    }
}
