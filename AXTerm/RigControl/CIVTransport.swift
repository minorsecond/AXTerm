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

/// Placeholder for CI-V over the Icom LAN protocol (UDP :50002). Exists so
/// the client is exercised against two transport shapes; a real
/// implementation replaces it without touching the client.
nonisolated final class LANCIVTransport: CIVTransport, @unchecked Sendable {
    let host: String
    let port: UInt16
    private(set) var state: CIVTransportState = .closed
    var onBytes: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (CIVTransportState) -> Void)?

    init(host: String, port: UInt16 = 50002) {
        self.host = host
        self.port = port
    }

    func open() {
        state = .failed("Icom LAN control is not implemented yet")
        onStateChange?(state)
    }

    func close() {
        state = .closed
        onStateChange?(state)
    }

    func write(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        completion(CIVTransportError.notImplemented("Icom LAN control"))
    }

    func setModemLines(dtr: Bool?, rts: Bool?) {}
}
