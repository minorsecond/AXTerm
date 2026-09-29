import Foundation

/// Altitude in the operator's units.
///
/// APRS always transmits feet — `/A=DDDDDD` and the Mic-E base-91 form are
/// both feet by definition — so feet is what is stored and metres is the
/// conversion, never the other way round.
nonisolated enum AltitudeDisplay {

    /// - Parameter inFeet: the operator's distance preference. Someone reading
    ///   kilometres wants metres, and mixing the two in one card is how a
    ///   terrain judgement gets made against the wrong number.
    static func string(feet: Int, inFeet: Bool) -> String {
        if inFeet { return "\(formatted(feet)) ft" }
        return "\(formatted(Int((Double(feet) * 0.3048).rounded()))) m"
    }

    private static func formatted(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
