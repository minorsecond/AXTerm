import Foundation

/// Whether a connected radio's receiver looks deaf.
///
/// A TNC that transmits fine but decodes nothing looks healthy everywhere
/// else in the app: the link is up, beacons go out, the TX light blinks. In
/// the field (2026-09-30) a TNC4 heard nothing for 40 minutes because of the
/// radio's antenna, and nothing on screen said so. This is the rule for
/// saying so, from evidence the engine already keeps: when the radio's link
/// came up, when it last decoded a frame, and how many frames it has sent
/// since the link came up.
///
/// Two kinds of evidence, and a radio that has only just connected meets
/// neither:
///
/// * Silence. Nothing decoded for `quietAfter`, counted from the later of
///   the last decoded frame and the moment the link came up, so a radio that
///   heard plenty before a reconnect is not held to that. An APRS channel is
///   busy almost everywhere, so the default is 20 minutes; a packet channel
///   can be quiet for an hour with nothing wrong, so callers give it longer.
/// * Transmitting into nothing. At least `transmitsBeforeWarning` frames
///   sent since the link came up, at least `minimumConnected` ago, and not a
///   single frame decoded in that time. On APRS a digipeater usually repeats
///   the first beacon within seconds; hearing none of several is worth a look.
nonisolated enum ReceiveHealth {

    enum Verdict: Equatable, Sendable {
        /// Nothing decoded for this many whole minutes.
        case quiet(minutes: Int)
        /// This many frames sent since connecting and nothing decoded.
        case nothingHeardAfterTransmitting(frames: Int, minutes: Int)
    }

    static let aprsQuietAfter: TimeInterval = 20 * 60
    static let packetQuietAfter: TimeInterval = 60 * 60
    static let transmitsBeforeWarning = 3
    static let minimumConnected: TimeInterval = 5 * 60

    /// The warning for one radio, or nil when there is nothing to say.
    ///
    /// - Parameters:
    ///   - connectedAt: when the radio's link came up; nil when it is not up.
    ///   - lastRx: when the radio last decoded a frame, ever.
    ///   - transmittedSinceConnect: frames sent on this radio since `connectedAt`.
    static func assess(connectedAt: Date?, lastRx: Date?, transmittedSinceConnect: Int,
                       now: Date, quietAfter: TimeInterval = aprsQuietAfter) -> Verdict? {
        guard let connectedAt, now >= connectedAt else { return nil }
        let heardSince = lastRx.flatMap { $0 >= connectedAt ? $0 : nil }
        let heardSinceConnect = heardSince != nil
        let quietSince = heardSince ?? connectedAt
        let quiet = now.timeIntervalSince(quietSince)
        if quiet >= quietAfter {
            return .quiet(minutes: Int(quiet / 60))
        }
        let connected = now.timeIntervalSince(connectedAt)
        if !heardSinceConnect, transmittedSinceConnect >= transmitsBeforeWarning,
           connected >= minimumConnected {
            return .nothingHeardAfterTransmitting(frames: transmittedSinceConnect,
                                                  minutes: Int(connected / 60))
        }
        return nil
    }

    /// How long to wait before calling a channel quiet.
    static func quietAfter(onAPRS: Bool) -> TimeInterval {
        onAPRS ? aprsQuietAfter : packetQuietAfter
    }

    /// The line the operator reads.
    static func message(_ verdict: Verdict) -> String {
        switch verdict {
        case .quiet(let minutes):
            return "Nothing received for \(minutes) min. Check the radio's volume, squelch and antenna."
        case .nothingHeardAfterTransmitting(let frames, let minutes):
            return "Sent \(frames) frames in \(minutes) min and heard nothing back. "
                + "Check the radio's volume, squelch and antenna."
        }
    }
}
