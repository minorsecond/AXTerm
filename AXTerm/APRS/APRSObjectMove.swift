import Foundation

/// What a move actually changes, in words.
///
/// A move is the same transmission as a placement — APRS has no move, and
/// re-sending a name we own *is* the move — but it is not the same
/// *decision*. Placing asks what this thing is. Moving asks only whether it
/// belongs at the new spot, so the confirmation should lead with the one
/// thing that changed: how far it went and which way.
nonisolated enum APRSObjectMove {

    /// Below this the drop is a slipped hand rather than an intention.
    ///
    /// Reported rather than refused: an operator may well mean to nudge an
    /// object twenty metres, and refusing that would be inventing a rule the
    /// protocol does not have. But "0.0 mi N" reads as a bug, and being told
    /// the thing barely moved is exactly the hint someone needs when the drag
    /// was an accident.
    static let restingMetres: Double = 30

    /// "1.4 mi WNW", or nil when the object has barely moved.
    static func summary(from origin: GreatCircle.Point,
                        to destination: GreatCircle.Point,
                        inMiles: Bool) -> String? {
        let km = GreatCircle.kilometres(from: origin, to: destination)
        guard km * 1000 >= restingMetres else { return nil }
        let bearing = GreatCircle.bearingDegrees(from: origin, to: destination)
        let value = inMiles ? GreatCircle.miles(fromKilometres: km) : km
        // One decimal close in, none far out: a tenth of a mile is a useful
        // distinction at walking range and noise at two hundred.
        let text = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return text + " " + (inMiles ? "mi" : "km") + " " + GreatCircle.compassPoint(bearing)
    }
}
