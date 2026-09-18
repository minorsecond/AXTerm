import Foundation

/// What to do about the beacon path, weighed against measured conditions.
///
/// The convention says a fixed station uses one hop. Conventions do not know
/// how many digipeaters can hear *this* station or how busy *this* channel is,
/// and both change the answer. One hop on a station only one digipeater can
/// hear is one failure away from being invisible; two hops on a dead-quiet
/// channel costs nobody anything.
///
/// So nothing here fires on a rule alone. Shortening is suggested only when
/// there is redundancy to spare *and* a channel busy enough for the spare
/// copies to cost something, and never when the extra hop is demonstrably
/// reaching a digipeater that the shorter path would not.
nonisolated struct APRSPathRecommendation: Equatable, Sendable {

    enum Verdict: Equatable, Sendable {
        /// The path is doing something, or there is no case for changing it.
        case keep
        /// Redundancy to spare and a channel busy enough to notice.
        case considerShortening(toHops: Int)
        /// Not enough has come back to judge.
        case notEnough
    }

    let verdict: Verdict
    /// The measured facts behind it, in the order they were weighed. Shown
    /// rather than summarised: the operator knows things this does not, and
    /// can only overrule it if they can see what it used.
    let reasons: [String]

    /// Digipeaters hearing us directly that count as redundancy.
    ///
    /// Three, so that losing one to a power cut or a bad afternoon still
    /// leaves two. At two, one failure halves the coverage and the shorter
    /// path stops being a free choice.
    static let wellCoveredDigipeaters = 3

    var isActionable: Bool {
        if case .considerShortening = verdict { return true }
        return false
    }

    var headline: String {
        switch verdict {
        case .notEnough:
            return "Not enough evidence yet to judge your path"
        case .keep:
            return "Keep your path as it is"
        case .considerShortening(let hops):
            return "Consider dropping to \(hops) hop\(hops == 1 ? "" : "s")"
        }
    }

    // MARK: - Deciding

    static func decide(advice: APRSPathAdvice, load: APRSChannelLoad) -> APRSPathRecommendation {
        var reasons: [String] = []

        guard advice.hasEnoughEvidence else {
            return APRSPathRecommendation(
                verdict: .notEnough,
                reasons: ["\(advice.framesObserved) of your own frames have been heard back; "
                          + "\(APRSPathAdvice.minimumFrames) is where one digipeater having a "
                          + "quiet spell stops changing the answer."])
        }

        let direct = advice.digipeaters.filter(\.hearsUsDirect).count
        reasons.append(direct == 0
            ? "Nothing has been seen taking a frame straight off your transmitter."
            : "\(direct) digipeater\(direct == 1 ? "" : "s") hear you directly "
              + "(\(advice.digipeaters.filter(\.hearsUsDirect).map(\.callsign).joined(separator: ", "))).")
        reasons.append("Channel: \(load.summary).")

        // The extra hop is reaching something the shorter path would not. That
        // settles it whatever the channel is doing.
        let extra = advice.reachedOnlyByExtraHops
        if !extra.isEmpty {
            reasons.append("\(extra.map(\.callsign).joined(separator: ", ")) "
                + "\(extra.count == 1 ? "is" : "are") only ever reached through a further hop, "
                + "so shortening would lose \(extra.count == 1 ? "it" : "them").")
            return APRSPathRecommendation(verdict: .keep, reasons: reasons)
        }

        guard advice.isOverProvisioned else {
            reasons.append("Your path already asks for no more than the network needs.")
            return APRSPathRecommendation(verdict: .keep, reasons: reasons)
        }

        guard direct >= wellCoveredDigipeaters else {
            reasons.append("With fewer than \(wellCoveredDigipeaters) hearing you directly, "
                + "one of them going off the air would cost you most of your coverage. "
                + "The spare hop is worth keeping as insurance.")
            return APRSPathRecommendation(verdict: .keep, reasons: reasons)
        }

        guard load.isBusy || load.isEchoHeavy else {
            reasons.append("The channel is quiet enough that the extra copies are not "
                + "costing anyone anything, so there is nothing to gain by changing it.")
            return APRSPathRecommendation(verdict: .keep, reasons: reasons)
        }

        if load.isEchoHeavy {
            reasons.append("More than a third of what you hear is the network repeating "
                + "itself, which is what a neighbourhood of over-long paths sounds like.")
        }
        reasons.append("You have coverage to spare and the channel is busy enough for the "
            + "spare copies to cost something. Note this only covers digipeaters inside your "
            + "own receive range: one too distant to hear could be using the extra hop.")
        return APRSPathRecommendation(
            verdict: .considerShortening(toHops: advice.hopsNeeded), reasons: reasons)
    }
}
