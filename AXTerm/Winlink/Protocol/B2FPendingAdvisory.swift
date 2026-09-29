import Foundation

/// A `;PM:` pending-message advisory — the metadata a remote sends ahead
/// of its proposal block.
///
///     ;PM: WN6OTL JDMCZA45WR5W 1048 KN4LQN@winlink.org Winlink Wednesday Roster
///          dest    MID          size origin             subject…
///
/// The first field is where the message is *going*, not where it came
/// from — which is the opposite of how it reads. Two captures settle it:
/// WN6OTL collecting a roster *published by* KN4LQN, and K0EPI-7
/// collecting `;PM: K0EPI-7 J71ZYJ4NZ90C 1309 SERVICE@winlink.org INQUIRY
/// - …`, an inquiry reply the CMS service sent to K0EPI-7. In both, field
/// one is the station doing the collecting.
///
/// The `FC` proposal that follows carries a MID and two byte counts and
/// nothing else, so this line is the only thing that can tell an operator
/// what they are about to spend airtime on. Both the Winlink CMS and BPQ
/// send them, ahead of the block they describe.
///
/// Advisory in every sense: a remote may send none, may send one for a
/// message it then does not propose, and owes no particular order. Nothing
/// may depend on it — a proposal without an advisory is still downloadable,
/// it just arrives described only by its size.
nonisolated struct B2FPendingAdvisory: Equatable, Sendable {

    /// Whose mailbox this is for — the station collecting it.
    var destination: String
    var mid: String
    /// The byte count as advertised here, which matches the proposal's
    /// *compressed* size — what actually crosses the air.
    var size: Int
    /// Who sent it. An address rather than a bare callsign, usually.
    var origin: String
    /// Free text, and the only human-readable thing known before download.
    /// Empty when the remote sent none.
    var subject: String

    /// Parses one `;PM:` line (without trailing CR/LF). Nil for anything
    /// that is not one, or is too mangled to trust.
    static func parse(_ line: String) -> B2FPendingAdvisory? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix(";PM:") else { return nil }

        // Four fixed fields, then a subject that may contain anything —
        // spaces included — so the split stops after the fourth.
        let body = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
        let parts = body.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count >= 4, let size = Int(parts[2]), size >= 0 else { return nil }

        return B2FPendingAdvisory(
            destination: String(parts[0]),
            mid: String(parts[1]),
            size: size,
            origin: String(parts[3]),
            subject: parts.count > 4 ? String(parts[4]).trimmingCharacters(in: .whitespaces) : "")
    }
}
