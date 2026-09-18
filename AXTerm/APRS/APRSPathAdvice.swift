import Foundation

/// Whether the path this station beacons with is buying it anything.
///
/// An APRS path asks digipeaters to repeat a frame a given number of times.
/// Every extra hop is another copy of the frame on a shared channel, so a path
/// longer than the network needs costs everybody airtime and the operator
/// nothing but goodwill. `WIDE1-1,WIDE2-1` is the usual default and is usually
/// one hop more than a well-sited station needs.
///
/// The evidence is already on the air: our own frames come back when a
/// digipeater repeats them, and the hops marked used say who repeated and in
/// what order. A digipeater that appears first heard us off our own
/// transmitter. One that only ever appears later heard a repeat, and is the
/// only kind of station an extra hop actually buys.
///
/// What this can and cannot see is the whole of its honesty. The evidence is
/// our own frames coming *back*, so it only ever covers digipeaters inside our
/// own receive range. A digipeater eighty miles away that repeated us on a
/// second hop never reaches our receiver and is invisible here. So the finding
/// is never "the extra hop reaches nobody" — it is "nothing you can hear
/// needed it", which is a smaller claim and the only one the evidence carries.
///
/// It never recommends a *longer* path either. Hearing nothing through a
/// second hop looks identical whether there is nothing out there or whether
/// what is out there is switched off.
nonisolated struct APRSPathAdvice: Equatable, Sendable {

    /// How one digipeater has been seen handling our frames.
    struct Digipeater: Equatable, Sendable, Identifiable {
        let callsign: String
        /// It took the frame straight off our transmitter at least once.
        let hearsUsDirect: Bool
        /// The shallowest hop it has ever repeated at, counting from 0.
        let shallowestHop: Int

        var id: String { callsign }
    }

    /// Every digipeater that has repeated us, nearest first.
    let digipeaters: [Digipeater]
    /// How many of our own frames came back, which is what all of this rests
    /// on. A handful is a hint; a few dozen is a finding.
    let framesObserved: Int
    /// Hops the current path asks for.
    let hopsRequested: Int
    /// The fewest hops that would still have reached every digipeater that
    /// has ever repeated us.
    let hopsNeeded: Int

    /// Whether there is enough evidence to say anything at all.
    ///
    /// Ten returned frames is the floor. Below that a single lucky opening, or
    /// one digipeater being briefly off the air, moves the answer.
    static let minimumFrames = 10

    var hasEnoughEvidence: Bool { framesObserved >= Self.minimumFrames }
    /// True when the path asks for more hops than anything has ever needed.
    ///
    /// Needing zero hops is not a finding that the path should be emptied: it
    /// means nothing has ever repeated us, and a station with no digipeater
    /// evidence at all has no basis to shorten anything.
    var isOverProvisioned: Bool {
        hasEnoughEvidence && hopsNeeded > 0 && hopsRequested > hopsNeeded
    }

    /// Digipeaters an extra hop is actually reaching.
    var reachedOnlyByExtraHops: [Digipeater] {
        digipeaters.filter { !$0.hearsUsDirect }
    }

    // MARK: - Building

    /// Reads the advice out of who repeated us at which hop.
    ///
    /// - Parameters:
    ///   - repeatHops: hop positions per digipeater, from `CoverageEvidence`.
    ///   - framesObserved: how many of our own frames came back.
    ///   - hopsRequested: hops the beacon path asks for, e.g. 2 for
    ///     `WIDE1-1,WIDE2-1`.
    static func from(repeatHops: [String: Set<Int>],
                     framesObserved: Int,
                     hopsRequested: Int) -> APRSPathAdvice {
        let digipeaters = repeatHops.compactMap { call, hops -> Digipeater? in
            guard let shallowest = hops.min() else { return nil }
            return Digipeater(callsign: call,
                              hearsUsDirect: shallowest == 0,
                              shallowestHop: shallowest)
        }
        .sorted {
            // Nearest first, then alphabetically so the list never reshuffles
            // under the operator between two equally shallow digipeaters.
            ($0.shallowestHop, $0.callsign) < ($1.shallowestHop, $1.callsign)
        }

        // One hop reaches a digipeater at position 0, two reach position 1,
        // and so on. The deepest anything has needed is the answer, and a
        // network that has never answered needs none of them.
        let deepest = digipeaters.map(\.shallowestHop).max()
        let needed = deepest.map { $0 + 1 } ?? 0
        return APRSPathAdvice(
            digipeaters: digipeaters,
            framesObserved: framesObserved,
            hopsRequested: hopsRequested,
            hopsNeeded: needed)
    }

    /// How many hops a beacon path asks for.
    ///
    /// Counts the hops still available to be used rather than the entries:
    /// `WIDE1-1,WIDE2-1` is two, `WIDE2-2` is also two, and a digipeater named
    /// outright is one. An entry already marked used belongs to a received
    /// frame's history, not to a request.
    static func hopsRequested(in path: [String]) -> Int {
        path.reduce(into: 0) { total, entry in
            let trimmed = entry.trimmingCharacters(in: .whitespaces).uppercased()
            guard !trimmed.isEmpty, !trimmed.hasSuffix("*") else { return }
            guard let dash = trimmed.lastIndex(of: "-"),
                  let remaining = Int(trimmed[trimmed.index(after: dash)...]) else {
                // A bare callsign or alias is one hop.
                total += 1
                return
            }
            total += max(0, remaining)
        }
    }

    // MARK: - Prose

    var headline: String {
        guard hasEnoughEvidence else {
            return "Not enough of your own frames have come back to judge your path yet"
        }
        guard isOverProvisioned else {
            return hopsNeeded == 0
                ? "No digipeater has repeated you, so there is nothing to judge the path against"
                : "Your path matches what the network around you actually needs"
        }
        let saved = hopsRequested - hopsNeeded
        return "Your path asks for \(hopsRequested) hop\(hopsRequested == 1 ? "" : "s") "
            + "and \(hopsNeeded) would reach every digipeater you can hear"
            + (saved > 0 ? ", so each beacon is repeated more times than it needs to be" : "")
    }

    var detail: String {
        guard hasEnoughEvidence else {
            return "\(framesObserved) of your frames have been heard back. "
                + "It takes \(Self.minimumFrames) before one digipeater having a quiet "
                + "afternoon stops being able to change the answer."
        }
        let direct = digipeaters.filter(\.hearsUsDirect)
        guard !direct.isEmpty else {
            return "Nothing has been seen taking a frame straight off your transmitter."
        }
        let names = direct.map(\.callsign).joined(separator: ", ")
        let extra = reachedOnlyByExtraHops
        if extra.isEmpty {
            return "\(direct.count) digipeater\(direct.count == 1 ? "" : "s") "
                + "hear you directly (\(names)), and nothing you can hear has needed a "
                + "further hop. Measured from \(framesObserved) of your own frames coming "
                + "back, so it covers your receive range and no further: a digipeater too "
                + "distant to hear could be using the extra hop without this ever knowing."
        }
        let extraNames = extra.map(\.callsign).joined(separator: ", ")
        return "\(direct.count) hear you directly (\(names)). "
            + "\(extraNames) only ever repeat a repeat, so the extra hop is what reaches "
            + "\(extra.count == 1 ? "it" : "them"). Measured from \(framesObserved) of your "
            + "own frames coming back."
    }
}
