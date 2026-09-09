import Foundation

/// National Weather Service watches and warnings, as they arrive over APRS.
///
/// These are worth having and they come with a caveat that has to travel with
/// them everywhere: **they are internet-fed**. NWS alerts reach APRS through a
/// gateway (conventionally `WXSVR`) that reads them from the NWS feed and
/// transmits them as bulletins. The RF hop from that gateway to you keeps
/// working when your own internet fails; the hop from the NWS to the gateway
/// does not. In the situation this app is built for, the gateway is very
/// likely the first thing to go.
///
/// So the failure mode is specific and dangerous: the last warning the gateway
/// managed to send stays on the air, being repeated by digipeaters, looking
/// exactly like a current one. A tornado warning from six hours ago is not a
/// forecast — it is a fossil — and nothing in the packet says which it is.
/// Every alert here therefore carries the time *this receiver* heard it, and
/// the UI is expected to show that age rather than the alert alone.
nonisolated struct APRSWeatherAlert: Equatable, Sendable {

    /// How seriously to treat it. Read from the wording, because APRS
    /// bulletins carry no severity field of their own.
    enum Severity: Int, Comparable, Sendable {
        case statement
        case watch
        case warning

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .warning: return "Warning"
            case .watch: return "Watch"
            case .statement: return "Statement"
            }
        }
    }

    /// The station that transmitted it — the gateway, not the NWS.
    var source: String
    /// Bulletin identifier, so repeats of the same bulletin collapse.
    var identifier: String
    var text: String
    var severity: Severity
    /// When this receiver heard it. Never the sender's clock.
    var heard: Date

    /// Alerts older than this are almost certainly a gateway that has gone
    /// off the air rather than weather that is still happening.
    static let freshWindow: TimeInterval = 2 * 3600

    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(heard) > Self.freshWindow
    }

    /// The line that must appear wherever the alert does.
    func provenance(now: Date = Date()) -> String {
        let age = heard.formatted(.relative(presentation: .named))
        let base = "Relayed by \(source) \(age) \u{2014} originally from an internet feed"
        return isStale(now: now)
            ? base + ". No update since; treat as possibly out of date."
            : base + "."
    }
}

extension APRSWeatherAlert {

    /// Callsign prefixes conventionally used by NWS relay gateways. Matching
    /// on the sender rather than the text keeps ordinary bulletins — a club
    /// net announcement, a swap-meet notice — out of the alert list.
    static let gatewayPrefixes = ["WXSVR", "NWS", "SKYWARN"]

    static func isGateway(_ callsign: String) -> Bool {
        let call = callsign.uppercased()
        return gatewayPrefixes.contains { call.hasPrefix($0) }
    }

    /// Classifies a bulletin heard from `source`, or nil when it is not a
    /// weather alert.
    ///
    /// Two independent signals are required: the sender looks like a gateway,
    /// **and** the text reads like an alert. Either alone produces false
    /// positives — a station called `NWSMITH` is a person, and a club bulletin
    /// mentioning a "flood watch" fundraiser is not a warning.
    static func classify(bulletinID: String, text: String, from source: String,
                         heard: Date) -> APRSWeatherAlert? {
        guard isGateway(source) else { return nil }
        guard let severity = severity(of: text) else { return nil }
        return APRSWeatherAlert(source: source.uppercased(), identifier: bulletinID,
                                text: text.trimmingCharacters(in: .whitespaces),
                                severity: severity, heard: heard)
    }

    /// Severity from the wording. Ordered so "warning" wins over "watch" when
    /// a bulletin mentions both, which the NWS does routinely when one
    /// replaces the other.
    static func severity(of text: String) -> Severity? {
        let upper = text.uppercased()
        if upper.contains("WARNING") { return .warning }
        if upper.contains("WATCH") { return .watch }
        if upper.contains("ADVISORY") || upper.contains("STATEMENT") { return .statement }
        return nil
    }
}

/// The alerts currently on the air, newest and most severe first.
nonisolated struct APRSWeatherAlertStore: Equatable, Sendable {

    private(set) var alerts: [String: APRSWeatherAlert] = [:]

    /// Keyed by gateway and bulletin id together: two gateways relaying the
    /// same NWS product are two pieces of evidence that it is real, and
    /// collapsing them would hide that.
    @discardableResult
    mutating func record(_ alert: APRSWeatherAlert) -> Bool {
        let key = "\(alert.source)|\(alert.identifier)"
        let existed = alerts[key]
        alerts[key] = alert
        return existed?.text != alert.text
    }

    /// Everything heard, worst first, then newest. Stale ones are **not**
    /// dropped: an operator needs to see that a warning exists and has gone
    /// quiet, which is different information from no warning at all.
    func all(now: Date = Date()) -> [APRSWeatherAlert] {
        alerts.values.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.heard > $1.heard
        }
    }

    func current(now: Date = Date()) -> [APRSWeatherAlert] {
        all(now: now).filter { !$0.isStale(now: now) }
    }
}
