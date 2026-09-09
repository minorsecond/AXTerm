import Foundation

/// Naming what an adaptive figure is about.
///
/// The tuner keeps its state per channel and per route (see `AdaptiveScope`),
/// which makes a bare "K1 P64" ambiguous in a way it was not when there was
/// one figure for the whole application. A per-radio number nobody can
/// attribute is worse than a global one, so every surface that shows a figure
/// says which channel it came from — but only when there is more than one, or
/// the attribution is noise on every row.
nonisolated enum AdaptiveScopeLabel {

    static func text(for params: AdaptiveParams?,
                     radioName: (RadioID) -> String?,
                     hasMultipleRadios: Bool) -> String {
        guard let params else { return "Waiting" }
        let radio = params.radio.map { radioName($0) ?? $0.rawValue }

        guard let destination = params.destination, !destination.isEmpty else {
            // No destination: this is a whole channel, or the operator's
            // baseline, which belongs to no radio at all.
            guard let radio else { return "All channels" }
            return "\(radio) channel"
        }

        let path = params.pathSignature ?? ""
        let route = path.isEmpty ? destination : "\(destination) via \(path)"
        guard hasMultipleRadios, let radio else { return route }
        return "\(route) · \(radio)"
    }
}
