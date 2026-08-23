import Foundation
import Network

/// B2F transport over TCP to the Winlink CMS ("Telnet" access).
///
/// The CMS telnet service is a plain byte stream (no telnet option
/// negotiation) with a two-prompt login preamble:
///
///     Callsign : <callsign CR>
///     Password : CMSTELNET <CR>
///
/// The account's real password is NOT sent here — authentication happens
/// inside B2F via the `;PQ:`/`;PR:` secure-login exchange, exactly as on
/// the radio path. After the preamble, bytes pass through untouched.
@MainActor
final class WinlinkTelnetTransport: WinlinkTransport {

    static let defaultHost = "cms.winlink.org"
    static let defaultPort: UInt16 = 8772
    static let telnetAccessPassword = "CMSTELNET"

    private enum LoginPhase {
        case awaitingCallsignPrompt
        case awaitingPasswordPrompt
        case passthrough
    }

    private let host: String
    private let port: UInt16
    private let callsign: String
    private var connection: NWConnection?
    private var loginPhase: LoginPhase = .awaitingCallsignPrompt
    private var promptBuffer = Data()
    private var closed = false

    var onReceive: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    var onDeliveryProgress: ((Int, Int) -> Void)?

    private var submittedBytes = 0
    private var deliveredBytes = 0

    var endpointDescription: String { "\(host):\(port)" }

    init(callsign: String, host: String = WinlinkTelnetTransport.defaultHost,
         port: UInt16 = WinlinkTelnetTransport.defaultPort) {
        self.callsign = callsign
        self.host = host
        self.port = port
    }

    func open() async throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        if !resumed {
                            resumed = true
                            continuation.resume()
                        }
                    case .failed(let error):
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: WinlinkTransportError.loginFailed(
                                "TCP connect failed: \(error.localizedDescription)"))
                        } else {
                            self?.handleClosed("connection failed: \(error.localizedDescription)")
                        }
                    case .cancelled:
                        self?.handleClosed(nil)
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
        }

        receiveLoop()
    }

    func send(_ data: Data) {
        submittedBytes += data.count
        let count = data.count
        connection?.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.deliveredBytes += count
                self.onDeliveryProgress?(self.deliveredBytes, self.submittedBytes)
            }
        })
    }

    func close() {
        guard !closed else { return }
        connection?.cancel()
    }

    // MARK: - Receive path

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.handleIncoming(data)
                }
                if isComplete || error != nil {
                    self.handleClosed(error.map { "connection error: \($0.localizedDescription)" })
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        switch loginPhase {
        case .passthrough:
            onReceive?(data)

        case .awaitingCallsignPrompt, .awaitingPasswordPrompt:
            promptBuffer.append(data)
            processLoginPrompts()
        }
    }

    private func processLoginPrompts() {
        let text = String(data: promptBuffer, encoding: .isoLatin1)?.lowercased() ?? ""

        if loginPhase == .awaitingCallsignPrompt, text.contains("callsign"), text.contains(":") {
            send(Data("\(callsign)\r".utf8))
            promptBuffer.removeAll()
            loginPhase = .awaitingPasswordPrompt
            return
        }

        if loginPhase == .awaitingPasswordPrompt, text.contains("password"), text.contains(":") {
            send(Data("\(Self.telnetAccessPassword)\r".utf8))
            promptBuffer.removeAll()
            loginPhase = .passthrough
            return
        }
    }

    private func handleClosed(_ reason: String?) {
        guard !closed else { return }
        closed = true
        onClose?(reason)
    }
}
