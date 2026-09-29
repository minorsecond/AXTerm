import Foundation
@testable import AXTerm

extension RadioStatusSummary {
    /// A radio for the presentation tests. Defaults describe the one-TNC
    /// station every operator had until now: a Direwolf over TCP.
    static func fixture(
        id: String = "radio-primary",
        name: String = "Direwolf",
        callsign: String = "K0EPI-7",
        status: ConnectionStatus = .connected,
        host: String = "192.168.3.218",
        port: Int? = 8001,
        endpoint: String? = nil,
        lastError: String? = nil
    ) -> RadioStatusSummary {
        RadioStatusSummary(
            id: RadioID(rawValue: id),
            name: name,
            callsign: callsign,
            status: status,
            endpoint: endpoint ?? (port.map { "\(host):\($0)" } ?? host),
            host: host,
            port: port,
            lastError: lastError,
            lastRx: nil,
            lastTx: nil)
    }
}
