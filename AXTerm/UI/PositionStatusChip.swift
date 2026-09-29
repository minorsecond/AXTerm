import SwiftUI

/// What the station is using for its position, in the toolbar.
///
/// Position is load-bearing in the way the TNC link is: every distance,
/// bearing, coverage ring and terrain profile starts from it, and a station
/// working from a grid centre is quietly answering short-path questions it
/// cannot answer. That earns a permanent place beside the other "is this
/// station working" indicators.
///
/// Graded rather than uniform, which is the same bargain `TNCStatusStrip`
/// makes: the normal case is a quiet secondary-coloured line naming the
/// source and its accuracy — "GPS ±20 m" — and only a real problem takes
/// colour. Nothing here shouts while everything is fine, but the operator
/// can always see which of three position sources the whole app is running
/// on, which is the question a settings page three clicks away was the only
/// thing answering.
///
/// Two states are worth the orange:
///
/// * No position at all, so distances and terrain are unavailable outright.
/// * Device location switched on and an attempt to use it has failed.
///   Waiting for the attempt to fail, rather than for a fix to be absent,
///   is what keeps this from blinking during the ordinary second at launch
///   before the first fix lands.
///
/// A stale-fix state is deliberately absent. It matters for a portable rig
/// and is noise for a base station, and there is no evidence yet for which
/// way that falls.
struct PositionStatusChip: View {

    let position: StationPosition?
    let usesDeviceLocation: Bool
    /// The last *fix*, not the last location — a grid-square fallback is not
    /// evidence the GPS answered.
    let deviceFix: StationLocation?
    let gpsError: GPSError?

    var body: some View {
        Button {
            SettingsRouter.shared.navigate(to: .general)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2)
                Text(title)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
            .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary)
                                            : AnyShapeStyle(Color.orange))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Station position: \(title)")
        .accessibilityHint("Opens position settings")
    }

    // MARK: - What it reads

    private var title: String {
        if let problem { return problem.label }
        guard let position else { return Problem.noPosition.label }
        return "\(position.source.shortLabel) \(accuracyText)"
    }

    private var symbol: String {
        problem?.symbol ?? "location.fill"
    }

    private var helpText: String {
        if let problem { return problem.help }
        guard let position else { return Problem.noPosition.help }
        return "Every distance, bearing, coverage ring and terrain profile "
            + "starts from this position: \(position.source.label.lowercased()), "
            + "accurate to about \(accuracyText.dropFirst()). "
            + "Click to change it."
    }

    private var accuracyText: String {
        guard let metres = position?.accuracyMetres else { return "" }
        return metres >= 1_000
            ? String(format: "\u{00B1}%.1f km", metres / 1_000)
            : String(format: "\u{00B1}%.0f m", metres)
    }

    enum Problem {
        case noPosition
        case denied
        case noFix

        var label: String {
            switch self {
            case .noPosition: return "No position"
            case .denied: return "Location denied"
            case .noFix: return "No GPS fix"
            }
        }

        var symbol: String {
            switch self {
            case .noPosition: return "location.slash"
            case .denied: return "location.slash"
            case .noFix: return "location.magnifyingglass"
            }
        }

        var help: String {
            switch self {
            case .noPosition:
                return "This station has no position, so distances, bearings, coverage "
                    + "rings and terrain profiles are unavailable. Set a grid square or "
                    + "coordinate in Settings \u{203A} General."
            case .denied:
                return "Device location is switched on but access is denied. Grant it in "
                    + "System Settings \u{203A} Privacy & Security \u{203A} Location "
                    + "Services, or switch it off in Settings \u{203A} General."
            case .noFix:
                return "Device location is switched on but no fix has arrived. The grid "
                    + "square is being used meanwhile. Open Settings \u{203A} General to "
                    + "try again."
            }
        }
    }

    /// Nil when there is nothing worth interrupting for.
    ///
    /// A failed attempt is required, not merely a missing fix. Between the
    /// window appearing and the first fix landing there is a second where
    /// device location is on and no coordinate exists yet, and reporting
    /// that painted the toolbar orange on every single launch — a blink
    /// that draws the eye and then withdraws the claim, which is worse than
    /// saying nothing. `currentLocation()` records an error on every failure
    /// path, so "we asked and it did not work" is a fact this can wait for.
    var problem: Problem? {
        guard position != nil else { return .noPosition }
        guard usesDeviceLocation, deviceFix == nil else { return nil }
        guard let gpsError else { return nil }
        return gpsError == .denied ? .denied : .noFix
    }
}
