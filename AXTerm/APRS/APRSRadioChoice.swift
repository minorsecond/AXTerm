import Foundation

/// Which radio to answer a station on.
///
/// Two radios are two channels. A station worked on 144.390 is not reachable by
/// transmitting on the node frequency, so "the first connected APRS radio" is a
/// coin toss dressed as a decision — right half the time on a two-radio station
/// and wrong the other half, silently.
///
/// The evidence is already there: every station record carries what each radio
/// heard of it and when. Xastir uses the same rule from the same evidence —
/// `transmit_message_data` sends out the port a station was heard on if it was
/// heard there within the past hour (`src/messages.c`).
nonisolated enum APRSRadioChoice {

    /// How stale a hearing may be and still name the channel a station is on.
    /// An hour, matching Xastir's `heard_via_tnc_in_past_hour`: long enough to
    /// cover a beacon interval and a quiet spell, short enough that a station
    /// heard yesterday does not decide today's transmission.
    static let window: TimeInterval = 3600

    /// The radio that heard `callsign` most recently, if it heard it inside the
    /// window and that radio is one we could actually transmit on.
    ///
    /// - Parameter eligible: the radios connected and carrying APRS. A radio
    ///   that heard the station but is now disconnected is not an answer.
    static func radioThatHeard(_ callsign: String, in stations: [Station],
                               now: Date, eligible: Set<RadioID>) -> RadioID? {
        guard !eligible.isEmpty else { return nil }
        let wanted = callsign.uppercased()
        guard let station = stations.first(where: { $0.call.uppercased() == wanted })
        else { return nil }
        return station.perRadio
            .filter { eligible.contains($0.key) && now.timeIntervalSince($0.value.lastHeard) <= window }
            .max { $0.value.lastHeard < $1.value.lastHeard }?
            .key
    }
}
