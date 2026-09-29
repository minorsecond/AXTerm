import Foundation

/// Checking the terrain forecast against what the radio has actually done.
///
/// The physics is verified against the Fresnel integral, so the arithmetic is
/// not in doubt. The inputs are: the far antenna height is a global default
/// until the operator records one, and the far position is a licence address
/// rather than an antenna.
///
/// One thing in the log can settle it. A completed connection over a path
/// with no digipeater in it means frames crossed that ground in both
/// directions, and terrain blocks both directions alike. Hearing a station is
/// not the same evidence: their transmitter may sit on a hill and ours in a
/// hollow, and a frame that arrived through a digipeater says only that the
/// digipeater is well placed.
nonisolated enum TerrainCalibration {

    enum Outcome: Equatable, Sendable {
        /// The model rates this path badly and a direct connection has
        /// completed over it anyway.
        case contradicted
        /// Model and log agree, or the model makes no strong claim.
        case consistent
        /// No completed direct connection, so nothing to check against. Not
        /// the same as agreement: an untried path produces silence either way.
        case untested
    }

    /// Only the severe end is worth contradicting. Below 10 dB the model is
    /// already saying the path works, so a connection agrees with it.
    static func outcome(severity: TerrainProfile.Severity,
                        hasCompletedDirectConnection: Bool) -> Outcome {
        switch severity {
        case .severe, .blocking:
            return hasCompletedDirectConnection ? .contradicted : .untested
        case .negligible, .noticeable:
            return .consistent
        case .unknown:
            return .untested
        }
    }

    /// One quiet line for a path the log has already disproved.
    ///
    /// Stated as a fact about the connection rather than a verdict on the
    /// chart. The operator can see the chart; what they cannot see is that
    /// their own station has already worked this path, or which input is
    /// worth correcting. Height comes first because it is one number they can
    /// go and find out.
    static func note(callsign: String, lastConnected: Date?) -> String {
        let when = lastConnected.map {
            " on " + $0.formatted(.dateTime.day().month(.abbreviated))
        } ?? ""
        return "You have connected directly to \(callsign) over this path\(when). "
            + "The forecast rates it worse than that, usually because the far "
            + "antenna height is still an assumed default."
    }
}
