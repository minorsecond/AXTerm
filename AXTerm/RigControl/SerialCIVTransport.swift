#if os(macOS)
import Foundation

/// CI-V over the radio's USB serial port (Port A on an IC-705).
///
/// Baud is nominal — over USB CDC the radio ignores it — and the modem lines
/// are only ever touched by a `SerialLinePTTController`.
nonisolated final class SerialCIVTransport: CIVTransport, @unchecked Sendable {

    let path: String
    private let port: POSIXSerialPort
    private let lock = NSLock()
    private var _state: CIVTransportState = .closed

    var onBytes: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (CIVTransportState) -> Void)?

    var state: CIVTransportState { lock.withLock { _state } }

    init(path: String, baudRate: Int = 115_200) {
        self.path = path
        self.port = POSIXSerialPort(path: path, baudRate: baudRate)
        port.onBytes = { [weak self] data in self?.onBytes?(data) }
        port.onDisconnect = { [weak self] message in self?.setState(.failed(message)) }
    }

    func open() {
        guard state != .open else { return }
        setState(.opening)
        do {
            try port.open()
            setState(.open)
        } catch {
            setState(.failed(Self.describe(error)))
        }
    }

    func close() {
        port.close()
        setState(.closed)
    }

    func write(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        guard state == .open else { completion(CIVTransportError.notOpen); return }
        do {
            try port.write(data)
            completion(nil)
        } catch {
            completion(CIVTransportError.io(Self.describe(error)))
        }
    }

    func setModemLines(dtr: Bool?, rts: Bool?) {
        port.setModemLines(dtr: dtr, rts: rts)
    }

    private func setState(_ new: CIVTransportState) {
        let changed: Bool = lock.withLock {
            guard _state != new else { return false }
            _state = new
            return true
        }
        if changed { onStateChange?(new) }
    }

    private static func describe(_ error: Error) -> String {
        guard let portError = error as? POSIXSerialPort.PortError else { return String(describing: error) }
        switch portError {
        case .alreadyOpen(let path): return "\(path) is already open in this app"
        case .openFailed(let path, let code): return "could not open \(path): \(String(cString: strerror(code)))"
        case .configureFailed(let path, let code): return "could not configure \(path): \(String(cString: strerror(code)))"
        case .notOpen: return "the port is not open"
        case .writeFailed(let code): return "write failed: \(String(cString: strerror(code)))"
        }
    }
}
#endif
