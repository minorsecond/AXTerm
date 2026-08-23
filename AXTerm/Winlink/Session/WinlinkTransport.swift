import Foundation

/// A byte-stream transport carrying one Winlink B2F conversation.
///
/// Two implementations exist: `WinlinkAX25Transport` (a claimed AX.25
/// connected-mode session over the TNC) and `WinlinkTelnetTransport`
/// (TCP to the Winlink CMS). The runner drives either identically —
/// B2F itself is transport-agnostic.
@MainActor
protocol WinlinkTransport: AnyObject {

    /// Human-readable endpoint (for logs and the session log table).
    var endpointDescription: String { get }

    /// Delivered bytes, in order. Set before calling `open()`.
    var onReceive: ((Data) -> Void)? { get set }

    /// The link closed — cleanly or otherwise. Set before calling `open()`.
    var onClose: ((String?) -> Void)? { get set }

    /// Reports outbound delivery: bytes confirmed delivered (AX.25: acked
    /// at L2; Telnet: written to the socket) out of bytes submitted.
    var onDeliveryProgress: ((_ bytesDelivered: Int, _ bytesSubmitted: Int) -> Void)? { get set }

    /// Establishes the link. Returns once the peer can receive bytes
    /// (AX.25: session connected; Telnet: TCP up and CMS login completed).
    func open() async throws

    /// Queues bytes for transmission, preserving order.
    func send(_ data: Data)

    /// Politely tears the link down (AX.25 DISC / TCP close).
    func close()
}

nonisolated enum WinlinkTransportError: Error, Equatable {
    case sessionBusy(String)
    case connectRefused(String)
    case connectTimeout(String)
    case loginFailed(String)
}
