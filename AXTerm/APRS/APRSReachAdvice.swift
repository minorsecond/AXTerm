import Foundation

/// How far a query to this station has to travel, judged by what we have
/// actually heard from it.
///
/// 2026-09-09: six stations were pinged and three of them could never have
/// received the query. AD1CT-4 had not been heard once on either radio; SIMLA
/// (an 85 km mountaintop) and KF0YKI-9 (a mobile ~75 km east) had only ever
/// arrived *through* a digipeater. Every frame AXTerm transmitted went out
/// with no digipeater path. The evidence to prevent all three was already in
/// the station list — nothing looked at it.
///
/// Reception is not proof of the reverse path, and this does not claim it is:
/// hearing a station direct proves a direct path exists in one direction,
/// which is the strongest thing available short of an answer. What it rules
/// out is the case that actually happened — spending a transmission asking,
/// at a reach that demonstrably does not span the gap, a station we have only
/// ever heard relayed.
nonisolated enum APRSReachAdvice: Equatable, Sendable {

    /// Heard direct at least once: its transmitter reaches us unaided.
    case inEarshot
    /// Heard, but only ever relayed by a digipeater.
    case viaDigipeaterOnly
    /// Never heard at all on this radio.
    case neverHeard

    /// One direct reception is enough. A station heard direct once and
    /// digipeated fifty times since is still one with a direct path — the
    /// digipeated copies are the digi being louder, not the path closing.
    static func advise(direct: Int, digipeated: Int) -> APRSReachAdvice {
        if direct > 0 { return .inEarshot }
        return digipeated > 0 ? .viaDigipeaterOnly : .neverHeard
    }

    /// The reach the evidence supports, or `nil` where it supports none and
    /// the operator's own choice should stand.
    var suggestedReach: APRSProbeReach? {
        switch self {
        case .inEarshot: return .direct
        case .viaDigipeaterOnly: return .wide
        // Never heard is not evidence for a reach, only against expecting an
        // answer. Guessing `.wide` here would dress a shot in the dark as a
        // considered choice.
        case .neverHeard: return nil
        }
    }

    /// What to tell the operator before they spend a transmission, if
    /// anything. `nil` where the ordinary case needs no warning.
    var caution: String? {
        switch self {
        case .inEarshot:
            return nil
        case .viaDigipeaterOnly:
            return "Only ever heard through a digipeater, so a direct query "
                + "probably will not reach it."
        case .neverHeard:
            return "Never heard on this radio, so there may be nothing there to answer."
        }
    }

    /// Whether the advice contradicts what the operator currently has selected.
    /// The disagreement is what gets shown; agreement needs no words.
    func disagrees(with reach: APRSProbeReach) -> Bool {
        guard let suggested = suggestedReach else { return false }
        return suggested != reach
    }
}
