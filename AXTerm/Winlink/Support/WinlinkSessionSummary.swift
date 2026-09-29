import Foundation

/// One past exchange, in the terms an operator asks about it afterwards.
///
/// The log rows hold the facts; this turns them into the three answers that
/// get looked for: how long it took, whether the airtime bought anything,
/// and — when it did not work — why.
nonisolated struct WinlinkSessionSummary: Equatable, Sendable, Identifiable {

    let log: WinlinkSessionLogRecord

    var id: Int64 { log.id ?? 0 }

    init(log: WinlinkSessionLogRecord) {
        self.log = log
    }

    var succeeded: Bool { log.result == "success" && log.errorText == nil }

    /// Rounded to whole seconds: sub-second precision on a link measured in
    /// minutes is noise, and a failed connect really does take under a
    /// second, so it must still read as a duration rather than a blank.
    var durationText: String {
        let total = Int(log.duration.rounded())
        guard total >= 60 else { return "\(max(0, total))s" }
        return "\(total / 60)m \(total % 60)s"
    }

    /// Bytes both ways over the whole session — the figure that says whether
    /// the airtime was worth spending. Nil when there was no time to measure
    /// over, because a rate there would be an artefact rather than a fact.
    var bytesPerSecond: Double? {
        let seconds = log.duration
        guard seconds > 0 else { return nil }
        return Double(log.bytesSent + log.bytesReceived) / seconds
    }

    var trafficText: String {
        let sent = log.messagesSent
        let received = log.messagesReceived
        guard sent > 0 || received > 0 else {
            // A connection that moved nothing is a real outcome — it is what
            // an empty mailbox looks like — and deserves saying.
            return "nothing moved"
        }
        return "\(sent) sent · \(received) received"
    }

    /// Why this session is worth looking at. For a failure that is the
    /// reason, which is the entire point of opening it.
    var outcomeText: String {
        if succeeded { return "Succeeded" }
        let detail = log.errorText ?? log.result
        return detail.isEmpty ? "Failed" : detail
    }

    /// A callsign alone does not identify a link: the same gateway answers
    /// on several frequencies and they behave nothing alike.
    var linkText: String {
        guard let hz = log.frequencyHz else { return log.gatewayCallsign }
        let mhz = Double(hz) / 1_000_000
        return "\(log.gatewayCallsign) · \(String(format: "%.3f", mhz)) MHz"
    }
}
