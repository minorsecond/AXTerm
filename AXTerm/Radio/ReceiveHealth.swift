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
        /// The sound modem heard this many transmissions and decoded this
        /// few frames. `radioSays` is what the radio's own receive audit
        /// found, when the radio has CI-V (empty when it found nothing); nil
        /// when there is no CI-V to ask.
        case hearsButDecodesLittle(carriers: Int, decoded: Int, minutes: Int, radioSays: [String]?)
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
        case .hearsButDecodesLittle(let carriers, let decoded, let minutes, let radioSays):
            let heard = "Heard \(carriers) transmissions in \(minutes) min but decoded "
                + "\(decoded == 1 ? "1 frame" : "\(decoded) frames"). "
            switch radioSays {
            case .none:
                return heard + "Check the radio's notch, noise reduction, filters and audio level."
            case .some(let findings) where findings.isEmpty:
                return heard + "The radio's receive settings look right, so check the audio level "
                    + "and the antenna."
            case .some(let findings):
                return heard + "The radio reports: " + findings.map { $0.lowercased() }.joined(separator: ", ") + "."
            }
        }
    }

    // MARK: - Hearing traffic, decoding little (sound modem)

    // The failure of 2026-09-30: an IC-705 with its notch on decoded about
    // one frame a minute on a channel carrying several, and nothing on screen
    // was wrong. The link was up, frames were arriving, the level was fine.
    // Only the sound modem can see this, because only it has the audio: it
    // counts transmissions from the receiver's noise quieting
    // (`NoiseQuietingDetector`) whether or not it can decode them. A hardware
    // TNC reports levels at most, so this rule never applies to one.

    /// The window carriers and decodes are compared over. Ten minutes of a
    /// busy APRS channel is dozens of transmissions; of a quiet packet
    /// channel, often none, which is what `minimumCarriers` is for.
    static let carrierWindow: TimeInterval = 10 * 60
    /// Fewer transmissions than this is not enough evidence to judge by, and
    /// keeps an idle channel from ever being called deaf.
    static let minimumCarriers = 10
    /// Below this share of transmissions decoded, the receiver is hearing
    /// traffic it cannot read. From the 2026-09-30 comparison: with the notch
    /// off the modem decoded 14 frames in 3 minutes against Direwolf's 17 on
    /// the same audio, most of what was there; with it on, about one a minute,
    /// a small fraction. A quarter sits well clear of both, and of the
    /// collisions and weak stations any shared channel loses.
    static let minimumDecodeRatio = 0.25

    /// The verdict from carriers heard and frames decoded over the window,
    /// or nil when there is too little traffic to say, or the modem is
    /// decoding a fair share of it.
    static func decodeRatio(carriers: Int, decoded: Int, minutes: Int,
                            radioSays: [String]?) -> Verdict? {
        guard carriers >= minimumCarriers else { return nil }
        guard Double(decoded) < minimumDecodeRatio * Double(carriers) else { return nil }
        return .hearsButDecodesLittle(carriers: carriers, decoded: decoded, minutes: minutes,
                                      radioSays: radioSays)
    }

    /// The sound modem's running counts, sampled over time, so carriers and
    /// decodes can be compared over the last `carrierWindow` rather than
    /// since the link came up.
    ///
    /// Samples are cumulative counters from the modem's telemetry. Keeping
    /// one every `spacing` bounds the ledger at about 120 entries.
    struct CarrierLedger: Equatable, Sendable {
        struct Sample: Equatable, Sendable {
            var at: Date
            var carriers: UInt64
            var decoded: UInt64
        }

        static let spacing: TimeInterval = 5
        private(set) var history: [Sample] = []
        private(set) var latest: Sample?

        init() {}

        /// Take the modem's counters as of `at`. Counters that go backward
        /// mean the modem restarted; what came before says nothing about it.
        mutating func record(at: Date, carriers: UInt64, decoded: UInt64) {
            let sample = Sample(at: at, carriers: carriers, decoded: decoded)
            if let last = latest, carriers < last.carriers || decoded < last.decoded {
                history.removeAll()
            }
            latest = sample
            if let kept = history.last, at.timeIntervalSince(kept.at) < Self.spacing { return }
            history.append(sample)
            // Keep one sample at or before the window's start, as the
            // baseline the window is measured from.
            let start = at.addingTimeInterval(-ReceiveHealth.carrierWindow)
            while history.count > 1, history[1].at <= start { history.removeFirst() }
        }

        /// Carriers and decodes over the window ending `now`, and how many
        /// whole minutes that covers. Nil before there are two samples.
        func counts(now: Date) -> (carriers: Int, decoded: Int, minutes: Int)? {
            guard let latest else { return nil }
            let start = now.addingTimeInterval(-ReceiveHealth.carrierWindow)
            guard let baseline = history.last(where: { $0.at <= start }) ?? history.first,
                  latest.at > baseline.at else { return nil }
            return (Int(latest.carriers &- baseline.carriers),
                    Int(latest.decoded &- baseline.decoded),
                    Int(latest.at.timeIntervalSince(baseline.at) / 60))
        }
    }
}
