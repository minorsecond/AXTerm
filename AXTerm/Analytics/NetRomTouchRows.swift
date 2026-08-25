import SwiftUI

/// How a routing entry reads on a handheld.
///
/// The macOS tables put nine columns side by side, which works in a 900pt
/// window and does not work at all on an 834pt iPad: the destination callsign
/// — the one field a routing view exists to show — truncates to `KB5YZB…`
/// while `Hops` gets a column of its own. On touch the same facts are stacked
/// instead, most important first.
///
/// The composition lives here rather than in the view so it can be tested:
/// what a routing table says about a link is the product, not decoration.
nonisolated enum NetRomTouchRow {

    /// "EVANS → DRLNOD". The pair is the fact; splitting it across two
    /// columns made the reader reassemble it.
    static func headline(destination: String, nextHop: String) -> String {
        guard !nextHop.isEmpty, nextHop != destination else { return destination }
        return "\(destination) → \(nextHop)"
    }

    /// One line of secondary facts, skipping anything absent so the row does
    /// not carry empty separators.
    ///
    /// An unknown hop count is **omitted**, not printed as a dash. The table
    /// could show "—" under a `Hops` header and be understood; on a row with
    /// no column labels a bare dash reads as a value rather than as an
    /// absence, and "— hops" reads as nothing at all. Unknown is also not
    /// zero — a route heard by broadcast carries no hop count, and "0 hops"
    /// would claim the destination is this station.
    static func detail(hops: Int?, updated: String, freshness: String) -> String {
        [hops.map { "\($0) hop\($0 == 1 ? "" : "s")" },
         updated.isEmpty ? nil : updated,
         freshness.isEmpty ? nil : freshness]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Whether the path adds anything the headline has not already said.
    ///
    /// A single-hop route's path *is* its next hop, and printing `DRLNOD`
    /// directly under `EVANS → DRLNOD` spends a line to repeat a word.
    static func shouldShowPath(_ path: String, nextHop: String) -> Bool {
        !path.isEmpty && path != nextHop
    }

    /// A measured value, or a dash where there is no measurement.
    ///
    /// Distinguished on purpose: "no observations yet" and "measured as zero"
    /// mean opposite things about a link, and a bare 0.00 would assert the
    /// second when the truth is the first.
    static func metric(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(decimals)f", value)
    }

    /// Spoken form for a link's directional probabilities, since "df 0.97 dr
    /// 0.96" is meaningless read aloud.
    static func spokenLink(from: String, to: String, df: Double?, dr: Double?) -> String {
        var parts = ["Link from \(from) to \(to)"]
        if let df { parts.append("forward delivery \(Int((df * 100).rounded())) percent") }
        if let dr { parts.append("reverse delivery \(Int((dr * 100).rounded())) percent") }
        return parts.joined(separator: ", ")
    }
}
