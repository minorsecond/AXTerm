import SwiftUI

/// How a ping's outcome reads on screen.
///
/// Lifted out of the map because two places now show it — the station card and
/// the Ask sheet — and a ping that read one way on the map and another in the
/// dialog would be worse than either. The wording is the feature: these strings
/// are the difference between "no answer" and "it cannot hear you".
enum APRSPingPresentation {

    static func icon(_ ping: APRSPingTracker.Ping) -> String {
        switch ping.outcome {
        case .waiting: return "clock"
        case .confirmed: return "checkmark.circle.fill"
        case .likely: return "checkmark.circle"
        // Silence from a station that repeated us is a different fact from
        // silence out of nothing, and an antenna rather than a question mark
        // is the difference: the link is proven, the answer is missing.
        case .silent: return ping.heardUs ? "antenna.radiowaves.left.and.right" : "questionmark.circle"
        }
    }

    static func tint(_ ping: APRSPingTracker.Ping) -> Color {
        switch ping.outcome {
        case .waiting: return .secondary
        case .confirmed: return .green
        case .likely: return .yellow
        case .silent: return ping.heardUs ? .yellow : .orange
        }
    }

    static func line(_ ping: APRSPingTracker.Ping) -> String {
        switch ping.outcome {
        case .waiting:
            return ping.heardUs
                ? "It repeated our frame, so it hears us. Waiting for a reply\u{2026}"
                : "Pinged \(ping.query)\(ping.reach == .wide ? " via my APRS path" : "") "
                + "— waiting for a reply\u{2026}"
        case .confirmed:
            // A message arriving during a broadcast-answered query is the
            // station talking to us, not the answer. Saying "answered" there
            // credits the question with evidence it did not produce.
            if ping.reply == .addressedUs {
                return ping.reach == .wide
                    ? "It sent us a message, so it is reachable over my APRS path "
                    + "\u{2014} but that is not an answer to \(ping.query), and digipeaters "
                    + "may have carried it either way."
                    : "It sent us a message directly, so it hears us \u{2014} but that is "
                    + "not an answer to \(ping.query)."
            }
            // What an answer proves depends entirely on how the question
            // travelled. A digipeated query may have been repeated twice on
            // the way out and the answer twice on the way back, so the two
            // stations can be nowhere near each other; saying "directly"
            // there claims a measurement nobody made.
            return ping.reach == .wide
                ? "Answered. It is reachable over my APRS path \u{2014} digipeaters may "
                + "have carried the question or the answer, so this is not proof of earshot."
                : "Answered us directly. It heard the ping."
        case .likely:
            return ping.heardUs
                ? "It repeated our frame, and transmitted right after the ping."
                : "Transmitted right after the ping — probably an answer."
        case .silent:
            // The case the operator hits most often, and the one bare silence
            // described worst: a digipeater proves it hears us by repeating
            // us, and then never answers a query in its life.
            let heard = ping.heardUs
                ? "It hears us — it repeated our frame — but did not answer. "
                : "No answer. "
            // A query answered with a message narrows the explanations:
            // silence can no longer be "it answered and we could not tell",
            // which is the standing caveat on a position query.
            if APRSDirectedQuery(rawValue: ping.query)?.isProvable == true {
                return heard + "\(ping.query) is answered with a message when it is answered "
                    + "at all, so this station most likely does not answer queries."
            }
            if ping.reach == .wide {
                // Silence after a digipeated query rules out more: the
                // station is not reachable even a hop away, or does not
                // answer. Reading it as "may not hear us" would send the
                // operator looking at antennas.
                return heard + (ping.heardUs
                    ? "Many digipeaters never answer queries."
                    : "It was asked over my APRS path, so it may be off the air "
                    + "entirely, or may not answer queries.")
            }
            return heard + (ping.heardUs
                ? "Many digipeaters never answer queries."
                : "It may not hear us, or may not answer queries.")
        }
    }

    /// Longer explanation for the same outcome.
    static func help(_ ping: APRSPingTracker.Ping) -> String {
        // Proven reception changes what silence means, so it gets its own
        // explanation rather than a suffix on the general one.
        if ping.heardUs, ping.outcome == .silent {
            return "This station retransmitted one of our frames, so the link works in both "
                + "directions. Digipeating and answering queries are different jobs: a digi "
                + "matches its callsign in the path and repeats the frame without reading the "
                + "payload, while answering \u{003F}APRSP means parsing the message and finding "
                + "its own name in the addressee. Much digipeater software never does the second."
        }
        switch ping.outcome {
        case .waiting:
            return "A directed query is answered immediately by anything that answers at all; "
                + "the window is \(Int(APRSPingTracker.window)) seconds."
        case .confirmed:
            if ping.reply == .addressedUs {
                return "The station sent a message addressed to this one, which is proof it "
                    + "hears us \u{2014} the only unambiguous kind APRS offers. It is not an "
                    + "answer to \(ping.query) though: that query is answered with an ordinary "
                    + "broadcast position, never with a message, so what arrived was this "
                    + "station saying something of its own."
            }
            return "The station sent a message addressed to this one, which is how \(ping.query) "
                + "is answered. That is proof it heard the ping \u{2014} the only unambiguous "
                + "kind APRS offers."
        case .likely:
            return "The station transmitted far sooner than its own beacon interval predicts. "
                + "An APRS position report carries no reference to the query that prompted it, "
                + "so timing is the only evidence available."
        case .silent:
            // Reach matters here and nowhere else: a direct query carries no
            // digipeater path, so no digipeater could have repeated it, and
            // the absence of that evidence says nothing.
            let reach = ping.reach == .direct
                ? " This one went direct, with no digipeater path, so there was nothing for a "
                    + "digipeater to repeat \u{2014} send it via your APRS path if you want that "
                    + "evidence."
                : ""
            return "Nothing attributable arrived. Plenty of stations \u{2014} most trackers and "
                + "many digipeaters \u{2014} never answer queries at all, so silence is not "
                + "proof they cannot hear you." + reach
        }
    }
}
