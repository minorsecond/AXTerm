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

    // Two constants, used as default arguments to this type's initialiser.
    // A default argument is evaluated in the caller's context, so leaving
    // these on the main actor — which the project's default isolation does
    // — made every nonisolated caller a warning.
    nonisolated static let defaultHost = "cms.winlink.org"
    nonisolated static let defaultPort: UInt16 = 8772
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
            // The weak reference is read once, here, into a local. Reading
            // it inside the Task means the concurrently-executing closure
            // touches the captured variable itself, which Swift 6 rejects.
            // A strong capture would be worse: the connection owns this
            // handler and this object owns the connection, so it would be a
            // retain cycle rather than a fix.
            connection.stateUpdateHandler = { [weak self] state in
                let transport = self
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
                            transport?.handleClosed("connection failed: \(error.localizedDescription)")
                        }
                    case .cancelled:
                        transport?.handleClosed(nil)
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
            // See `open()`: one read of the weak reference, out here.
            let transport = self
            Task { @MainActor in
                guard let transport else { return }
                transport.deliveredBytes += count
                transport.onDeliveryProgress?(transport.deliveredBytes, transport.submittedBytes)
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
            // See `open()`: one read of the weak reference, out here.
            let transport = self
            Task { @MainActor in
                guard let transport else { return }
                if let data, !data.isEmpty {
                    transport.handleIncoming(data)
                }
                if isComplete || error != nil {
                    transport.handleClosed(error.map { "connection error: \($0.localizedDescription)" })
                    return
                }
                transport.receiveLoop()
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
