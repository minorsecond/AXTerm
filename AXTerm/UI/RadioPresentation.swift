import Foundation

/// What one radio's link looks like from outside, for the status surfaces:
/// the toolbar capsule, the sidebar rows, the menu bar item, the iOS strip.
nonisolated struct RadioStatusSummary: Hashable, Sendable {
    let id: RadioID
    let name: String
    /// The callsign this radio operates as, SSID included.
    let callsign: String
    let status: ConnectionStatus
    /// Where the link goes, as the operator would say it:
    /// "192.168.3.218:8001" or "/dev/cu.usbserial-1420".
    let endpoint: String
    /// The TCP pieces when there are any. The single-radio surfaces have
    /// always shown the host alone, and spoken "at host port N".
    let host: String
    let port: Int?
    let lastError: String?
    let lastRx: Date?
    let lastTx: Date?
    // Only the built-in modem knows these; nil for a TNC, and then every
    // string below is exactly what it was.
    var frequencyHz: Int? = nil
    var modeLabel: String? = nil
    var dcd: Bool? = nil
    var ptt: Bool? = nil
    var rxLevelDBFS: Float? = nil
}

/// The words and tints the status surfaces use, free of SwiftUI.
///
/// With one radio these reproduce today's strings exactly — the parity tests
/// pin them — so an operator with one TNC sees nothing change. With several,
/// the same functions say how many, and which.
nonisolated enum RadioPresentation {

    /// A status colour, named rather than a `Color` so it can be tested.
    enum Tint: Equatable, Sendable {
        case connected, connecting, failed, idle
    }

    static func tint(for status: ConnectionStatus) -> Tint {
        switch status {
        case .connected: .connected
        case .connecting: .connecting
        case .failed: .failed
        case .disconnected: .idle
        }
    }

    /// One status for a set of radios, for the surfaces that still show a
    /// single dot. Any working link counts as working; a link still coming
    /// up outranks one that has failed, because the operator can still wait
    /// for it.
    static func aggregateStatus(_ statuses: [ConnectionStatus]) -> ConnectionStatus {
        if statuses.contains(.connected) { return .connected }
        if statuses.contains(.connecting) { return .connecting }
        if statuses.contains(.failed) { return .failed }
        return .disconnected
    }

    /// The toolbar capsule's label.
    static func capsuleLabel(_ radios: [RadioStatusSummary]) -> String {
        guard radios.count > 1 else {
            // One radio: the strings the capsule has always shown.
            let radio = radios.first
            switch radio?.status ?? .disconnected {
            case .connected:
                let shown = (radio?.host.isEmpty == false) ? radio!.host : (radio?.endpoint ?? "")
                return "TNC: \(shown)"
            case .connecting: return "TNC Connecting\u{2026}"
            case .disconnected: return "TNC Disconnected"
            case .failed: return "TNC Failed"
            }
        }
        let connected = radios.filter { $0.status == .connected }.count
        if connected == radios.count { return "Radios: \(connected) connected" }
        if connected > 0 { return "Radios: \(connected) of \(radios.count)" }
        if radios.contains(where: { $0.status == .connecting }) { return "Radios Connecting\u{2026}" }
        let failed = radios.filter { $0.status == .failed }.count
        if failed > 0 { return "Radios: \(failed) failed" }
        return "Radios Disconnected"
    }

    /// Help text for one radio's dot: which radio, how it is doing, where
    /// its link goes and who it is on the air — enough to act on without
    /// opening anything.
    static func dotHelp(_ radio: RadioStatusSummary) -> String {
        var line = "\(radio.name): \(radio.status.rawValue)"
        if !radio.endpoint.isEmpty { line += " \u{b7} \(radio.endpoint)" }
        if !radio.callsign.isEmpty { line += " \u{b7} \(radio.callsign)" }
        if let hz = radio.frequencyHz {
            line += " \u{b7} " + String(format: "%.3f MHz", Double(hz) / 1_000_000)
            if let mode = radio.modeLabel { line += " \(mode)" }
        }
        if radio.status == .failed, let error = radio.lastError, !error.isEmpty {
            line += " \u{2014} \(error)"
        }
        return line
    }

    /// The sidebar section header. Says how many are up only when not all of
    /// them are, and how many the operator has hidden only when some are.
    static func sidebarTitle(total: Int, connected: Int, hidden: Int) -> String {
        var title = connected == total
            ? "Radios (\(total))"
            : "Radios (\(connected) of \(total) connected)"
        if hidden > 0 { title += " \u{b7} \(hidden) hidden" }
        return title
    }
}
