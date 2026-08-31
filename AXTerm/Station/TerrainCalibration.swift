import Foundation

/// Checking the terrain forecast against what the radio has actually done.
///
/// The physics is verified against the Fresnel integral, so the arithmetic is
/// not in doubt. The inputs are: every far antenna height is a global
/// assumption until the operator records one, and every far position is a
/// licence address rather than an antenna — and this app's own notes say
/// nodes sit on hilltops, not at the operator's house.
///
/// So the forecast has one honest test available, needing no new data: a path
/// it calls severely degraded, from a station whose frames arrive here with
/// nothing repeating them. Terrain blocks both directions equally, so a
/// direct reception is not weak evidence against a terrain verdict — it is
/// a measurement contradicting a prediction.
///
/// The point is not to hide the forecast when it disagrees with the record.
/// It is to stop the forecast being the only voice, and to say which input is
/// most likely wrong.
nonisolated enum TerrainCalibration {

    enum Outcome: Equatable, Sendable {
        /// The model calls this path badly degraded and the station has been
        /// heard here directly regardless.
        case contradicted
        /// Model and record agree, or the model makes no strong claim to
        /// disagree with.
        case consistent
        /// Nothing has been heard directly from this station, so there is
        /// nothing to check the model against. Not the same as agreement —
        /// a station that never transmits produces silence either way.
        case untested
    }

    /// Only the severe end is worth contradicting.
    ///
    /// Below 10 dB the model is already saying the path works, so a
    /// reception agrees with it rather than refuting it. The check exists for
    /// the case where the page tells an operator not to bother with a station
    /// they are demonstrably receiving.
    static func outcome(severity: TerrainProfile.Severity,
                        heardDirectly: Bool) -> Outcome {
        switch severity {
        case .severe, .blocking:
            return heardDirectly ? .contradicted : .untested
        case .negligible, .noticeable:
            return .consistent
        case .unknown:
            return .untested
        }
    }

    /// What to say on a contradicted path, and what to do about it.
    ///
    /// Names the two suspects in the order they are worth checking. Height
    /// first: it is one number, the operator can find it out, and it is the
    /// input the verdict is most sensitive to. Position second, because a
    /// licence address for a node is often kilometres and a few hundred
    /// metres of elevation from the antenna, and there is nothing the
    /// operator can do about that except record what they know.
    static func note(callsign: String, directFrames: Int) -> String {
        let heard = directFrames == 1
            ? "one frame" : "\(directFrames.formatted()) frames"
        return "This path reads as blocked, but \(heard) from \(callsign) have "
            + "arrived here directly — nothing repeated them, and terrain blocks "
            + "both directions equally. So the forecast is wrong about this path. "
            + "The likeliest cause is the far antenna height, which is a default "
            + "until you record one; after that, the position, which is a licence "
            + "address rather than an antenna."
    }
}
