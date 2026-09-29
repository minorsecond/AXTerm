import Foundation

/// The digipeater path an APRS transmission asks for.
///
/// **Nothing on APRS is repeated automatically.** A digipeater repeats a frame
/// only when the frame's AX.25 path names it — by callsign, by alias, or by the
/// `WIDEn-N` convention — so a frame sent with no path reaches whoever is in
/// direct earshot and nobody else. A station whose path is empty is invisible
/// past its own horizon however good its antenna is, which is exactly what a
/// silent `?APRSP` to a station two hops away looks like.
///
/// `n-N` is a hop budget the *sender* sets and each digipeater decrements:
/// `WIDE2-2` asks for two wide-area hops, and the digi that takes the last one
/// marks the entry used. `WIDE1-1` is answered only by fill-in ("home") digis,
/// which is why the usual fixed-station path leads with it.
nonisolated enum APRSPath {

    /// The most hops any one path entry may ask for.
    ///
    /// Three, matching Xastir's `MAX_WIDES` (`src/util.h`), whose
    /// `check_unproto_path` is the de-facto definition of a socially
    /// acceptable path — it is what a large part of the network is checked
    /// against before it transmits.
    static let maxWides = 3

    /// The paths worth offering, in the order a station should consider them.
    /// Empty is direct: the honest default for a station that has not decided,
    /// because it puts nothing extra on the channel.
    static let presets: [String] = ["", "WIDE1-1", "WIDE1-1,WIDE2-1", "WIDE2-1", "WIDE2-2"]

    /// How a path reads in a menu.
    static func label(_ path: String) -> String {
        let text = path.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Direct — no digipeaters" : text
    }

    /// Parse a path the operator typed. Same grammar as the beacon's.
    static func digis(_ path: String) -> [String] {
        (try? BeaconPlan.planPath(path).get()) ?? []
    }

    /// How many times the channel carries one frame sent on this path: our
    /// transmission plus every hop we asked for.
    ///
    /// A `WIDEn-N` entry costs `N`, not one: `WIDE2-2` is two further
    /// transmissions. An explicit callsign or a non-`WIDE` alias costs one.
    static func transmissions(_ path: String) -> Int {
        digis(path).reduce(1) { total, token in
            total + hops(of: token)
        }
    }

    /// The hops one path entry asks for.
    static func hops(of token: String) -> Int {
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let n = Int(parts[1]), n > 0 else { return 1 }
        return n
    }

    /// What is worth saying about a path before it goes on the air, or nil
    /// when there is nothing to say.
    ///
    /// Not validation — `BeaconPlan.planPath` does that. This is the etiquette
    /// a shared channel runs on, and the reason `WIDE4-4` is not in `presets`:
    /// the New-N paradigm exists because unbounded paths flooded APRS, and
    /// most modern digipeaters now ignore them outright.
    static func advice(_ path: String) -> String? {
        let tokens = digis(path)
        if tokens.isEmpty { return nil }
        if let deprecated = tokens.first(where: { isDeprecated($0) }) {
            return "\(deprecated) is a pre-New-N path. Most digipeaters ignore it, "
                + "so this may go no further than direct. Use WIDE1-1 or WIDE2-1."
        }
        if let problem = unsociable(tokens) { return problem }
        let total = transmissions(path)
        if total > 3 {
            return "Every frame becomes \(total) transmissions on a shared channel. "
                + "Two hops (WIDE1-1,WIDE2-1) reaches almost everything that will "
                + "ever hear you."
        }
        return nil
    }

    /// The rules a path has to keep to be repeated by a well-behaved network,
    /// as enforced by Xastir's `check_unproto_path` (`src/util.c`).
    ///
    /// These are not arbitrary: a fill-in entry anywhere but the front asks
    /// home digis to repeat a frame that has already travelled, and two
    /// `WIDEn-N` entries multiply rather than add — which is how the pre-New-N
    /// network was flooded in the first place.
    static func unsociable(_ tokens: [String]) -> String? {
        var seenWideN = false
        for (index, token) in tokens.enumerated() {
            let call = token.split(separator: "-", maxSplits: 1).first.map(String.init) ?? token
            let isFillIn = call == "RELAY" || token == "WIDE1-1"
            if isFillIn, index > 0 {
                return "\(token) is a fill-in hop and only belongs first in the path: "
                    + "after the first slot it asks home digipeaters to repeat a frame "
                    + "that has already travelled."
            }
            guard call.hasPrefix("WIDE") || call.hasPrefix("TRACE") else { continue }
            let parts = token.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let n = Int(call.dropFirst(call.hasPrefix("WIDE") ? 4 : 5)),
                  let N = Int(parts[1]) else { continue }
            if N == 0 {
                return "\(token) is a used-up digipeater slot — its hops are spent, "
                    + "so no digipeater will act on it."
            }
            if n < N {
                return "\(token) asks for more hops than it declares. In WIDEn-N the "
                    + "first number is the total and the second is what is left, so N "
                    + "can never exceed n."
            }
            if n > maxWides || N > maxWides {
                return "\(token) asks for more than \(maxWides) hops. Most digipeaters "
                    + "will not act on it at all, so it reaches less far than WIDE2-1, "
                    + "not further."
            }
            if token != "WIDE1-1" {
                if seenWideN {
                    return "Two WIDEn-N entries multiply the hops rather than adding "
                        + "them. One is the convention: WIDE1-1,WIDE2-1."
                }
                seenWideN = true
            }
        }
        return nil
    }

    /// The paths the New-N paradigm replaced. `WIDEn-N` with n of 3 or more
    /// asks a whole region to repeat one frame; `RELAY` and `TRACE` are the
    /// generic aliases that made a path impossible to account for.
    static func isDeprecated(_ token: String) -> Bool {
        let call = token.split(separator: "-", maxSplits: 1).first.map(String.init) ?? token
        if call == "RELAY" || call == "TRACE" || call == "TRACEn" || call == "WIDE" { return true }
        if call.hasPrefix("WIDE"), let n = Int(call.dropFirst(4)), n >= 3 { return true }
        if call.hasPrefix("TRACE"), Int(call.dropFirst(5)) != nil { return true }
        return false
    }
}

/// How far a general query is asked.
///
/// Xastir transmits its `?WX?` and `?APRS?` queries on the interface's own
/// UNPROTO path (`db_gui.c` calls `output_my_data` with a null path, which
/// falls through to `select_unproto_path`), so on a normally-configured
/// station a general query *is* digipeated. AXTerm floods direct by default
/// because its probe answers "who can hear me", which only a direct query can
/// honestly answer — but the wide form is the one that fills a map, and it is
/// what the rest of the world does.
nonisolated enum APRSProbeReach: String, Sendable, CaseIterable, Identifiable {
    /// No path. Every answer proves direct earshot.
    case direct
    /// The radio's own APRS path. Answers prove reachability, not earshot.
    case wide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .direct: return "Direct only"
        case .wide: return "Via my APRS path"
        }
    }

    var help: String {
        switch self {
        case .direct:
            return "One transmission, no digipeaters. Everyone who answers can hear this "
                + "station directly — the only form that answers \"who can hear me\"."
        case .wide:
            return "Digipeated on this radio's APRS path, so stations a hop or two away "
                + "answer too. Every one of them transmits a reply, so ask sparingly."
        }
    }
}
