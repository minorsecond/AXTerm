import Foundation

/// How many times a stand-down goes out, and when it stops.
///
/// A placement that fails to arrive harms nothing — nobody sees an object that
/// was never transmitted. A kill that fails is the opposite: the object stays
/// standing on every receiver that heard the placement, saying a road is closed
/// that is open, and the operator who sent the kill has no way to tell. So the
/// stand-down is the one thing here that repeats.
///
/// Deliberately not what a live object does. Re-beaconing something that
/// remains true is an open-ended claim on a shared channel and belongs to the
/// operator; a kill is bounded news that has to land once.
nonisolated enum APRSObjectKillRepeat {

    /// Delays after the first stand-down, in seconds.
    ///
    /// Doubling rather than evenly spaced: the first repeat covers a single
    /// collision, the later ones cover a station that was transmitting through
    /// the whole burst. Four frames over seven minutes, then silence — the
    /// object is bounded news, not a claim being maintained.
    ///
    /// Nothing here is shorter than a minute, and that is a wire constraint
    /// rather than politeness. An object timestamp is `DDHHMMz` — minutes, no
    /// seconds — so two kills inside one minute encode to *byte-identical*
    /// frames, and a digipeater's duplicate suppression (Direwolf's `DEDUPE`,
    /// 30 s by default) drops the second. A repeat that no digipeater repeats
    /// is not a repeat.
    static let ladder: [TimeInterval] = [60, 120, 240]

    /// Whether a queued repeat should still be transmitted.
    ///
    /// The hazard this exists for: stand down `AID`, then place `AID` again —
    /// or watch another agency place theirs — and a repeat still in the queue
    /// kills the *new* object on every receiver on the channel. Anything live
    /// under that name means the news has been overtaken, so the repeat is
    /// abandoned. Whose object it is does not matter: killing a stranger's is
    /// the worse of the two mistakes, and it is the one the operator would
    /// never see happen.
    static func stillWanted(key: String, liveObjects: [APRSObjectStore.Placed]) -> Bool {
        !liveObjects.contains { $0.report.key == key }
    }

    /// The key a repeat is filed under, matching how the rest of APRS keys an
    /// object: by name alone, case- and padding-insensitively.
    static func key(_ name: String) -> String {
        APRSObjectReport.wireName(name).trimmingCharacters(in: .whitespaces).uppercased()
    }
}
