import SwiftUI

/// Says something about this station's position only when there is something
/// worth saying.
///
/// Position is load-bearing in the way the TNC link is: every distance,
/// bearing, coverage ring and terrain profile starts from it, and a station
/// with no usable position has a quietly broken map. That earns it a place
/// beside the other "is this station working" indicators.
///
/// What it does not earn is a permanent readout. A base station's position
/// never changes, so a chip that always says `DM79po` is a status line that
/// shouts when everything is fine — the thing `TNCStatusStrip` argues
/// against, and the thing that trains an operator to stop reading the
/// toolbar. So it is silent unless one of two things is true:
///
/// * There is no position at all, so distances and terrain are unavailable
///   and nothing else on screen says why.
/// * The operator switched device location on and an attempt to use it has
///   failed. That state used to be visible only on the Settings page they
///   would already have had to be looking at. Waiting for the attempt to
///   fail, rather than for a fix to be absent, is what keeps this quiet
///   during the ordinary second at launch before the first fix arrives.
///
/// A stale-fix state is deliberately absent. It matters for a portable rig
/// and is pure noise for a base station, and there is no field evidence yet
/// for which way that trade falls.
struct PositionStatusChip: View {

    let position: StationPosition?
    let usesDeviceLocation: Bool
    /// The last *fix*, not the last location — a grid-square fallback is not
    /// evidence the GPS answered.
    let deviceFix: StationLocation?
    let gpsError: GPSError?

    var body: some View {
        if let problem {
            Button {
                SettingsRouter.shared.navigate(to: .general)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: problem.symbol)
                        .font(.caption2)
                    Text(problem.label)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(problem.help)
            .accessibilityLabel(problem.label)
            .accessibilityHint("Opens position settings")
        }
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
